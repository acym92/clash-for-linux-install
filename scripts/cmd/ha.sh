#!/usr/bin/env bash

# Multi-subscription high availability. Runtime selection is performed through
# the controller API, so normal failover does not restart Mihomo.

_ha_get() {
    "$BIN_YQ" "$1 // $2" "$CLASH_HA_CONFIG" 2>/dev/null
}

_ha_enabled() {
    [ -f "$CLASH_HA_CONFIG" ] && "$BIN_YQ" -e '.enabled == true' "$CLASH_HA_CONFIG" >/dev/null 2>&1
}

_ha_state_get() {
    [ -f "$CLASH_HA_STATE" ] || {
        "$BIN_YQ" -n "$2" 2>/dev/null
        return
    }
    "$BIN_YQ" "$1 // $2" "$CLASH_HA_STATE" 2>/dev/null
}

_ha_log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$CLASH_HA_LOG"
}

_ha_random() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-24}"
}

_ha_build_config() {
    [ "$CLASHCTL_KERNEL" = mihomo ] || {
        _errorcat "HA 模式目前仅支持 mihomo 内核"
        return 1
    }

    local template_name template_path group nodes part work name path count=0
    template_name=$(_sub_current)
    [ -n "$template_name" ] || template_name=$(_sub_names | head -n1)
    [ -n "$template_name" ] || {
        _errorcat "没有可聚合的订阅，请先添加订阅"
        return 1
    }
    template_path=$(_sub_get "$template_name" path)
    [ -s "$template_path" ] || {
        _errorcat "基础订阅文件不可用：$template_path"
        return 1
    }

    group=$(_ha_get '.group' '"HA-AUTO"')
    nodes=$(mktemp "${CLASH_RESOURCES_DIR}/.ha-nodes.XXXXXX") || return 1
    part=$(mktemp "${CLASH_RESOURCES_DIR}/.ha-part.XXXXXX") || {
        /usr/bin/rm -f "$nodes"
        return 1
    }
    work=$(mktemp "${CLASH_RESOURCES_DIR}/.ha-config.XXXXXX") || {
        /usr/bin/rm -f "$nodes" "$part"
        return 1
    }
    printf '[]\n' >"$nodes"

    while IFS= read -r name; do
        [ -n "$name" ] || continue
        path=$(_sub_get "$name" path)
        [ -s "$path" ] || continue
        PROFILE_NAME=$name "$BIN_YQ" '
          [.proxies[]? | select(.name != null) |
            .name = ("[" + strenv(PROFILE_NAME) + "] " + .name)]
        ' "$path" >"$part" || continue
        local n
        n=$("$BIN_YQ" 'length' "$part" 2>/dev/null)
        [ "${n:-0}" -gt 0 ] || {
            _ha_log "WARN [$name] 没有内联 proxies，当前版本暂不聚合远程 proxy-providers"
            continue
        }
        "$BIN_YQ" eval-all 'select(fileIndex == 0) + select(fileIndex == 1)' "$nodes" "$part" >"${nodes}.new" || continue
        /bin/mv -f "${nodes}.new" "$nodes"
        count=$((count + n))
    done < <(_sub_names)

    [ "$count" -gt 0 ] || {
        /usr/bin/rm -f "$nodes" "$part" "$work"
        _errorcat "所有订阅都没有可聚合的内联节点（proxy-providers 格式暂不支持）"
        return 1
    }

    HA_GROUP=$group "$BIN_YQ" eval-all '
      select(fileIndex == 0) as $config |
      select(fileIndex == 1) as $nodes |
      strenv(HA_GROUP) as $ha |
      $config |
      .proxies = $nodes |
      (.proxy-groups // []) as $old |
      .proxy-groups = (
        ($old | map(select(.name != $ha) |
          {"name": .name, "type": "select", "proxies": [$ha]})) +
        [{"name": $ha, "type": "select", "proxies": ($nodes | map(.name))}]
      ) |
      .rules = ((.rules // []) as $rules |
        ($rules | select(length > 0)) // ["MATCH," + $ha])
    ' "$template_path" "$nodes" >"$work"
    /usr/bin/rm -f "$nodes" "$part"

    _valid_config "$work" || {
        /usr/bin/rm -f "$work"
        _errorcat "聚合配置未通过内核校验"
        return 1
    }
    _HA_BUILD_FILE=$work
    _HA_BUILD_COUNT=$count
}

_ha_build_and_restart() {
    _ha_build_config || return 1
    local backup rc
    backup=$(mktemp "${CLASH_RESOURCES_DIR}/.ha-base-backup.XXXXXX") || return 1
    /bin/cp -f "$CLASH_CONFIG_BASE" "$backup"
    /bin/mv -f "$_HA_BUILD_FILE" "$CLASH_CONFIG_BASE"
    _merge_config_restart
    rc=$?
    if [ "$rc" -ne 0 ]; then
        /bin/mv -f "$backup" "$CLASH_CONFIG_BASE"
        _merge_config >/dev/null 2>&1 || true
        _errorcat "HA 配置启用失败，已恢复原配置"
        return 1
    fi
    /usr/bin/rm -f "$backup"
    _okcat "已聚合 $_HA_BUILD_COUNT 个节点到 [$(_ha_get '.group' '"HA-AUTO"')]"
}

_ha_write_state() {
    local now=$1 current=$2 current_delay=$3 best=$4 best_delay=$5 failures=$6 candidate=$7 candidate_count=$8 reason=$9
    local last_switch
    last_switch=$(_ha_state_get '."last-switch"' '0')
    CHECKED=$now CURRENT=$current CURRENT_DELAY=$current_delay BEST=$best BEST_DELAY=$best_delay \
      FAILURES=$failures CANDIDATE=$candidate CANDIDATE_COUNT=$candidate_count REASON=$reason LAST_SWITCH=$last_switch \
      "$BIN_YQ" -n '
        {"checked-at": strenv(CHECKED), "current": strenv(CURRENT),
         "current-delay": strenv(CURRENT_DELAY), "best": strenv(BEST),
         "best-delay": strenv(BEST_DELAY), "failures": (env(FAILURES) | tonumber),
         "candidate": strenv(CANDIDATE), "candidate-count": (env(CANDIDATE_COUNT) | tonumber),
         "last-reason": strenv(REASON), "last-switch": (env(LAST_SWITCH) | tonumber)}
      ' >"${CLASH_HA_STATE}.new" && /bin/mv -f "${CLASH_HA_STATE}.new" "$CLASH_HA_STATE"
}

_ha_record_switch() {
    local now=$1 reason=$2
    SWITCH_AT=$now SWITCH_REASON=$reason "$BIN_YQ" -i \
      '."last-switch" = (env(SWITCH_AT) | tonumber) | ."last-reason" = strenv(SWITCH_REASON)' "$CLASH_HA_STATE"
}

_ha_region_key() {
    local name=${1,,}
    if [[ "$name" == *台湾* || "$name" == *台灣* || "$name" == *臺灣* || "$name" == *taiwan* || "$name" == *🇹🇼* || "$name" =~ (^|[^a-z])tw([^a-z]|$) ]]; then
        printf 'taiwan\n'
    elif [[ "$name" == *日本* || "$name" == *东京* || "$name" == *東京* || "$name" == *大阪* || "$name" == *japan* || "$name" == *🇯🇵* || "$name" =~ (^|[^a-z])jp([^a-z]|$) ]]; then
        printf 'japan\n'
    elif [[ "$name" == *香港* || "$name" == *hongkong* || "$name" == *"hong kong"* || "$name" == *🇭🇰* || "$name" =~ (^|[^a-z])hk([^a-z]|$) ]]; then
        printf 'hong-kong\n'
    else
        printf 'other\n'
    fi
}

_ha_region_rank() {
    local key order entry rank=0
    key=$(_ha_region_key "$1")
    order=$2
    while IFS= read -r entry; do
        entry=${entry//[[:space:]]/}
        [ "$entry" = "$key" ] && { printf '%s\n' "$rank"; return; }
        rank=$((rank + 1))
    done < <(tr ',' '\n' <<<"$order")
    printf '999\n'
}

_ha_mode_allows_performance_switch() {
    [ "$1" = auto ]
}

_ha_mode_allows_failure_switch() {
    [ "$1" != pin ]
}

_ha_same_region() {
    [ "$(_ha_region_key "$1")" = "$(_ha_region_key "$2")" ]
}

# 从有效的 name<TAB>delay 行中选择候选。地区偏好只在最快延迟加容差的
# 范围内生效，因此偏好地区的慢节点不会压过明显更快的其他地区节点。
_ha_select_best() {
    local tolerance=$1 order=$2 enabled=$3 name delay fastest='' rank best_rank=999
    local best='' best_delay=''
    local names=() delays=()
    while IFS=$'\t' read -r name delay; do
        [[ "$delay" =~ ^[0-9]+$ ]] && [ "$delay" -gt 0 ] || continue
        names+=("$name")
        delays+=("$delay")
        [ -z "$fastest" ] || [ "$delay" -ge "$fastest" ] || fastest=$delay
        [ -n "$fastest" ] || fastest=$delay
    done
    [ -n "$fastest" ] || return 0

    local i
    for ((i = 0; i < ${#names[@]}; i++)); do
        name=${names[$i]}
        delay=${delays[$i]}
        if [ "$enabled" = true ]; then
            [ "$delay" -le $((fastest + tolerance)) ] || continue
            rank=$(_ha_region_rank "$name" "$order")
        else
            rank=0
        fi
        if [ -z "$best" ] || [ "$rank" -lt "$best_rank" ] || { [ "$rank" -eq "$best_rank" ] && [ "$delay" -lt "$best_delay" ]; }; then
            best=$name
            best_delay=$delay
            best_rank=$rank
        fi
    done
    [ -n "$best" ] && printf '%s\t%s\n' "$best" "$best_delay"
}

_ha_check_once() {
    service_is_active >/dev/null 2>&1 || return 1
    local group url confirm_url timeout current best='' best_delay='' current_delay=''
    local name delay failures candidate candidate_count now mode hold_until reason=healthy
    local region_enabled region_tolerance region_order delay_rows
    group=$(_ha_get '.group' '"HA-AUTO"')
    url=$(_ha_get '.check-url' '"http://www.gstatic.com/generate_204"')
    confirm_url=$(_ha_get '.confirm-url' '"https://cp.cloudflare.com/generate_204"')
    timeout=$(_ha_get '.timeout' '5000')
    current=$(_node_now "$group")
    [ -n "$current" ] || return 1

    local members=()
    while IFS= read -r name; do
        [ -n "$name" ] && members+=("$name")
    done < <(_node_members "$group")
    [ ${#members[@]} -gt 0 ] || return 1

    region_enabled=$(_ha_get '.region-preference.enabled' 'true')
    region_tolerance=$(_ha_get '.region-preference.tolerance' '100')
    region_order=$(_ha_get '(.region-preference.order // ["taiwan", "japan", "hong-kong", "other"]) | join(",")' '"taiwan,japan,hong-kong,other"')
    delay_rows=$(_node_delay_rows "$group" "$url" "$timeout" "${members[@]}")
    while IFS=$'\t' read -r name delay; do
        [[ "$delay" =~ ^[0-9]+$ ]] && [ "$delay" -gt 0 ] || continue
        [ "$name" = "$current" ] && current_delay=$delay
    done <<<"$delay_rows"
    IFS=$'\t' read -r best best_delay < <(_ha_select_best "$region_tolerance" "$region_order" "$region_enabled" <<<"$delay_rows")

    failures=$(_ha_state_get '.failures' '0')
    candidate=$(_ha_state_get '.candidate' '""')
    candidate_count=$(_ha_state_get '."candidate-count"' '0')
    now=$(date +%s)
    mode=$(_ha_get '.mode' '"auto"')
    hold_until=$(_ha_get '."hold-until"' '0')

    if [ "$mode" = hold ] && [ "$hold_until" -gt 0 ] && [ "$now" -ge "$hold_until" ]; then
        "$BIN_YQ" -i '.mode = "auto" | ."hold-until" = 0' "$CLASH_HA_CONFIG"
        mode=auto
    fi

    if [ -z "$current_delay" ]; then
        local confirm
        confirm=$(_node_delay_one "$current" "timeout=${timeout}&url=$(_node_urlencode "$confirm_url")" | cut -f2)
        if [[ "$confirm" =~ ^[0-9]+$ ]] && [ "$confirm" -gt 0 ]; then
            failures=0
            reason="主探测目标失败，确认目标正常"
        else
            failures=$((failures + 1))
            reason="当前节点探测失败 ${failures} 次"
            if _ha_mode_allows_failure_switch "$mode" && [ -n "$best" ] && [ "$failures" -ge "$(_ha_get '.failure-confirmations' '2')" ]; then
                _node_apply "$group" "$best" >/dev/null && {
                    reason="故障切换：$current -> $best"
                    _ha_log "$reason"
                    failures=0
                    current=$best
                    current_delay=$best_delay
                    candidate=''
                    candidate_count=0
                    _ha_write_state "$now" "$current" "$current_delay" "$best" "$best_delay" "$failures" "$candidate" "$candidate_count" "$reason"
                    _ha_record_switch "$now" "$reason"
                    return 0
                }
            fi
        fi
    else
        failures=0
        if _ha_mode_allows_performance_switch "$mode" && [ -n "$best" ] && [ "$best" != "$current" ]; then
            local abs rel required improvement last_switch cooldown confirmations
            local current_region_rank best_region_rank region_preferred=false switch_kind=performance
            abs=$(_ha_get '.absolute-improvement' '80')
            rel=$(_ha_get '.relative-improvement' '30')
            required=$((current_delay * rel / 100))
            [ "$required" -lt "$abs" ] && required=$abs
            improvement=$((current_delay - best_delay))
            last_switch=$(_ha_state_get '."last-switch"' '0')
            cooldown=$(_ha_get '.cooldown' '600')
            confirmations=$(_ha_get '.performance-confirmations' '3')
            current_region_rank=$(_ha_region_rank "$current" "$region_order")
            best_region_rank=$(_ha_region_rank "$best" "$region_order")
            if [ "$region_enabled" = true ] && [ "$best_region_rank" -lt "$current_region_rank" ] && [ "$best_delay" -le $((current_delay + region_tolerance)) ]; then
                region_preferred=true
                switch_kind=region
            fi
            if { [ "$region_preferred" = true ] || [ "$improvement" -ge "$required" ]; } && [ $((now - last_switch)) -ge "$cooldown" ]; then
                if [ "$candidate" = "$best" ] || { [ "$switch_kind" = region ] && [ -n "$candidate" ] && _ha_same_region "$candidate" "$best"; }; then
                    candidate=$best
                    candidate_count=$((candidate_count + 1))
                else
                    candidate=$best
                    candidate_count=1
                fi
                if [ "$switch_kind" = region ]; then
                    reason="地区优先候选（相差 ${improvement#-}ms），确认 ${candidate_count}/${confirmations}"
                else
                    reason="候选改善 ${improvement}ms，确认 ${candidate_count}/${confirmations}"
                fi
                if [ "$candidate_count" -ge "$confirmations" ]; then
                    _node_apply "$group" "$best" >/dev/null && {
                        if [ "$switch_kind" = region ]; then
                            reason="地区优先切换：$current(${current_delay}ms) -> $best(${best_delay}ms)"
                        else
                            reason="性能切换：$current(${current_delay}ms) -> $best(${best_delay}ms)"
                        fi
                        _ha_log "$reason"
                        current=$best
                        current_delay=$best_delay
                        candidate=''
                        candidate_count=0
                        _ha_write_state "$now" "$current" "$current_delay" "$best" "$best_delay" 0 "$candidate" "$candidate_count" "$reason"
                        _ha_record_switch "$now" "$reason"
                        return 0
                    }
                fi
            else
                candidate=''
                candidate_count=0
                reason="延迟差未达到切换阈值"
            fi
        elif [ "$mode" != auto ]; then
            reason="人工模式：$mode"
        fi
    fi
    _ha_write_state "$now" "$current" "$current_delay" "$best" "$best_delay" "$failures" "$candidate" "$candidate_count" "$reason"
    if _ha_mode_allows_failure_switch "$mode" && [ -z "$best" ] && [ "$failures" -ge "$(_ha_get '.failure-confirmations' '2')" ]; then
        _ha_recover "$now"
    fi
}

_ha_recover() {
    local now=$1 last
    last=$(_ha_get '."last-recovery"' '0')
    [ $((now - last)) -ge 600 ] || return 0
    LAST_RECOVERY=$now "$BIN_YQ" -i '."last-recovery" = (env(LAST_RECOVERY) | tonumber)' "$CLASH_HA_CONFIG"
    _ha_log "全部候选不可用，尝试更新所有订阅并重建候选池"
    _sub_update --all >>"$CLASH_HA_LOG" 2>&1 || true
    _ha_build_and_restart >>"$CLASH_HA_LOG" 2>&1 || _ha_log "ERROR 自动恢复重建失败"
}

_ha_daemon() {
    _ha_enabled || return 0
    if [ -f "$CLASH_HA_PID" ] && kill -0 "$(cat "$CLASH_HA_PID" 2>/dev/null)" 2>/dev/null; then
        _errorcat "HA 调度器已运行"
        return 1
    fi
    printf '%s\n' "$$" >"$CLASH_HA_PID"
    trap '/usr/bin/rm -f "$CLASH_HA_PID"' EXIT INT TERM
    _ha_log "HA 调度器启动"
    while _ha_enabled; do
        _ha_check_once || _ha_log "WARN 本轮检测失败，等待内核/API 就绪"
        sleep "$(_ha_get '.interval' '30')" & wait $!
    done
}

_ha_install_daemon() {
    [ -f "$CLASH_HA_PID" ] && kill -0 "$(cat "$CLASH_HA_PID" 2>/dev/null)" 2>/dev/null && return 0
    detect_service_manager
    if [ "$service_manager" = systemd ] && _is_root; then
        local unit=/etc/systemd/system/clashctl-ha.service
        {
            printf '%s\n' '[Unit]' 'Description=clashctl multi-subscription HA selector' "After=${CLASHCTL_KERNEL}.service network-online.target" "Requires=${CLASHCTL_KERNEL}.service" '' '[Service]' 'Type=simple'
            printf 'ExecStart=/bin/bash -c '\''export CLASHCTL_HOME="%s"; . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"; clashctl ha daemon'\''\n' "$CLASHCTL_HOME"
            printf '%s\n' 'Restart=always' 'RestartSec=5' '' '[Install]' 'WantedBy=multi-user.target'
        } >"$unit"
        systemctl daemon-reload && systemctl enable --now clashctl-ha.service
    else
        nohup env CLASHCTL_HOME="$CLASHCTL_HOME" bash -c '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"; clashctl ha daemon' >"$CLASH_HA_LOG" 2>&1 &
    fi
}

_ha_ensure_services() {
    _ha_enabled || return 0
    _ha_install_daemon || _ha_log "WARN 无法启动 HA 调度器"
    "$BIN_YQ" -e '.lan.enabled == true' "$CLASH_HA_CONFIG" >/dev/null 2>&1 || return 0
    _ha_client_config
    _ha_start_subscription_server || _ha_log "WARN 无法启动客户端订阅服务"
}

_ha_stop_daemon() {
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files clashctl-ha.service >/dev/null 2>&1; then
        systemctl disable --now clashctl-ha.service >/dev/null 2>&1 || true
    fi
    [ -f "$CLASH_HA_PID" ] && kill "$(cat "$CLASH_HA_PID" 2>/dev/null)" 2>/dev/null || true
    /usr/bin/rm -f "$CLASH_HA_PID"
}

_ha_client_config() {
    local server port user password
    server=$(_ha_get '.lan.server' '""')
    port=$(_ha_get '.lan.port' '7890')
    user=$(_ha_get '.lan.username' '""')
    password=$(_ha_get '.lan.password' '""')
    [ -n "$server" ] || server=$(_get_local_ip)
    LAN_SERVER=$server LAN_PORT=$port LAN_USER=$user LAN_PASSWORD=$password "$BIN_YQ" -n '
      {"mixed-port": 7890, "allow-lan": false, "mode": "rule",
       "proxies": [{"name": "LAN-HA", "type": "http", "server": strenv(LAN_SERVER),
         "port": (env(LAN_PORT) | tonumber), "username": strenv(LAN_USER), "password": strenv(LAN_PASSWORD)}],
       "proxy-groups": [{"name": "PROXY", "type": "select", "proxies": ["LAN-HA"]}],
       "rules": ["IP-CIDR,10.0.0.0/8,DIRECT,no-resolve", "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
         "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve", "MATCH,PROXY"]}
    ' >"$CLASH_HA_CLIENT_CONFIG"
    chmod 600 "$CLASH_HA_CLIENT_CONFIG"
}

_ha_start_subscription_server() {
    command -v python3 >/dev/null 2>&1 || {
        _errorcat "未找到 python3，无法启动局域网订阅服务"
        return 1
    }
    local port token cidr
    port=$(_ha_get '.lan.subscription-port' '8088')
    token=$(_ha_get '.lan.subscription-token' '""')
    cidr=$(_ha_get '.lan.allowed-cidr' '"192.168.0.0/16"')
    [ -n "$token" ] || return 1
    printf '%s\n' "$token" >"$CLASH_HA_SUB_TOKEN"
    chmod 600 "$CLASH_HA_SUB_TOKEN" "$CLASH_HA_CONFIG"
    _ha_stop_subscription_server
    detect_service_manager
    if [ "$service_manager" = systemd ] && _is_root; then
        local unit=/etc/systemd/system/clashctl-ha-sub.service python_path
        python_path=$(command -v python3)
        {
            printf '%s\n' '[Unit]' 'Description=clashctl LAN subscription server' 'After=network-online.target' '' '[Service]' 'Type=simple'
            printf 'ExecStart="%s" "%s" --port %s --token-file "%s" --file "%s" --cidr "%s"\n' "$python_path" "$CLASHCTL_HOME/scripts/ha/serve.py" "$port" "$CLASH_HA_SUB_TOKEN" "$CLASH_HA_CLIENT_CONFIG" "$cidr"
            printf '%s\n' 'Restart=always' 'RestartSec=5' '' '[Install]' 'WantedBy=multi-user.target'
        } >"$unit"
        systemctl daemon-reload && systemctl enable --now clashctl-ha-sub.service
    else
        nohup python3 "$CLASHCTL_HOME/scripts/ha/serve.py" --port "$port" --token-file "$CLASH_HA_SUB_TOKEN" --file "$CLASH_HA_CLIENT_CONFIG" --cidr "$cidr" \
          >>"$CLASH_HA_LOG" 2>&1 &
        printf '%s\n' "$!" >"$CLASH_HA_SUB_PID"
    fi
}

_ha_stop_subscription_server() {
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files clashctl-ha-sub.service >/dev/null 2>&1; then
        systemctl disable --now clashctl-ha-sub.service >/dev/null 2>&1 || true
    fi
    [ -f "$CLASH_HA_SUB_PID" ] && kill "$(cat "$CLASH_HA_SUB_PID" 2>/dev/null)" 2>/dev/null || true
    /usr/bin/rm -f "$CLASH_HA_SUB_PID"
}

_ha_lan_enable() {
    local cidr=${1:-192.168.0.0/16} user=${2:-clash} advertised_server=${3:-} password=${CLASHCTL_LAN_PASSWORD:-}
    command -v python3 >/dev/null 2>&1 || {
        _errorcat "局域网订阅服务需要 python3，请安装后重试"
        return 1
    }
    python3 -c 'import ipaddress,sys; ipaddress.ip_network(sys.argv[1], strict=False)' "$cidr" >/dev/null 2>&1 || {
        _errorcat "无效的局域网 CIDR：$cidr"
        return 1
    }
    [ -n "$password" ] || password=$(_ha_random 18)
    local server token port
    server=$advertised_server
    [ -n "$server" ] || server=$(_get_local_ip)
    [ -n "$server" ] || {
        _errorcat "无法检测 Linux 局域网 IP，请检查默认路由和网卡地址"
        return 1
    }
    token=$(_ha_random 32)
    port=$(_ha_get '.lan.port' '7890')
    CIDR=$cidr USERNAME=$user PASSWORD=$password SERVER=$server TOKEN=$token "$BIN_YQ" -i '
      .lan.enabled = true | .lan."allowed-cidr" = strenv(CIDR) |
      .lan.username = strenv(USERNAME) | .lan.password = strenv(PASSWORD) |
      .lan.server = strenv(SERVER) | .lan."subscription-token" = strenv(TOKEN)
    ' "$CLASH_HA_CONFIG"
    CIDR=$cidr USERNAME=$user PASSWORD=$password "$BIN_YQ" -i '
      ."allow-lan" = true | ."bind-address" = "*" |
      ."lan-allowed-ips" = [strenv(CIDR)] | .authentication = [strenv(USERNAME) + ":" + strenv(PASSWORD)] |
      ."external-controller" = "127.0.0.1:9090"
    ' "$CLASH_CONFIG_MIXIN"
    _merge_config_restart || return 1
    chmod 600 "$CLASH_HA_CONFIG" "$CLASH_CONFIG_MIXIN" "$CLASH_CONFIG_RUNTIME"
    _ha_client_config
    _ha_start_subscription_server || return 1
    _okcat "局域网代理：http://${server}:${port}（用户：$user，密码：$password）"
    _okcat "客户端订阅：http://${server}:$(_ha_get '.lan.subscription-port' '8088')/sub/${token}"
}

_ha_status() {
    printf 'HA：%s\n' "$(if _ha_enabled; then printf '启用'; else printf '停用'; fi)"
    if [ -f "$CLASH_HA_PID" ] && kill -0 "$(cat "$CLASH_HA_PID" 2>/dev/null)" 2>/dev/null; then
        printf '调度器：运行中\n'
    else
        printf '调度器：未运行\n'
    fi
    printf '模式：%s\n' "$(_ha_get '.mode' '"auto"')"
    printf '策略组：%s\n' "$(_ha_get '.group' '"HA-AUTO"')"
    printf '当前节点：%s (%sms)\n' "$(_ha_state_get '.current' '"—"')" "$(_ha_state_get '."current-delay"' '"—"')"
    printf '本轮最优：%s (%sms)\n' "$(_ha_state_get '.best' '"—"')" "$(_ha_state_get '."best-delay"' '"—"')"
    printf '最近判断：%s\n' "$(_ha_state_get '."last-reason"' '"尚未检测"')"
    printf '检测时间：%s\n' "$(_ha_state_get '."checked-at"' '"—"')"
    if "$BIN_YQ" -e '.lan.enabled == true' "$CLASH_HA_CONFIG" >/dev/null 2>&1; then
        printf '局域网代理：http://%s:%s\n' "$(_ha_get '.lan.server' '""')" "$(_ha_get '.lan.port' '7890')"
        printf '客户端订阅：http://%s:%s/sub/%s\n' "$(_ha_get '.lan.server' '""')" "$(_ha_get '.lan."subscription-port"' '8088')" "$(_ha_get '.lan."subscription-token"' '""')"
    fi
}

clashha() {
    [ -f "$CLASH_HA_CONFIG" ] || {
        _errorcat "缺少 HA 配置：$CLASH_HA_CONFIG"
        return 1
    }
    case "${1:-status}" in
    enable)
        _sub_migrate
        ENABLED=true "$BIN_YQ" -i '.enabled = true' "$CLASH_HA_CONFIG"
        _ha_build_and_restart || { "$BIN_YQ" -i '.enabled = false' "$CLASH_HA_CONFIG"; return 1; }
        _ha_install_daemon && _okcat "HA 自动优选已启用"
        ;;
    disable)
        "$BIN_YQ" -i '.enabled = false' "$CLASH_HA_CONFIG"
        _ha_stop_daemon
        local current
        current=$(_sub_current)
        [ -n "$current" ] && _sub_use_locked "$current"
        _okcat "HA 已停用"
        ;;
    refresh)
        [ "${2:-}" = --update ] && _sub_update --all
        _ha_build_and_restart
        ;;
    check) _ha_check_once && _ha_status ;;
    status) _ha_status ;;
    daemon) _ha_daemon ;;
    hold)
        local minutes=${2:-60}
        [[ "$minutes" =~ ^[0-9]+$ ]] || { _errorcat "分钟必须为整数"; return 1; }
        local until=$(( $(date +%s) + minutes * 60 ))
        HOLD_UNTIL=$until "$BIN_YQ" -i '.mode = "hold" | ."hold-until" = (env(HOLD_UNTIL) | tonumber)' "$CLASH_HA_CONFIG"
        _okcat "已进入稳定模式 ${minutes} 分钟；故障仍会切换"
        ;;
    resume) "$BIN_YQ" -i '.mode = "auto" | ."hold-until" = 0' "$CLASH_HA_CONFIG"; _okcat "已恢复自动优选" ;;
    pin)
        [ -n "${2:-}" ] || { _errorcat "用法：clashctl ha pin <节点全名>"; return 1; }
        _node_apply "$(_ha_get '.group' '"HA-AUTO"')" "$2" || return 1
        "$BIN_YQ" -i '.mode = "pin"' "$CLASH_HA_CONFIG"
        ;;
    unpin) "$BIN_YQ" -i '.mode = "auto"' "$CLASH_HA_CONFIG"; _okcat "已解除严格固定" ;;
    lan)
        case "${2:-}" in
        enable) _ha_lan_enable "${3:-}" "${4:-}" "${5:-}" ;;
        disable)
            "$BIN_YQ" -i '.lan.enabled = false' "$CLASH_HA_CONFIG"
            "$BIN_YQ" -i '."allow-lan" = false | ."lan-allowed-ips" = [] | .authentication = []' "$CLASH_CONFIG_MIXIN"
            _ha_stop_subscription_server
            _merge_config_restart && _okcat "局域网入口已关闭"
            ;;
        *) _errorcat "用法：clashctl ha lan enable [CIDR] [用户名] [对外服务器地址] | disable" ;;
        esac
        ;;
    log) tail "${@:2}" "$CLASH_HA_LOG" ;;
    -h | --help | help)
        cat <<EOF

clashctl ha - 多订阅高可用

  enable                  聚合全部订阅并启动自动优选
  disable                 停用 HA，恢复当前单订阅
  refresh [--update]      重建候选池；--update 先更新全部订阅
  check                   立即检测一次
  status                  查看当前状态
  hold [分钟]             暂停性能切换，故障仍切换（默认 60 分钟）
  resume                  恢复自动优选
  pin <节点全名>          严格固定节点，故障也不切换
  unpin                   解除严格固定
  lan enable [CIDR] [用户] [地址] 开启局域网代理和客户端订阅
  lan disable             关闭局域网入口
  log [-n 行数]           查看 HA 日志

EOF
        ;;
    *) _errorcat "未知 HA 子命令：$1" ;;
    esac
}
