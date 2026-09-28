#!/usr/bin/env bash

clashoff() {
    case "${1:-}" in
    -e | --env-only)
        off_env_only
        ;;
    -s | --service-only)
        off_service_only || return
        if [ -n "${http_proxy:-}" ]; then _failcat "警告：当前终端代理未关闭"; fi
        ;;
    -h | --help)
        off_help
        ;;
    *)
        off_service_only || return
        off_env_only
        ;;
    esac
}

off_env_only() {
    unset_system_proxy
    _okcat "终端代理已关闭"
}
off_service_only() {
    _supervisor_stop || return 1
    _ha_stop_daemon
    _ha_stop_subscription_server
    service_is_active >&/dev/null && {
        service_stop >/dev/null
        service_is_active >&/dev/null && tunstatus >&/dev/null && {
            service_sudo_stop || _errorcat "请先关闭 Tun 模式" || return
        }
        service_is_active >&/dev/null && {
            _failcat "$CLASHCTL_KERNEL 停止失败"
            return 1
        }
    }
    _okcat "$CLASHCTL_KERNEL 已停止"
}

unset_system_proxy() {
    unset http_proxy
    unset https_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset all_proxy
    unset ALL_PROXY
    unset no_proxy
    unset NO_PROXY
}

off_help() {
    cat <<EOF

clashctl off - 关闭代理环境

Usage:
  clashctl off [OPTIONS]

Options:
  -s, --service-only 仅关闭 $CLASHCTL_KERNEL 服务
  -e, --env-only     仅关闭终端代理
  -h, --help         显示帮助信息

EOF
}
