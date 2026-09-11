# 手动直连规则

以下地址由用户指定为不经过代理。Mihomo 使用 `DOMAIN-SUFFIX` 匹配根域名及其所有子域名，因此配置中不写 `*.`。

## 分号分隔字符串

```text
localhost;127.*;[::1];*.qq.com;*.bilibili.com;*.aliyun.com;192.168.31.*;*.deepseek.com;*.feishu.com;*.feishu.cn;*.163.com;*.battle.net;*.battlenet.com.cn;*.blizzard.com;blizzard.gcdn.cloudn.co.kr;*.netease.com;*.baidu.com;*.gitee.com;*.taobao.com;*.youdao.com;*.ugnas.com;*.ug.link
```

## Mihomo 规则

```yaml
- DOMAIN,localhost,DIRECT
- IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
- IP-CIDR6,::1/128,DIRECT,no-resolve
- IP-CIDR,192.168.31.0/24,DIRECT,no-resolve
- DOMAIN-SUFFIX,qq.com,DIRECT
- DOMAIN-SUFFIX,bilibili.com,DIRECT
- DOMAIN-SUFFIX,aliyun.com,DIRECT
- DOMAIN-SUFFIX,deepseek.com,DIRECT
- DOMAIN-SUFFIX,feishu.com,DIRECT
- DOMAIN-SUFFIX,feishu.cn,DIRECT
- DOMAIN-SUFFIX,163.com,DIRECT
- DOMAIN-SUFFIX,battle.net,DIRECT
- DOMAIN-SUFFIX,battlenet.com.cn,DIRECT
- DOMAIN-SUFFIX,blizzard.com,DIRECT
- DOMAIN,blizzard.gcdn.cloudn.co.kr,DIRECT
- DOMAIN-SUFFIX,netease.com,DIRECT
- DOMAIN-SUFFIX,baidu.com,DIRECT
- DOMAIN-SUFFIX,gitee.com,DIRECT
- DOMAIN-SUFFIX,taobao.com,DIRECT
- DOMAIN-SUFFIX,youdao.com,DIRECT
- DOMAIN-SUFFIX,ugnas.com,DIRECT
- DOMAIN-SUFFIX,ug.link,DIRECT
```

这些规则同时写入服务端 Mixin 和通过局域网订阅下发的客户端配置，并排列在代理规则之前。
