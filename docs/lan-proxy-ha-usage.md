# 多订阅高可用使用说明

当前实现适用于 Mihomo。推荐使用带 systemd 的 Linux，并以 root 安装，这样 HA 调度器和客户端订阅服务会注册为开机服务。普通用户安装也能运行，但辅助进程不会自动跨系统重启恢复。

## 安装和启用

安装项目后，先添加订阅。第一个订阅作为规则、DNS 等基础模板，所有订阅中的内联 `proxies` 节点会进入统一候选池。

```bash
clashctl sub add -n A 'https://example.com/sub-a'
clashctl sub add -n B 'https://example.com/sub-b'
clashctl sub add -n C 'https://example.com/sub-c'

clashctl ha enable
clashctl ha status
```

节点在统一组中显示为 `[订阅名] 原节点名`。目前只聚合配置里的内联 `proxies`；仅含远程 `proxy-providers` 且没有内联节点的订阅会被跳过并写入 HA 日志。

启用 HA 会生成聚合配置并重启一次 Mihomo。此后的自动优选通过 API 修改 `HA-AUTO` 选择，不重启内核。原订阅的策略组名称会保留并统一指向 `HA-AUTO`，因此原规则仍能找到它们，但原来按地区或业务选择不同组的行为会被统一出口取代。

## 给局域网设备使用

假设 Linux 地址为 `192.168.1.10`，局域网网段是 `192.168.1.0/24`：

```bash
clashctl ha lan enable 192.168.1.0/24 clash
```

命令会显示：

- HTTP 代理地址，例如 `http://192.168.1.10:7890`
- 用户名 `clash` 和一个随机密码
- 客户端订阅地址，例如 `http://192.168.1.10:8088/sub/<随机令牌>`

如果运行在 Docker bridge 网络中，程序检测到的通常是容器地址。第三个参数应明确填写局域网设备实际访问的宿主机地址：

```bash
clashctl ha lan enable 192.168.31.0/24 clash 192.168.31.1
```

在手机或电脑的 Mihomo/Clash 客户端中导入这个客户端订阅地址即可。生成的客户端配置只包含 Linux 服务器入口，不会泄露真实上游订阅。如果应用支持手工 HTTP 代理，也可以直接填写服务器地址、7890 端口和命令显示的用户名密码。

建议为 Linux 配置固定 DHCP 地址。防火墙只允许可信局域网访问 TCP 7890 和 8088。例如使用 UFW：

```bash
sudo ufw allow from 192.168.1.0/24 to any port 7890 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 8088 proto tcp
```

不要把 7890、8088 或 Mihomo 管理端口转发到公网。管理 API 在启用 LAN 功能时会绑定到 `127.0.0.1:9090`。

如需自行指定代理密码，先设置环境变量；这样密码不会作为命令参数出现在 shell 历史中：

```bash
export CLASHCTL_LAN_PASSWORD='换成强密码'
clashctl ha lan enable 192.168.1.0/24 clash
unset CLASHCTL_LAN_PASSWORD
```

## 日常操作

```bash
clashctl ha status             # 当前节点、延迟、判断原因和订阅地址
clashctl ha check              # 立即检测一次
clashctl ha log -n 50          # 最近日志
clashctl ha refresh --update   # 更新全部订阅并重建候选池；会重启一次内核
```

## Codex / OpenAI 专用高可用

如果普通网页可用，但 Codex 经常连接失败，可启用独立的 `CODEX` 策略组：

```bash
clashctl ha codex enable       # 建组、重启一次内核并立即优选
clashctl ha codex status       # 查看自动/固定模式、当前节点和判断原因
clashctl ha codex check        # 立即执行一轮检测
```

OpenAI、ChatGPT 及相关静态资源域名会进入 `CODEX`。调度器分别检测 ChatGPT 页面入口和 OpenAI API 鉴权入口，只有两个目标都返回预期状态的节点才进入候选池，并使用较慢的一次延迟作为评分。默认每 120 秒检测一次；当前节点连续失败两轮会故障切换。性能切换要求候选至少快 150ms、同时改善至少 30%，连续三轮成立且冷却 30 分钟；存在 OpenAI 活跃连接时会推迟性能切换。

Web UI 中 `CODEX` 默认选择 `CODEX-HA`，此时自动逻辑生效。在 `CODEX` 中直接选择任一具体节点后即进入固定模式，调度器不会进行性能或故障切换；恢复自动模式使用：

```bash
clashctl ha codex auto
```

也可以从命令行固定节点：

```bash
clashctl ha codex pin '[订阅名] 节点名'
```

关闭专用策略并恢复原规则：

```bash
clashctl ha codex disable
```

## 外部代理兜底

当所有订阅节点都不可用时，可以让 Linux 代理入口临时转发到另一台 HTTP/SOCKS5 代理服务器。客户端仍连接原来的 Linux 地址，故障切换和恢复回切都由 HA 调度器完成。

启用后，基础订阅中原有的代理策略组统一经 `HA-AUTO` 出口转发，因此所有原本需要代理的 TCP 流量都会跟随外部备用切换；原本命中 `DIRECT`、`REJECT` 等直连或拦截规则的流量保持原行为。

例如将 `192.168.31.47:9098` 配置为 HTTP 备用、`192.168.31.47:9099` 配置为 SOCKS5 备用：

```bash
clashctl ha fallback set 192.168.31.47 9098 9099
clashctl ha fallback test
clashctl ha fallback status
```

如果容器网络不能直接访问备用服务器，可以先把备用端口反向转发到本机，再配置回环地址。例如将备用 HTTP/SOCKS5 端口分别映射到本机 `19098/19099` 后使用：

