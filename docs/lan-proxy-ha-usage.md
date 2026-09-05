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
```

修改后无需重建候选池，调度器下一轮会读取新值。修改 `group` 则必须执行 `clashctl ha refresh`。

## 已知边界

- 正常切换不会主动清空连接，但旧节点失效时，建立在旧节点上的连接无法迁移，应用需要重连。
- 自动判断基于连通性和 HTTP 延迟。当前版本没有用大文件持续测速，避免测速抢占局域网带宽。
- 单机方案不能处理 Linux 服务器断电、局域网或宽带本身故障。
- 客户端订阅服务使用局域网 HTTP 和随机令牌；只应部署在可信且有防火墙隔离的网络。
