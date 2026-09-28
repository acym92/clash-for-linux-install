#!/usr/bin/env bash

_supervisor_log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$CLASH_SUPERVISOR_LOG"
}

_supervisor_running() {
    [ -f "$CLASH_SUPERVISOR_PID" ] &&
        _ha_pid_running "$(cat "$CLASH_SUPERVISOR_PID" 2>/dev/null)" 'clashctl supervise run'
}

_supervisor_step() {
    (
        exec 7>"${CLASH_SUPERVISOR_PID}.cycle.lock"
        flock -n 7 || exit 0
        [ -f "$CLASH_SUPERVISOR_ENABLED" ] || exit 0
        if ! service_is_active; then
            _supervisor_log "内核进程不存在，重新启动"
            service_start || exit 1
        fi
        CLASHCTL_SERVICE_CANCEL_FILE=$CLASH_SUPERVISOR_ENABLED service_wait_ready || {
            _supervisor_log "WARN 内核/API 尚未就绪，稍后重试"
            exit 1
        }
        [ -f "$CLASH_SUPERVISOR_ENABLED" ] || exit 0
        _ha_ensure_services || {
            _supervisor_log "WARN 附属服务未全部就绪，稍后重试"
            exit 1
        }
        date +%s >"$CLASH_SUPERVISOR_HEARTBEAT"
    )
}

_supervisor_cleanup() {
    [ "$(cat "$CLASH_SUPERVISOR_PID" 2>/dev/null)" = "$$" ] && /usr/bin/rm -f "$CLASH_SUPERVISOR_PID"
    return 0
}

_supervisor_run() {
    local interval=${CLASHCTL_SUPERVISOR_INTERVAL:-10} backoff=5 delay
    [[ "$interval" =~ ^[1-9][0-9]*$ ]] || interval=10
    exec 9>"${CLASH_SUPERVISOR_PID}.lock"
    flock -n 9 || return 0
    printf '%s\n' "$$" >"$CLASH_SUPERVISOR_PID"
    trap '_supervisor_cleanup' EXIT
    trap 'exit 0' INT TERM
    _supervisor_log "容器/无 systemd 服务守护启动"
    while [ -f "$CLASH_SUPERVISOR_ENABLED" ]; do
        if _supervisor_step; then
            delay=$interval
            backoff=5
        else
            delay=$backoff
            backoff=$((backoff * 2))
            [ "$backoff" -le 60 ] || backoff=60
        fi
        sleep "$delay" 9>&- & wait $! || true
    done
}

_supervisor_start() {
    detect_service_manager
    # Native managers already supervise the service units.
    [ "$service_manager" = nohup ] || return 0
    : >"$CLASH_SUPERVISOR_ENABLED"
    _supervisor_running && return 0
    (
        exec 8>"${CLASH_SUPERVISOR_PID}.launch.lock"
        flock -w 5 8 || exit 1
        _supervisor_running && exit 0
        local runner=()
        command -v tini >/dev/null 2>&1 && runner=(tini -s -g --)
        nohup "${runner[@]}" env CLASHCTL_HOME="$CLASHCTL_HOME" bash -c \
            '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"; clashctl supervise run' \
            </dev/null 7>&- 8>&- 9>&- >>"$CLASH_SUPERVISOR_LOG" 2>&1 &
    ) || return 1
    local attempt
    for ((attempt = 0; attempt < 30; attempt++)); do
        _supervisor_running && return 0
        sleep 0.1
    done
    return 1
}

_supervisor_stop() {
    /usr/bin/rm -f "$CLASH_SUPERVISOR_ENABLED"
    local pid='' attempt
    [ -f "$CLASH_SUPERVISOR_PID" ] && pid=$(cat "$CLASH_SUPERVISOR_PID" 2>/dev/null)
    if _supervisor_running; then
        kill -TERM "$pid" 2>/dev/null || true
        for ((attempt = 0; attempt < 50; attempt++)); do
            _ha_pid_running "$pid" 'clashctl supervise run' || break
            sleep 0.1
        done
        _ha_pid_running "$pid" 'clashctl supervise run' && kill -KILL "$pid" 2>/dev/null || true
    fi
    # Wait for any in-flight start before stopping the kernel, so an explicit
    # `off` cannot be undone by the final supervisor cycle.
    (
        exec 7>"${CLASH_SUPERVISOR_PID}.cycle.lock"
        flock -w 40 7
    ) || return 1
    /usr/bin/rm -f "$CLASH_SUPERVISOR_PID"
}

_supervisor_status() {
    detect_service_manager
    [ "$service_manager" = nohup ] || return 0
    printf '服务守护：%s\n' "$(if _supervisor_running; then printf '运行中'; else printf '未运行'; fi)"
    printf '守护最近成功检查：%s\n' "$(cat "$CLASH_SUPERVISOR_HEARTBEAT" 2>/dev/null || printf '尚未检查')"
}

clashsupervise() {
    case "${1:-status}" in
    start) _supervisor_start ;;
    stop) _supervisor_stop ;;
    run) _supervisor_run ;;
    status) _supervisor_status ;;
    *) _errorcat '用法：clashctl supervise [start|stop|status]' ; return 1 ;;
    esac
}