```bash
clashctl ha fallback set 127.0.0.1 19098 19099
```

生成的结构为：

```text
HA-AUTO
├── HA-LOCAL        # 原有订阅节点，由延迟和地区策略管理
├── JSSS-SOCKS      # 首选外部备用，支持 UDP 配置
└── JSSS-HTTP       # HTTP/HTTPS TCP 备用
```

外部备用不会参与正常的延迟排名。只有本地节点池连续达到 `fallback.failure-confirmations` 次全体不可用，且外部代理通过两个实际请求检查时，`HA-AUTO` 才切换到外部代理。外部代理生效期间仍会探测本地节点；本地候选连续达到 `recovery-confirmations` 次健康，并经过 `recovery-stable-seconds` 稳定期后才回切。

默认开启 `defer-recovery-when-active`，存在活跃连接时推迟恢复回切。严格固定 `pin` 模式不会自动进入外部备用。停用并恢复原来的单层节点组：

```bash
clashctl ha fallback disable
```

对应的配置保存在 `resources/ha.yaml`：

```yaml
fallback:
  enabled: true
  local-group: HA-LOCAL
  failure-confirmations: 2
  recovery-confirmations: 3
  recovery-stable-seconds: 300
  defer-recovery-when-active: true
  check-url: http://www.gstatic.com/generate_204
  check-expected-status: 204
  confirm-url: https://cp.cloudflare.com/generate_204
  confirm-expected-status: 204
  timeout: 5000
  upstreams:
    - name: JSSS-SOCKS
      type: socks5
      server: 192.168.31.47
      port: 9099
      udp: true
    - name: JSSS-HTTP
      type: http
      server: 192.168.31.47
      port: 9098
```

后台默认每 30 秒检测一次。性能切换要求候选至少快 80ms、同时改善至少 30%，并连续三轮成立；性能切换后冷却 10 分钟。当前节点连续两轮在主目标和确认目标上都失败时，会切换到本轮可用的最低延迟节点。

会议、长下载期间可以暂停性能切换，故障切换仍然保留：

```bash
clashctl ha hold 120
clashctl ha resume
```

需要完全固定节点时，先从 `clashctl node list` 或 Web 面板取得完整节点名：

```bash
clashctl ha pin '[A] 香港 01'
clashctl ha unpin
```

严格固定期间即使节点故障也不会自动切换。

停止局域网入口或恢复项目原来的单订阅模式：

```bash
clashctl ha lan disable
clashctl ha disable
```

## 调整策略

编辑安装目录下的 `resources/ha.yaml`。常用字段如下：

```yaml
interval: 30
timeout: 5000
absolute-improvement: 80
relative-improvement: 30
performance-confirmations: 3
failure-confirmations: 2
cooldown: 600
region-preference:
  enabled: true
  tolerance: 100
  order: [taiwan, japan, hong-kong, other]
ha-domains:
  - ws.okx.com
codex:
  interval: 120
  absolute-improvement: 150
  relative-improvement: 30
  performance-confirmations: 3
  failure-confirmations: 2
  cooldown: 1800
  protect-active-connections: true
subscription-update:
  enabled: true
  interval: 21600
  retry-interval: 900
  defer-when-active: true
```

修改后无需重建候选池，调度器下一轮会读取新值。修改 `group` 则必须执行 `clashctl ha refresh`。

定时订阅更新默认每 6 小时执行一次，依次下载并校验全部订阅。内容没有变化时不会重启 Mihomo；内容变化但仍有活跃连接时会标记为待应用，并每 15 分钟检查一次，空闲后才重建 HA 节点池。下载、校验或重建失败时保留当前可用配置。运行 `clashctl ha status` 可以查看上次成功时间、下次尝试时间和待应用状态。

地区偏好只在节点延迟不超过本轮最快节点 100ms 时生效；默认顺序是台湾、日本、香港、其他。同一地区仍选择延迟最低的节点。地区优先切换与普通性能切换一样，需要连续三轮确认并遵守冷却时间。设置 `region-preference.enabled: false` 可关闭地区偏好。

`ha-domains` 中的完整主机名会生成优先级较高的 `DOMAIN,<主机>,HA-AUTO` 规则。默认的 `ws.okx.com` 因此始终使用通用 HA 节点，不依赖基础订阅自带的规则集。

通用 `HA-AUTO` 的自动切换只在 `mode: auto` 时执行。使用 `clashctl ha pin '<节点全名>'` 后进入 `pin` 模式，即使固定节点故障也不会切换；使用 `clashctl ha unpin` 才会恢复自动模式。Codex 专用组则直接读取 Web UI 中 `CODEX` 的选择，选中具体节点后不会自动切换，选回 `CODEX-HA` 或运行 `clashctl ha codex auto` 才恢复自动模式。

## 已知边界

- 正常切换不会主动清空连接，但旧节点失效时，建立在旧节点上的连接无法迁移，应用需要重连。
- 外部备用切换同样不能迁移已有 TCP/UDP 会话；切换后新连接使用新的出口。
- HTTP 外部备用只承载 TCP。需要 UDP 时应使用支持 UDP 的 SOCKS5 上游，并在真实应用中验证。
- 自动判断基于连通性和 HTTP 延迟。当前版本没有用大文件持续测速，避免测速抢占局域网带宽。
- 单机方案不能处理 Linux 服务器断电、局域网或宽带本身故障。
- 客户端订阅服务使用局域网 HTTP 和随机令牌；只应部署在可信且有防火墙隔离的网络。
