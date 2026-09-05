#!/usr/bin/env bash

CLASHCTL_SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
. "$CLASHCTL_SRC/scripts/preflight.sh"
. "$CLASHCTL_SRC/scripts/cmd/off.sh"

! _is_root && tunstatus >&/dev/null && {
    _errorcat "请先关闭 Tun 模式"
    exit
}
uninstall_service

# 清理多订阅 HA 辅助服务。
for ha_unit in clashctl-ha.service clashctl-ha-sub.service; do
    command -v systemctl >/dev/null 2>&1 && systemctl disable --now "$ha_unit" >/dev/null 2>&1 || true
    /usr/bin/rm -f "/etc/systemd/system/$ha_unit"
done
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
[ -f "$CLASH_HA_PID" ] && kill "$(cat "$CLASH_HA_PID" 2>/dev/null)" 2>/dev/null || true
[ -f "$CLASH_HA_SUB_PID" ] && kill "$(cat "$CLASH_HA_SUB_PID" 2>/dev/null)" 2>/dev/null || true

# 清理旧版 sub update --auto 遗留的自管 crontab
command -v crontab >&/dev/null && {
    crontab -l 2>/dev/null | grep -Fv "$CLASHCTL_CRON_TAG" | crontab -
}

/usr/bin/rm -rf "$CLASHCTL_HOME"
revoke_rc

_okcat '✨' "已卸载，相关配置已清除"
[ -n "$http_proxy" ] && _failcat '❗' "当前终端仍残留代理环境变量，重开终端即可清除"
