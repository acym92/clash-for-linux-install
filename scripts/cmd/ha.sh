#!/usr/bin/env bash

# Multi-subscription high availability. Runtime selection is performed through
# the controller API, so normal failover does not restart Mihomo.

_ha_get() {
    "$BIN_YQ" "$1 // $2" "$CLASH_HA_CONFIG" 2>/dev/null
}

_ha_enabled() {
    [ -f "$CLASH_HA_CONFIG" ] && "$BIN_YQ" -e '.enabled == true' "$CLASH_HA_CONFIG" >/dev/null 2>&1
}

_ha_pid_running() {
    local pid=${1:-} expected=${2:-} stat state args=()
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [ -r "/proc/$pid/stat" ] || return 1
    stat=$(<"/proc/$pid/stat")
    state=${stat#*) }
    state=${state%% *}
    [ "$state" != Z ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    [ -z "$expected" ] && return 0
    mapfile -d '' args <"/proc/$pid/cmdline" 2>/dev/null || return 1
    [[ " ${args[*]} " == *"$expected"* ]]
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

    local template_name template_path group ha_domains codex_enabled codex_group codex_auto_group codex_domains codex_mode codex_pinned codex_first
    local fallback_enabled fallback_local_group fallback_count nodes upstreams part work name path count=0
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
    ha_domains=$(_ha_get '(.ha-domains // []) | join(",")' '""')
    codex_enabled=$(_ha_get '.codex.enabled' 'false')
    codex_group=$(_ha_get '.codex.group' '"CODEX"')
    codex_auto_group=$(_ha_get '.codex.auto-group' '"CODEX-HA"')
    codex_mode=$(_ha_get '.codex.mode' '"auto"')
    codex_pinned=$(_ha_get '.codex."pinned-node"' '""')
    codex_domains=$(_ha_get '(.codex.domains // ["chatgpt.com", "openai.com", "oaistatic.com", "oaiusercontent.com"]) | join(",")' '"chatgpt.com,openai.com,oaistatic.com,oaiusercontent.com"')
    fallback_enabled=$(_ha_get '.fallback.enabled' 'false')
    fallback_local_group=$(_ha_get '.fallback."local-group"' '"HA-LOCAL"')
    nodes=$(mktemp "${CLASH_RESOURCES_DIR}/.ha-nodes.XXXXXX") || return 1
    upstreams=$(mktemp "${CLASH_RESOURCES_DIR}/.ha-upstreams.XXXXXX") || {
        /usr/bin/rm -f "$nodes"
        return 1
    }
    part=$(mktemp "${CLASH_RESOURCES_DIR}/.ha-part.XXXXXX") || {
        /usr/bin/rm -f "$nodes" "$upstreams"
        return 1
    }
    work=$(mktemp "${CLASH_RESOURCES_DIR}/.ha-config.XXXXXX") || {
        /usr/bin/rm -f "$nodes" "$upstreams" "$part"
        return 1
    }
    printf '[]\n' >"$nodes"
    "$BIN_YQ" '[.fallback.upstreams[]? |
      select(.name != null and .name != "" and .server != null and .server != "" and .port != null) |
      select(.type == "http" or .type == "socks5") |
      .port = (.port | tonumber)]' "$CLASH_HA_CONFIG" >"$upstreams" || printf '[]\n' >"$upstreams"
    fallback_count=$("$BIN_YQ" 'length' "$upstreams" 2>/dev/null)
    if [ "$fallback_enabled" = true ] && [ "${fallback_count:-0}" -eq 0 ]; then
        /usr/bin/rm -f "$nodes" "$upstreams" "$part" "$work"
        _errorcat "外部备用已启用，但没有有效的 http/socks5 上游"
        return 1
    fi

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
        /usr/bin/rm -f "$nodes" "$upstreams" "$part" "$work"
        _errorcat "所有订阅都没有可聚合的内联节点（proxy-providers 格式暂不支持）"
        return 1
    }

    codex_first=$codex_auto_group
    if [ "$codex_mode" = fixed ] && [ -n "$codex_pinned" ] && PINNED=$codex_pinned "$BIN_YQ" -e 'map(select(.name == strenv(PINNED))) | length > 0' "$nodes" >/dev/null 2>&1; then
        codex_first=$codex_pinned
    fi
    HA_GROUP=$group HA_DOMAINS=$ha_domains CODEX_ENABLED=$codex_enabled CODEX_GROUP=$codex_group CODEX_AUTO_GROUP=$codex_auto_group CODEX_FIRST=$codex_first CODEX_DOMAINS=$codex_domains \
      FALLBACK_ENABLED=$fallback_enabled FALLBACK_LOCAL_GROUP=$fallback_local_group NODES_FILE=$nodes FALLBACKS_FILE=$upstreams "$BIN_YQ" '
      load(strenv(NODES_FILE)) as $nodes |
      load(strenv(FALLBACKS_FILE)) as $fallbacks |
      strenv(HA_GROUP) as $ha |
      strenv(FALLBACK_LOCAL_GROUP) as $local |
      strenv(CODEX_GROUP) as $codex |
      strenv(CODEX_AUTO_GROUP) as $codexAuto |
      (strenv(CODEX_ENABLED) == "true") as $codexEnabled |
      (strenv(FALLBACK_ENABLED) == "true") as $fallbackEnabled |
      (($fallbacks | map(.name)) | select($fallbackEnabled) // []) as $fallbackNames |
      .profile."store-selected" = true |
      .proxies = ($nodes + (($fallbacks | select($fallbackEnabled)) // [])) |
      (.proxy-groups // []) as $old |
      .proxy-groups = (
        ($old | map(select(.name != $ha and .name != $local and .name != $codex and .name != $codexAuto and .name != "CODEX-PROBE") |
          {"name": .name, "type": "select", "proxies": [$ha]})) +
        (([{"name": $ha, "type": "select", "proxies": ([$local] + $fallbackNames)},
           {"name": $local, "type": "select", "hidden": true, "proxies": ($nodes | map(.name))}]
          | select($fallbackEnabled)) //
         [{"name": $ha, "type": "select", "proxies": ($nodes | map(.name))}]) +
        ((
          [{"name": $codex, "type": "select", "proxies": ([strenv(CODEX_FIRST)] + (([$codexAuto] + ($nodes | map(.name)) + $fallbackNames) | map(select(. != strenv(CODEX_FIRST)))))},
           {"name": $codexAuto, "type": "select", "hidden": true, "proxies": ($nodes | map(.name))}]
          | select($codexEnabled)
        ) // [])
      ) |
      .listeners = ((.listeners // []) | map(select(.name != "codex-ha-probe"))) |
      .rules = ((.rules // []) as $rules |
        (($rules | select(length > 0)) // ["MATCH," + $ha]) as $baseRules |
        (strenv(HA_DOMAINS) | split(",") | map(select(length > 0) | "DOMAIN," + . + "," + $ha)) as $haRules |
        ((((strenv(CODEX_DOMAINS) | split(",") | map("DOMAIN-SUFFIX," + . + "," + $codex)) + $haRules + $baseRules)
          | select($codexEnabled)) // ($haRules + $baseRules)))
    ' "$template_path" >"$work"
    /usr/bin/rm -f "$nodes" "$upstreams" "$part"

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
    local last_switch route fallback_node fallback_since recovery_count fallback_codex_managed
    last_switch=$(_ha_state_get '."last-switch"' '0')
    route=$(_ha_state_get '.route' '"local"')
    fallback_node=$(_ha_state_get '."fallback-node"' '""')
    fallback_since=$(_ha_state_get '."fallback-since"' '0')
    recovery_count=$(_ha_state_get '."recovery-count"' '0')
    fallback_codex_managed=$(_ha_state_get '."fallback-codex-managed"' 'false')
    CHECKED=$now CURRENT=$current CURRENT_DELAY=$current_delay BEST=$best BEST_DELAY=$best_delay \
      FAILURES=$failures CANDIDATE=$candidate CANDIDATE_COUNT=$candidate_count REASON=$reason LAST_SWITCH=$last_switch \
      ROUTE=$route FALLBACK_NODE=$fallback_node FALLBACK_SINCE=$fallback_since RECOVERY_COUNT=$recovery_count FALLBACK_CODEX_MANAGED=$fallback_codex_managed \
      "$BIN_YQ" -n '
        {"checked-at": strenv(CHECKED), "current": strenv(CURRENT),
         "current-delay": strenv(CURRENT_DELAY), "best": strenv(BEST),
         "best-delay": strenv(BEST_DELAY), "failures": (env(FAILURES) | tonumber),
         "candidate": strenv(CANDIDATE), "candidate-count": (env(CANDIDATE_COUNT) | tonumber),
         "last-reason": strenv(REASON), "last-switch": (env(LAST_SWITCH) | tonumber),
         "route": strenv(ROUTE), "fallback-node": strenv(FALLBACK_NODE),
         "fallback-since": (env(FALLBACK_SINCE) | tonumber), "recovery-count": (env(RECOVERY_COUNT) | tonumber),
         "fallback-codex-managed": (strenv(FALLBACK_CODEX_MANAGED) == "true")}
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

_ha_fallback_enabled() {
    [ "$(_ha_get '.fallback.enabled' 'false')" = true ] &&
      [ "$(_ha_get '(.fallback.upstreams // []) | length' '0')" -gt 0 ]
}

_ha_local_group() {
    if _ha_fallback_enabled; then
        _ha_get '.fallback."local-group"' '"HA-LOCAL"'
    else
        _ha_get '.group' '"HA-AUTO"'
    fi
}

_ha_fallback_is_node() {
    local node=$1
    [ -n "$node" ] || return 1
    NODE=$node "$BIN_YQ" -e '.fallback.upstreams[]? | select(.name == strenv(NODE))' "$CLASH_HA_CONFIG" >/dev/null 2>&1
}

_ha_fallback_proxy_status_ok() {
    local name=$1 url=$2 expected=$3 timeout_ms=$4 row type server port user password code timeout_sec
    row=$(NAME=$name "$BIN_YQ" -r '.fallback.upstreams[]? | select(.name == strenv(NAME)) |
      [.type, .server, (.port | tostring), (.username // ""), (.password // "")] | @tsv' "$CLASH_HA_CONFIG" 2>/dev/null | head -n1)
    [ -n "$row" ] || return 1
    IFS=$'\t' read -r type server port user password <<<"$row"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    timeout_sec=$(( (timeout_ms + 999) / 1000 ))
    local args=(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout "$timeout_sec" --max-time "$timeout_sec" -H 'Connection: close')
    case $type in
    http) args+=(--proxy "http://${server}:${port}") ;;
    socks5) args+=(--socks5-hostname "${server}:${port}") ;;
    *) return 1 ;;
    esac
    [ -z "$user" ] && [ -z "$password" ] || args+=(--proxy-user "${user}:${password}")
    code=$("${args[@]}" "$url" 2>/dev/null) || return 1
    [ "$code" = "$expected" ]
}

_ha_fallback_choose() {
    _ha_fallback_enabled || return 1
    local check_url confirm_url check_expected confirm_expected timeout name
    check_url=$(_ha_get '.fallback."check-url"' '"http://www.gstatic.com/generate_204"')
    confirm_url=$(_ha_get '.fallback."confirm-url"' '"https://cp.cloudflare.com/generate_204"')
    check_expected=$(_ha_get '.fallback."check-expected-status"' '204')
    confirm_expected=$(_ha_get '.fallback."confirm-expected-status"' '204')
    timeout=$(_ha_get '.fallback.timeout' '5000')
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        _ha_fallback_proxy_status_ok "$name" "$check_url" "$check_expected" "$timeout" || continue
        _ha_fallback_proxy_status_ok "$name" "$confirm_url" "$confirm_expected" "$timeout" || continue
        printf '%s\n' "$name"
        return 0
    done < <("$BIN_YQ" -r '.fallback.upstreams[]?.name' "$CLASH_HA_CONFIG" 2>/dev/null)
    return 1
}

_ha_fallback_state_set() {
    local route=$1 node=$2 since=$3 recovery_count=$4 codex_managed=$5
    ROUTE=$route FALLBACK_NODE=$node FALLBACK_SINCE=$since RECOVERY_COUNT=$recovery_count FALLBACK_CODEX_MANAGED=$codex_managed \
      "$BIN_YQ" -i '.route = strenv(ROUTE) | ."fallback-node" = strenv(FALLBACK_NODE) |
        ."fallback-since" = (env(FALLBACK_SINCE) | tonumber) | ."recovery-count" = (env(RECOVERY_COUNT) | tonumber) |
        ."fallback-codex-managed" = (strenv(FALLBACK_CODEX_MANAGED) == "true")' "$CLASH_HA_STATE"
}

_ha_fallback_apply() {
    local node=$1 entry codex_entry codex_auto codex_selected codex_managed=false
    entry=$(_ha_get '.group' '"HA-AUTO"')
    _node_apply "$entry" "$node" >/dev/null || return 1
    if _ha_codex_enabled && [ "$(_ha_get '.codex.mode' '"auto"')" = auto ]; then
        codex_entry=$(_ha_get '.codex.group' '"CODEX"')
        codex_auto=$(_ha_get '.codex."auto-group"' '"CODEX-HA"')
        codex_selected=$(_node_now "$codex_entry")
        if [ "$codex_selected" = "$codex_auto" ]; then
            _node_apply "$codex_entry" "$node" >/dev/null && codex_managed=true
        fi
    fi
    printf '%s\n' "$codex_managed"
}

_ha_fallback_restore() {
    local best=$1 codex_managed=$2 local_group entry codex_entry codex_auto codex_selected
    local_group=$(_ha_local_group)
    entry=$(_ha_get '.group' '"HA-AUTO"')
    _node_apply "$local_group" "$best" >/dev/null || return 1
    _node_apply "$entry" "$local_group" >/dev/null || return 1
    if [ "$codex_managed" = true ] && _ha_codex_enabled; then
        codex_entry=$(_ha_get '.codex.group' '"CODEX"')
        codex_auto=$(_ha_get '.codex."auto-group"' '"CODEX-HA"')
        codex_selected=$(_node_now "$codex_entry")
        _ha_fallback_is_node "$codex_selected" && _node_apply "$codex_entry" "$codex_auto" >/dev/null || true
    fi
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

_ha_codex_enabled() {
    _ha_enabled && [ "$(_ha_get '.codex.enabled' 'false')" = true ]
}

_ha_codex_state_get() {
    [ -f "$CLASH_HA_CODEX_STATE" ] || {
        "$BIN_YQ" -n "$2" 2>/dev/null
        return
    }
    "$BIN_YQ" "$1 // $2" "$CLASH_HA_CODEX_STATE" 2>/dev/null
}

_ha_codex_write_state() {
    local now=$1 current=$2 current_delay=$3 best=$4 best_delay=$5 failures=$6 candidate=$7 candidate_count=$8 reason=$9
    local last_switch
    last_switch=$(_ha_codex_state_get '."last-switch"' '0')
    CHECKED=$now CURRENT=$current CURRENT_DELAY=$current_delay BEST=$best BEST_DELAY=$best_delay \
      FAILURES=$failures CANDIDATE=$candidate CANDIDATE_COUNT=$candidate_count REASON=$reason LAST_SWITCH=$last_switch \
      "$BIN_YQ" -n '
        {"checked-at": (env(CHECKED) | tonumber), "current": strenv(CURRENT),
         "current-delay": strenv(CURRENT_DELAY), "best": strenv(BEST),
         "best-delay": strenv(BEST_DELAY), "failures": (env(FAILURES) | tonumber),
         "candidate": strenv(CANDIDATE), "candidate-count": (env(CANDIDATE_COUNT) | tonumber),
         "last-reason": strenv(REASON), "last-switch": (env(LAST_SWITCH) | tonumber)}
      ' >"${CLASH_HA_CODEX_STATE}.new" && /bin/mv -f "${CLASH_HA_CODEX_STATE}.new" "$CLASH_HA_CODEX_STATE"
}

_ha_codex_record_switch() {
    local now=$1 reason=$2
    SWITCH_AT=$now SWITCH_REASON=$reason "$BIN_YQ" -i \
      '."last-switch" = (env(SWITCH_AT) | tonumber) | ."last-reason" = strenv(SWITCH_REASON)' "$CLASH_HA_CODEX_STATE"
}

# Verify the real HTTP status through the configured local proxy port.
_ha_codex_http_status_ok() {
    local host=$1 port=$2 url=$3 expected=$4 timeout_ms=$5 code timeout_sec
    timeout_sec=$(( (timeout_ms + 999) / 1000 ))
    code=$(curl -sS -o /dev/null -w '%{http_code}' --proxy "http://${host}:${port}" \
        --connect-timeout "$timeout_sec" --max-time "$timeout_sec" \
        -H 'Connection: close' "$url" 2>/dev/null) || return 1
    [ "$code" = "$expected" ]
}

# The delay API is used only to create a bounded shortlist. When no Codex
# connections are active, candidates are selected and verified one at a time;
# the original selection is restored before returning.
_ha_codex_healthy_rows() {
    local group=$1 current=$2 check_url=$3 check_expected=$4 confirm_url=$5 confirm_expected=$6 timeout=$7
    shift 7
    local members=("$@") latency_rows proxy_host proxy_port probe_limit name delay
    local shortlist=()
    proxy_host=$(_ha_get '.lan.server' '"127.0.0.1"')
    [ -n "$proxy_host" ] || proxy_host=127.0.0.1
    proxy_port=$("$BIN_YQ" '."mixed-port" // .port // 7890' "$CLASH_CONFIG_RUNTIME" 2>/dev/null)
    probe_limit=$(_ha_get '.codex.probe-limit' '24')
    [[ "$probe_limit" =~ ^[0-9]+$ ]] || probe_limit=24
    latency_rows=$(_node_delay_rows "$group" "$confirm_url" "$timeout" "${members[@]}")
    delay=$(awk -F '\t' -v node="$current" '$1 == node {print $2; exit}' <<<"$latency_rows")
    [[ "$delay" =~ ^[0-9]+$ ]] && [ "$delay" -gt 0 ] && shortlist+=("$current"$'\t'"$delay")
    while IFS=$'\t' read -r name delay; do
        [[ "$delay" =~ ^[0-9]+$ ]] && [ "$delay" -gt 0 ] || continue
        [[ "$name" == *剩余流量* || "$name" == *距离下次重置* || "$name" == *套餐到期* ]] && continue
        [ "$name" = "$current" ] && continue
        shortlist+=("$name"$'\t'"$delay")
        [ "${#shortlist[@]}" -ge "$probe_limit" ] && break
    done < <(sort -t $'\t' -k2,2n <<<"$latency_rows")
    local row
    for row in "${shortlist[@]}"; do
        name=${row%%$'\t'*}
        delay=${row##*$'\t'}
        if [ "$name" != "$current" ] && [ "$(_ha_codex_active_connections)" -gt 0 ]; then
            break
        fi
        _node_apply "$group" "$name" >/dev/null 2>&1 || continue
        _ha_codex_http_status_ok "$proxy_host" "$proxy_port" "$check_url" "$check_expected" "$timeout" || continue
        _ha_codex_http_status_ok "$proxy_host" "$proxy_port" "$confirm_url" "$confirm_expected" "$timeout" || continue
        printf '%s\t%s\n' "$name" "$delay"
    done
    _node_apply "$group" "$current" >/dev/null 2>&1 || true
}

_ha_codex_active_connections() {
    local domains host domain count=0 resp
    domains=$(_ha_get '(.codex.domains // []) | join(",")' '""')
    [ -n "$domains" ] || { printf '0\n'; return; }
    resp=$(_node_curl GET '/connections') || { printf '0\n'; return; }
    while IFS= read -r host; do
        [ -n "$host" ] || continue
        while IFS= read -r domain; do
            [ -n "$domain" ] || continue
            if [ "$host" = "$domain" ] || [[ "$host" == *."$domain" ]]; then
                count=$((count + 1))
                break
            fi
        done < <(tr ',' '\n' <<<"$domains")
    done < <("$BIN_YQ" -p json '.connections[]?.metadata.host // ""' <<<"$resp" 2>/dev/null)
    printf '%s\n' "$count"
}

_ha_codex_check_once() {
    _ha_codex_enabled || return 0
    service_is_active >/dev/null 2>&1 || return 1
    local entry_group entry_selected group check_url check_expected confirm_url confirm_expected timeout current best='' best_delay='' current_delay=''
    local failures candidate candidate_count now mode reason=healthy delay_rows checked_at initialized
    local region_enabled region_tolerance region_order name delay
    entry_group=$(_ha_get '.codex.group' '"CODEX"')
    group=$(_ha_get '.codex.auto-group' '"CODEX-HA"')
    entry_selected=$(_node_now "$entry_group")
    [ -n "$entry_selected" ] || return 1
    if _ha_fallback_enabled && _ha_fallback_is_node "$entry_selected"; then
        now=$(date +%s)
        reason="Codex 随全局出口使用外部备用：$entry_selected"
        _ha_codex_write_state "$now" "$entry_selected" '' "$entry_selected" '' 0 '' 0 "$reason"
        return 0
    fi
    if [ "$entry_selected" != "$group" ]; then
        now=$(date +%s)
        if [ "$(_ha_get '.codex.mode' '"auto"')" != fixed ] || [ "$(_ha_get '.codex."pinned-node"' '""')" != "$entry_selected" ]; then
            PINNED=$entry_selected "$BIN_YQ" -i '.codex.mode = "fixed" | .codex."pinned-node" = strenv(PINNED)' "$CLASH_HA_CONFIG"
        fi
        reason="Codex 固定节点：$entry_selected"
        _ha_codex_write_state "$now" "$entry_selected" '' "$entry_selected" '' 0 '' 0 "$reason"
        return 0
    fi
    if [ "$(_ha_get '.codex.mode' '"auto"')" != auto ] || [ -n "$(_ha_get '.codex."pinned-node"' '""')" ]; then
        "$BIN_YQ" -i '.codex.mode = "auto" | .codex."pinned-node" = ""' "$CLASH_HA_CONFIG"
    fi
    check_url=$(_ha_get '.codex.check-url' '"https://chatgpt.com/robots.txt"')
    check_expected=$(_ha_get '.codex.check-expected-status' '200')
    confirm_url=$(_ha_get '.codex.confirm-url' '"https://api.openai.com/v1/models"')
    confirm_expected=$(_ha_get '.codex.confirm-expected-status' '401')
    timeout=$(_ha_get '.codex.timeout' '8000')
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
    delay_rows=$(_ha_codex_healthy_rows "$group" "$current" "$check_url" "$check_expected" "$confirm_url" "$confirm_expected" "$timeout" "${members[@]}")
    while IFS=$'\t' read -r name delay; do
        [ "$name" = "$current" ] && current_delay=$delay
    done <<<"$delay_rows"
    IFS=$'\t' read -r best best_delay < <(_ha_select_best "$region_tolerance" "$region_order" "$region_enabled" <<<"$delay_rows") || true

    failures=$(_ha_codex_state_get '.failures' '0')
    candidate=$(_ha_codex_state_get '.candidate' '""')
    candidate_count=$(_ha_codex_state_get '."candidate-count"' '0')
    checked_at=$(_ha_codex_state_get '."checked-at"' '0')
    [ "$checked_at" -gt 0 ] && initialized=true || initialized=false
    now=$(date +%s)
    mode=auto

    if [ -z "$current_delay" ]; then
        candidate=''
        candidate_count=0
        failures=$((failures + 1))
        reason="Codex 当前节点双目标探测失败 ${failures} 次"
        if [ -n "$best" ] && [ "$failures" -ge "$(_ha_get '.codex.failure-confirmations' '2')" ]; then
            _node_apply "$group" "$best" >/dev/null && {
                reason="Codex 故障切换：$current -> $best"
                _ha_log "$reason"
                failures=0
                current=$best
                current_delay=$best_delay
                candidate=''
                candidate_count=0
                _ha_codex_write_state "$now" "$current" "$current_delay" "$best" "$best_delay" "$failures" "$candidate" "$candidate_count" "$reason"
                _ha_codex_record_switch "$now" "$reason"
                return 0
            }
        fi
    else
        failures=0
        if [ "$initialized" = false ] && [ -n "$best" ] && [ "$best" != "$current" ]; then
            _node_apply "$group" "$best" >/dev/null && {
                reason="Codex 启动优选：$current(${current_delay}ms) -> $best(${best_delay}ms)"
                _ha_log "$reason"
                current=$best
                current_delay=$best_delay
                _ha_codex_write_state "$now" "$current" "$current_delay" "$best" "$best_delay" 0 '' 0 "$reason"
                _ha_codex_record_switch "$now" "$reason"
                return 0
            }
        elif [ "$mode" = auto ] && [ -n "$best" ] && [ "$best" != "$current" ]; then
            local abs rel required improvement last_switch cooldown confirmations active protect_active
            local current_region_rank best_region_rank region_preferred=false switch_kind=performance
            abs=$(_ha_get '.codex.absolute-improvement' '150')
            rel=$(_ha_get '.codex.relative-improvement' '30')
            required=$((current_delay * rel / 100))
            [ "$required" -lt "$abs" ] && required=$abs
            improvement=$((current_delay - best_delay))
            last_switch=$(_ha_codex_state_get '."last-switch"' '0')
            cooldown=$(_ha_get '.codex.cooldown' '1800')
            confirmations=$(_ha_get '.codex.performance-confirmations' '3')
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
                    reason="Codex 地区优先候选（相差 ${improvement#-}ms），确认 ${candidate_count}/${confirmations}"
                else
                    reason="Codex 性能候选改善 ${improvement}ms，确认 ${candidate_count}/${confirmations}"
                fi
                if [ "$candidate_count" -ge "$confirmations" ]; then
                    protect_active=$(_ha_get '.codex.protect-active-connections' 'true')
                    active=0
                    [ "$protect_active" = true ] && active=$(_ha_codex_active_connections)
                    if [ "$active" -gt 0 ]; then
                        candidate_count=$confirmations
                        reason="Codex 有 ${active} 条活跃连接，推迟性能切换"
                    else
                        _node_apply "$group" "$best" >/dev/null && {
                            if [ "$switch_kind" = region ]; then
                                reason="Codex 地区优先切换：$current(${current_delay}ms) -> $best(${best_delay}ms)"
                            else
                                reason="Codex 性能切换：$current(${current_delay}ms) -> $best(${best_delay}ms)"
                            fi
                            _ha_log "$reason"
                            current=$best
                            current_delay=$best_delay
                            candidate=''
                            candidate_count=0
                            _ha_codex_write_state "$now" "$current" "$current_delay" "$best" "$best_delay" 0 "$candidate" "$candidate_count" "$reason"
                            _ha_codex_record_switch "$now" "$reason"
                            return 0
                        }
                    fi
                fi
            else
                candidate=''
                candidate_count=0
                reason="Codex 延迟差未达到切换阈值"
            fi
        else
            candidate=''
            candidate_count=0
            reason="Codex 当前节点已是本轮最优"
        fi
    fi
    _ha_codex_write_state "$now" "$current" "$current_delay" "$best" "$best_delay" "$failures" "$candidate" "$candidate_count" "$reason"
}

_ha_codex_check_if_due() {
    _ha_codex_enabled || return 0
    local now last interval
    now=$(date +%s)
    last=$(_ha_codex_state_get '."checked-at"' '0')
    interval=$(_ha_get '.codex.interval' '120')
    [ $((now - last)) -ge "$interval" ] || return 0
    _ha_codex_check_once
}

_ha_check_once() {
    service_is_active >/dev/null 2>&1 || return 1
    local entry_group entry_selected group url confirm_url timeout current best='' best_delay='' current_delay=''
    local name delay failures candidate candidate_count now mode hold_until reason=healthy
    local region_enabled region_tolerance region_order delay_rows
    local route fallback_node fallback_since recovery_count fallback_codex_managed
    entry_group=$(_ha_get '.group' '"HA-AUTO"')
    group=$(_ha_local_group)
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
    IFS=$'\t' read -r best best_delay < <(_ha_select_best "$region_tolerance" "$region_order" "$region_enabled" <<<"$delay_rows") || true

    failures=$(_ha_state_get '.failures' '0')
    candidate=$(_ha_state_get '.candidate' '""')
    candidate_count=$(_ha_state_get '."candidate-count"' '0')
    now=$(date +%s)
    mode=$(_ha_get '.mode' '"auto"')
    hold_until=$(_ha_get '."hold-until"' '0')
    route=$(_ha_state_get '.route' '"local"')
    fallback_node=$(_ha_state_get '."fallback-node"' '""')
    fallback_since=$(_ha_state_get '."fallback-since"' '0')
    recovery_count=$(_ha_state_get '."recovery-count"' '0')
    fallback_codex_managed=$(_ha_state_get '."fallback-codex-managed"' 'false')

    if _ha_fallback_enabled; then
        entry_selected=$(_node_now "$entry_group")
        if _ha_fallback_is_node "$entry_selected"; then
            route=fallback
            fallback_node=$entry_selected
            [ "$fallback_since" -gt 0 ] || fallback_since=$now
        elif [ "$route" = fallback ]; then
            route=local
            fallback_node=''
            fallback_since=0
            recovery_count=0
            fallback_codex_managed=false
        fi
    else
        route=local
    fi

    if [ "$mode" = hold ] && [ "$hold_until" -gt 0 ] && [ "$now" -ge "$hold_until" ]; then
        "$BIN_YQ" -i '.mode = "auto" | ."hold-until" = 0' "$CLASH_HA_CONFIG"
        mode=auto
    fi

    if [ "$route" = fallback ]; then
        local confirm recovery_confirmations recovery_stable defer_recovery active replacement
        recovery_confirmations=$(_ha_get '.fallback."recovery-confirmations"' '3')
        recovery_stable=$(_ha_get '.fallback."recovery-stable-seconds"' '300')
        defer_recovery=$(_ha_get '.fallback."defer-recovery-when-active"' 'true')
        if [ -n "$best" ]; then
            confirm=$(_node_delay_one "$best" "timeout=${timeout}&url=$(_node_urlencode "$confirm_url")" | cut -f2)
            if [[ "$confirm" =~ ^[0-9]+$ ]] && [ "$confirm" -gt 0 ]; then
                recovery_count=$((recovery_count + 1))
                [ "$recovery_count" -le "$recovery_confirmations" ] || recovery_count=$recovery_confirmations
                reason="本地候选恢复：$best，确认 ${recovery_count}/${recovery_confirmations}"
                if [ "$recovery_count" -ge "$recovery_confirmations" ] && [ $((now - fallback_since)) -ge "$recovery_stable" ]; then
                    active=0
                    [ "$defer_recovery" = true ] && active=$(_ha_active_connections)
                    if [ "$active" -gt 0 ]; then
                        reason="本地节点已恢复，检测到 ${active} 条活跃连接，推迟回切"
                    elif _ha_fallback_restore "$best" "$fallback_codex_managed"; then
                        reason="外部备用恢复回切：$fallback_node -> $best"
                        _ha_log "$reason"
                        current=$best
                        current_delay=$best_delay
                        failures=0
                        candidate=''
                        candidate_count=0
                        _ha_write_state "$now" "$current" "$current_delay" "$best" "$best_delay" 0 '' 0 "$reason"
                        _ha_fallback_state_set local '' 0 0 false
                        _ha_record_switch "$now" "$reason"
                        return 0
                    else
                        reason="本地节点已恢复，但回切失败"
                    fi
                fi
            else
                recovery_count=0
                reason="外部备用生效中；本地候选确认失败"
            fi
        else
            recovery_count=0
            reason="外部备用生效中；本地节点仍全部不可用"
        fi
        replacement=$(_ha_fallback_choose 2>/dev/null || true)
        if [ -n "$replacement" ] && [ "$replacement" != "$fallback_node" ]; then
            _node_apply "$entry_group" "$replacement" >/dev/null && {
                if [ "$fallback_codex_managed" = true ] && _ha_codex_enabled; then
                    _node_apply "$(_ha_get '.codex.group' '"CODEX"')" "$replacement" >/dev/null || true
                fi
                reason="外部备用切换：$fallback_node -> $replacement"
                _ha_log "$reason"
                fallback_node=$replacement
            }
        elif [ -z "$replacement" ]; then
            reason="本地节点和外部备用均不可用"
        fi
        _ha_write_state "$now" "$current" "$current_delay" "$best" "$best_delay" "$failures" '' 0 "$reason"
        _ha_fallback_state_set fallback "$fallback_node" "$fallback_since" "$recovery_count" "$fallback_codex_managed"
        [ -n "$best" ] || _ha_recover "$now"
        return 0
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
    local all_failed_confirmations
    all_failed_confirmations=$(_ha_get '.failure-confirmations' '2')
    _ha_fallback_enabled && all_failed_confirmations=$(_ha_get '.fallback."failure-confirmations"' '2')
    if _ha_mode_allows_failure_switch "$mode" && [ -z "$best" ] && [ "$failures" -ge "$all_failed_confirmations" ]; then
        if _ha_fallback_enabled; then
            local selected codex_managed
            selected=$(_ha_fallback_choose 2>/dev/null || true)
            if [ -n "$selected" ]; then
                codex_managed=$(_ha_fallback_apply "$selected") || codex_managed=false
                if [ "$(_node_now "$entry_group")" = "$selected" ]; then
                    reason="本地节点全部不可用，切换外部备用：$selected"
                    _ha_log "$reason"
                    _ha_write_state "$now" "$current" "$current_delay" '' '' 0 '' 0 "$reason"
                    _ha_fallback_state_set fallback "$selected" "$now" 0 "$codex_managed"
                    _ha_record_switch "$now" "$reason"
                    return 0
                fi
            fi
            _ha_log "WARN 本地节点全部不可用，外部备用也不可用"
        fi
        _ha_recover "$now"
    fi
}

_ha_recover() {
    local now=$1 last
    last=$(_ha_get '."last-recovery"' '0')
    [ $((now - last)) -ge 600 ] || return 0
    LAST_RECOVERY=$now "$BIN_YQ" -i '."last-recovery" = (env(LAST_RECOVERY) | tonumber)' "$CLASH_HA_CONFIG"
    if [ "$(_ha_state_get '.route' '"local"')" = fallback ]; then
        _ha_log "外部备用生效中，更新订阅缓存但不重启 Mihomo"
        _sub_update --all >>"$CLASH_HA_LOG" 2>&1 || true
        return 0
    fi
    _ha_log "全部候选不可用，尝试更新所有订阅并重建候选池"
    _sub_update --all >>"$CLASH_HA_LOG" 2>&1 || true
    _ha_build_and_restart >>"$CLASH_HA_LOG" 2>&1 || _ha_log "ERROR 自动恢复重建失败"
}

_ha_sub_update_state_get() {
    [ -f "$CLASH_HA_SUB_UPDATE_STATE" ] || {
        "$BIN_YQ" -n "$2" 2>/dev/null
        return
    }
    "$BIN_YQ" "$1 // $2" "$CLASH_HA_SUB_UPDATE_STATE" 2>/dev/null
}

_ha_sub_update_state_write() {
    local last_attempt=$1 last_success=$2 next_attempt=$3 pending=$4 applied_fingerprint=$5 pending_fingerprint=$6 reason=$7
    LAST_ATTEMPT=$last_attempt LAST_SUCCESS=$last_success NEXT_ATTEMPT=$next_attempt PENDING=$pending \
      APPLIED_FINGERPRINT=$applied_fingerprint PENDING_FINGERPRINT=$pending_fingerprint REASON=$reason \
      "$BIN_YQ" -n '
        {"last-attempt": (env(LAST_ATTEMPT) | tonumber),
         "last-success": (env(LAST_SUCCESS) | tonumber),
         "next-attempt": (env(NEXT_ATTEMPT) | tonumber),
         "pending": (env(PENDING) == "true"),
         "applied-fingerprint": strenv(APPLIED_FINGERPRINT),
         "pending-fingerprint": strenv(PENDING_FINGERPRINT),
         "last-reason": strenv(REASON)}
      ' >"${CLASH_HA_SUB_UPDATE_STATE}.new" && /bin/mv -f "${CLASH_HA_SUB_UPDATE_STATE}.new" "$CLASH_HA_SUB_UPDATE_STATE"
}

_ha_profiles_fingerprint() {
    local name path
    {
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            path=$(_sub_get "$name" path)
            [ -s "$path" ] || continue
            printf '%s\t' "$name"
            sha256sum "$path"
        done < <(_sub_names)
    } | sha256sum | awk '{print $1}'
}

_ha_active_connections() {
    local response count
    response=$(_node_curl GET '/connections') || { printf '1\n'; return; }
    count=$("$BIN_YQ" -p=json '.connections | length' <<<"$response" 2>/dev/null)
    [[ "$count" =~ ^[0-9]+$ ]] && printf '%s\n' "$count" || printf '1\n'
}

_ha_subscription_update_if_due() {
    [ "$(_ha_get '.subscription-update.enabled' 'false')" = true ] || return 0
    local now interval retry defer pending last_attempt last_success next_attempt applied_fingerprint pending_fingerprint
    local before after reason active
    now=$(date +%s)
    interval=$(_ha_get '.subscription-update.interval' '21600')
    retry=$(_ha_get '.subscription-update."retry-interval"' '900')
    defer=$(_ha_get '.subscription-update."defer-when-active"' 'true')
    [[ "$interval" =~ ^[0-9]+$ ]] || interval=21600
    [[ "$retry" =~ ^[0-9]+$ ]] || retry=900
    pending=$(_ha_sub_update_state_get '.pending' 'false')
    last_attempt=$(_ha_sub_update_state_get '."last-attempt"' '0')
    last_success=$(_ha_sub_update_state_get '."last-success"' '0')
    next_attempt=$(_ha_sub_update_state_get '."next-attempt"' '0')
    applied_fingerprint=$(_ha_sub_update_state_get '."applied-fingerprint"' '""')
    pending_fingerprint=$(_ha_sub_update_state_get '."pending-fingerprint"' '""')
    [ "$now" -ge "$next_attempt" ] || return 0
    before=$(_ha_profiles_fingerprint)
    [ -n "$applied_fingerprint" ] || applied_fingerprint=$before

    if [ "$pending" != true ]; then
        _ha_log "开始定时更新全部订阅"
        last_attempt=$now
        if ! _sub_update --all >>"$CLASH_HA_LOG" 2>&1; then
            reason="订阅更新失败，${retry} 秒后重试"
            _ha_log "WARN $reason"
            _ha_sub_update_state_write "$last_attempt" "$last_success" $((now + retry)) false "$applied_fingerprint" '' "$reason"
            return 0
        fi
        after=$(_ha_profiles_fingerprint)
        if [ "$after" = "$applied_fingerprint" ]; then
            reason="订阅更新成功，内容无变化"
            _ha_log "$reason"
            _ha_sub_update_state_write "$last_attempt" "$now" $((now + interval)) false "$after" '' "$reason"
            return 0
        fi
        pending=true
        pending_fingerprint=$after
    fi

    if [ "$defer" = true ]; then
        active=$(_ha_active_connections)
        if [ "$active" -gt 0 ]; then
            reason="订阅已有变化，检测到 ${active} 条活跃连接，${retry} 秒后再应用"
            _ha_log "$reason"
            _ha_sub_update_state_write "$last_attempt" "$last_success" $((now + retry)) true "$applied_fingerprint" "$pending_fingerprint" "$reason"
            return 0
        fi
    fi

    if _ha_build_and_restart >>"$CLASH_HA_LOG" 2>&1; then
        _ha_client_config
        after=$(_ha_profiles_fingerprint)
        reason="订阅更新已应用并重建 HA 节点池"
        _ha_log "$reason"
        _ha_sub_update_state_write "$last_attempt" "$now" $((now + interval)) false "$after" '' "$reason"
    else
        reason="订阅已更新但重建失败，${retry} 秒后重试"
        _ha_log "ERROR $reason"
        _ha_sub_update_state_write "$last_attempt" "$last_success" $((now + retry)) true "$applied_fingerprint" "$pending_fingerprint" "$reason"
    fi
}

_ha_daemon() {
    _ha_enabled || return 0
    local lock_file="${CLASH_HA_PID}.lock"
    exec 9>"$lock_file"
    /usr/bin/flock -n 9 || {
        _errorcat "HA 调度器已运行"
        return 1
    }
    if [ -f "$CLASH_HA_PID" ] && [ "$(cat "$CLASH_HA_PID" 2>/dev/null)" != "$$" ] && [ "$(cat "$CLASH_HA_PID" 2>/dev/null)" != "$PPID" ] && _ha_pid_running "$(cat "$CLASH_HA_PID" 2>/dev/null)" 'clashctl ha daemon'; then
        _errorcat "HA 调度器已运行"
        return 1
    fi
    printf '%s\n' "$$" >"$CLASH_HA_PID"
    trap '/usr/bin/rm -f "$CLASH_HA_PID"' EXIT INT TERM
    _ha_log "HA 调度器启动"
    while _ha_enabled && [ "$(cat "$CLASH_HA_PID" 2>/dev/null)" = "$$" ]; do
        _ha_check_once || _ha_log "WARN 本轮检测失败，等待内核/API 就绪"
        _ha_codex_check_if_due || _ha_log "WARN Codex 本轮检测失败，等待内核/API 就绪"
        _ha_subscription_update_if_due || _ha_log "WARN 定时订阅更新任务异常"
        sleep "$(_ha_get '.interval' '30')" & wait $!
    done
}

_ha_install_daemon() {
    [ -f "$CLASH_HA_PID" ] && _ha_pid_running "$(cat "$CLASH_HA_PID" 2>/dev/null)" 'clashctl ha daemon' && return 0
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
        local attempt i pid
        for attempt in 1 2; do
            (
                local launch_lock="${CLASH_HA_PID}.launch.lock"
                local runner=()
                exec 8>"$launch_lock"
                /usr/bin/flock -n 8 || exit 0
                if [ -f "$CLASH_HA_PID" ]; then
                    pid=$(cat "$CLASH_HA_PID" 2>/dev/null)
                    [ -n "$pid" ] && _ha_pid_running "$pid" 'clashctl ha daemon' && exit 0
                fi
                command -v tini >/dev/null 2>&1 && runner=(tini -s -g --)
                nohup "${runner[@]}" env CLASHCTL_HOME="$CLASHCTL_HOME" bash -c '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"; clashctl ha daemon' 8>&- >"$CLASH_HA_LOG" 2>&1 &
            )
            for ((i = 0; i < 30; i++)); do
                [ -f "$CLASH_HA_PID" ] && pid=$(cat "$CLASH_HA_PID" 2>/dev/null)
                [ -n "${pid:-}" ] && _ha_pid_running "$pid" 'clashctl ha daemon' && return 0
                sleep 0.1
            done
        done
        return 1
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
    local pid='' i
    [ -f "$CLASH_HA_PID" ] && pid=$(cat "$CLASH_HA_PID" 2>/dev/null)
    [ -n "$pid" ] && _ha_pid_running "$pid" 'clashctl ha daemon' && kill "$pid" 2>/dev/null || true
    if [ -n "$pid" ]; then
        for ((i = 0; i < 50; i++)); do
            _ha_pid_running "$pid" 'clashctl ha daemon' || break
            sleep 0.1
        done
        _ha_pid_running "$pid" 'clashctl ha daemon' && kill -9 "$pid" 2>/dev/null || true
    fi
    /usr/bin/rm -f "$CLASH_HA_PID"
    # The wrapper can outlive the daemon briefly while reaping its children.
    # Wait until its flock is released so an immediate restart does not race.
    for ((i = 0; i < 50; i++)); do
        ( exec 7>"${CLASH_HA_PID}.lock"; /usr/bin/flock -n 7 ) && break
        sleep 0.1
    done
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
       "rules": ["DOMAIN,localhost,DIRECT", "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
         "IP-CIDR6,::1/128,DIRECT,no-resolve", "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
         "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve", "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
         "DOMAIN-SUFFIX,qq.com,DIRECT", "DOMAIN-SUFFIX,bilibili.com,DIRECT",
         "DOMAIN-SUFFIX,aliyun.com,DIRECT", "DOMAIN-SUFFIX,deepseek.com,DIRECT",
         "DOMAIN-SUFFIX,feishu.com,DIRECT", "DOMAIN-SUFFIX,feishu.cn,DIRECT",
         "DOMAIN-SUFFIX,163.com,DIRECT",
         "DOMAIN-SUFFIX,battle.net,DIRECT", "DOMAIN-SUFFIX,battlenet.com.cn,DIRECT",
         "DOMAIN-SUFFIX,blizzard.com,DIRECT", "DOMAIN,blizzard.gcdn.cloudn.co.kr,DIRECT",
         "DOMAIN-SUFFIX,netease.com,DIRECT", "DOMAIN-SUFFIX,baidu.com,DIRECT",
         "DOMAIN-SUFFIX,gitee.com,DIRECT", "DOMAIN-SUFFIX,taobao.com,DIRECT",
         "DOMAIN-SUFFIX,youdao.com,DIRECT", "DOMAIN-SUFFIX,ugnas.com,DIRECT",
         "DOMAIN-SUFFIX,ug.link,DIRECT", "DOMAIN,ws.okx.com,PROXY", "MATCH,PROXY"]}
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
    if [ -f "$CLASH_HA_SUB_PID" ] && _ha_pid_running "$(cat "$CLASH_HA_SUB_PID" 2>/dev/null)" 'scripts/ha/serve.py'; then
        return 0
    fi
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
    [ -f "$CLASH_HA_SUB_PID" ] && _ha_pid_running "$(cat "$CLASH_HA_SUB_PID" 2>/dev/null)" 'scripts/ha/serve.py' && kill "$(cat "$CLASH_HA_SUB_PID" 2>/dev/null)" 2>/dev/null || true
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
    _ha_stop_subscription_server
    _ha_start_subscription_server || return 1
    _okcat "局域网代理：http://${server}:${port}（用户：$user，密码：$password）"
    _okcat "客户端订阅：http://${server}:$(_ha_get '.lan.subscription-port' '8088')/sub/${token}"
}

_ha_fallback_test() {
    _ha_fallback_enabled || { _errorcat "外部备用未启用或未配置"; return 1; }
    local check_url confirm_url check_expected confirm_expected timeout name healthy=0
    check_url=$(_ha_get '.fallback."check-url"' '"http://www.gstatic.com/generate_204"')
    confirm_url=$(_ha_get '.fallback."confirm-url"' '"https://cp.cloudflare.com/generate_204"')
    check_expected=$(_ha_get '.fallback."check-expected-status"' '204')
    confirm_expected=$(_ha_get '.fallback."confirm-expected-status"' '204')
    timeout=$(_ha_get '.fallback.timeout' '5000')
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if _ha_fallback_proxy_status_ok "$name" "$check_url" "$check_expected" "$timeout" &&
          _ha_fallback_proxy_status_ok "$name" "$confirm_url" "$confirm_expected" "$timeout"; then
            printf '外部备用：%s 可用\n' "$name"
            healthy=$((healthy + 1))
        else
            printf '外部备用：%s 不可用\n' "$name"
        fi
    done < <("$BIN_YQ" -r '.fallback.upstreams[]?.name' "$CLASH_HA_CONFIG" 2>/dev/null)
    [ "$healthy" -gt 0 ]
}

_ha_fallback_status() {
    if ! _ha_fallback_enabled; then
        printf '外部备用：停用\n'
        return 0
    fi
    local entry local_group selected route node recovery route_suffix=''
    entry=$(_ha_get '.group' '"HA-AUTO"')
    local_group=$(_ha_local_group)
    selected=$(_node_now "$entry")
    route=$(_ha_state_get '.route' '"local"')
    node=$(_ha_state_get '."fallback-node"' '""')
    recovery=$(_ha_state_get '."recovery-count"' '0')
    [ -z "$node" ] || route_suffix="（${node}）"
    printf '外部备用：启用（出口：%s -> %s）\n' "$entry" "${selected:-—}"
    printf '本地节点组：%s\n' "$local_group"
    printf '出口状态：%s%s\n' "$route" "$route_suffix"
    printf '本地恢复确认：%s/%s\n' "$recovery" "$(_ha_get '.fallback."recovery-confirmations"' '3')"
}

_ha_fallback_set() {
    local server=$1 http_port=$2 socks_port=$3 backup
    [ -n "$server" ] || { _errorcat "备用服务器地址不能为空"; return 1; }
    [[ "$http_port" =~ ^[0-9]+$ ]] && [ "$http_port" -ge 1 ] && [ "$http_port" -le 65535 ] || {
        _errorcat "HTTP 端口无效：$http_port"
        return 1
    }
    [[ "$socks_port" =~ ^[0-9]+$ ]] && [ "$socks_port" -ge 1 ] && [ "$socks_port" -le 65535 ] || {
        _errorcat "SOCKS5 端口无效：$socks_port"
        return 1
    }
    backup=$(mktemp "${CLASH_RESOURCES_DIR}/.ha-fallback-backup.XXXXXX") || return 1
    /bin/cp -f "$CLASH_HA_CONFIG" "$backup"
    SERVER=$server HTTP_PORT=$http_port SOCKS_PORT=$socks_port "$BIN_YQ" -i '
      .fallback.enabled = true |
      .fallback.upstreams = [
        {"name": "JSSS-SOCKS", "type": "socks5", "server": strenv(SERVER), "port": (env(SOCKS_PORT) | tonumber), "udp": true},
        {"name": "JSSS-HTTP", "type": "http", "server": strenv(SERVER), "port": (env(HTTP_PORT) | tonumber)}
      ]' "$CLASH_HA_CONFIG" || { /bin/mv -f "$backup" "$CLASH_HA_CONFIG"; return 1; }
    if ! _ha_build_and_restart; then
        /bin/mv -f "$backup" "$CLASH_HA_CONFIG"
        _errorcat "外部备用配置失败，已恢复原配置"
        return 1
    fi
    /usr/bin/rm -f "$backup"
    _ha_fallback_test || _failcat "外部备用配置已保存，但当前探测失败"
}

_ha_codex_status() {
    if ! _ha_codex_enabled; then
        printf 'Codex HA：停用\n'
        return 0
    fi
    local entry auto selected current mode
    entry=$(_ha_get '.codex.group' '"CODEX"')
    auto=$(_ha_get '.codex.auto-group' '"CODEX-HA"')
    selected=$(_node_now "$entry")
    current=$(_node_now "$auto")
    if _ha_fallback_enabled && _ha_fallback_is_node "$selected"; then
        mode=fallback
    elif [ "$selected" = "$auto" ]; then
        mode=auto
    else
        mode=fixed
    fi
    printf 'Codex HA：启用（%s）\n' "$mode"
    printf 'Codex 入口：%s -> %s\n' "$entry" "${selected:-—}"
    [ "$mode" = auto ] || current=$selected
    printf 'Codex 当前节点：%s (%sms)\n' "${current:-—}" "$(_ha_codex_state_get '."current-delay"' '"—"')"
    printf 'Codex 本轮最优：%s (%sms)\n' "$(_ha_codex_state_get '.best' '"—"')" "$(_ha_codex_state_get '."best-delay"' '"—"')"
    printf 'Codex 最近判断：%s\n' "$(_ha_codex_state_get '."last-reason"' '"尚未检测"')"
    printf 'Codex 检测时间：%s\n' "$(_ha_codex_state_get '."checked-at"' '"—"')"
}

_ha_subscription_update_status() {
    if [ "$(_ha_get '.subscription-update.enabled' 'false')" != true ]; then
        printf '订阅定时更新：停用\n'
        return 0
    fi
    local pending last_success next_attempt reason
    pending=$(_ha_sub_update_state_get '.pending' 'false')
    last_success=$(_ha_sub_update_state_get '."last-success"' '0')
    next_attempt=$(_ha_sub_update_state_get '."next-attempt"' '0')
    reason=$(_ha_sub_update_state_get '."last-reason"' '"尚未执行"')
    printf '订阅定时更新：启用（每 %s 秒，待应用：%s）\n' "$(_ha_get '.subscription-update.interval' '21600')" "$pending"
    printf '订阅上次成功：%s\n' "$last_success"
    printf '订阅下次尝试：%s\n' "$next_attempt"
    printf '订阅最近结果：%s\n' "$reason"
}

_ha_status() {
    printf 'HA：%s\n' "$(if _ha_enabled; then printf '启用'; else printf '停用'; fi)"
    if [ -f "$CLASH_HA_PID" ] && _ha_pid_running "$(cat "$CLASH_HA_PID" 2>/dev/null)" 'clashctl ha daemon'; then
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
    _ha_fallback_status
    _ha_codex_status
    _ha_subscription_update_status
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
        local pin_group
        pin_group=$(_ha_local_group)
        _node_apply "$pin_group" "$2" || return 1
        if _ha_fallback_enabled; then
            _node_apply "$(_ha_get '.group' '"HA-AUTO"')" "$pin_group" || return 1
            [ ! -f "$CLASH_HA_STATE" ] || _ha_fallback_state_set local '' 0 0 false
        fi
        "$BIN_YQ" -i '.mode = "pin"' "$CLASH_HA_CONFIG"
        ;;
    unpin) "$BIN_YQ" -i '.mode = "auto"' "$CLASH_HA_CONFIG"; _okcat "已解除严格固定" ;;
    codex)
        case "${2:-status}" in
        enable)
            _ha_enabled || { _errorcat "请先运行 clashctl ha enable，再启用 Codex HA"; return 1; }
            "$BIN_YQ" -i '.codex.mode = "auto" | .codex."pinned-node" = ""' "$CLASH_HA_CONFIG"
            "$BIN_YQ" -i '.codex.enabled = true' "$CLASH_HA_CONFIG"
            /usr/bin/rm -f "$CLASH_HA_CODEX_STATE"
            _ha_build_and_restart || { "$BIN_YQ" -i '.codex.enabled = false' "$CLASH_HA_CONFIG"; return 1; }
            _ha_install_daemon
            _ha_codex_check_once
            _ha_codex_status
            ;;
        disable)
            "$BIN_YQ" -i '.codex.enabled = false' "$CLASH_HA_CONFIG"
            /usr/bin/rm -f "$CLASH_HA_CODEX_STATE"
            _ha_build_and_restart
            ;;
        check) _ha_codex_check_once && _ha_codex_status ;;
        auto)
            _ha_codex_enabled || { _errorcat "Codex HA 未启用"; return 1; }
            _node_apply "$(_ha_get '.codex.group' '"CODEX"')" "$(_ha_get '.codex.auto-group' '"CODEX-HA"')" || return 1
            "$BIN_YQ" -i '.codex.mode = "auto" | .codex."pinned-node" = ""' "$CLASH_HA_CONFIG"
            [ ! -f "$CLASH_HA_CODEX_STATE" ] || "$BIN_YQ" -i '.failures = 0 | .candidate = "" | ."candidate-count" = 0' "$CLASH_HA_CODEX_STATE"
            _ha_codex_check_once
            ;;
        pin)
            _ha_codex_enabled || { _errorcat "Codex HA 未启用"; return 1; }
            [ -n "${3:-}" ] || { _errorcat "用法：clashctl ha codex pin <节点全名>"; return 1; }
            _node_apply "$(_ha_get '.codex.group' '"CODEX"')" "$3" || return 1
            PINNED=$3 "$BIN_YQ" -i '.codex.mode = "fixed" | .codex."pinned-node" = strenv(PINNED)' "$CLASH_HA_CONFIG"
            ;;
        status) _ha_codex_status ;;
        *) _errorcat "用法：clashctl ha codex enable|disable|check|status|auto|pin <节点全名>" ;;
        esac
        ;;
    fallback)
        case "${2:-status}" in
        set)
            [ -n "${3:-}" ] && [ -n "${4:-}" ] && [ -n "${5:-}" ] || {
                _errorcat "用法：clashctl ha fallback set <服务器> <HTTP端口> <SOCKS5端口>"
                return 1
            }
            _ha_fallback_set "$3" "$4" "$5"
            ;;
        test) _ha_fallback_test ;;
        status) _ha_fallback_status ;;
        disable)
            local fallback_backup
            fallback_backup=$(mktemp "${CLASH_RESOURCES_DIR}/.ha-fallback-backup.XXXXXX") || return 1
            /bin/cp -f "$CLASH_HA_CONFIG" "$fallback_backup"
            "$BIN_YQ" -i '.fallback.enabled = false' "$CLASH_HA_CONFIG"
            if _ha_build_and_restart; then
                /usr/bin/rm -f "$fallback_backup"
                [ ! -f "$CLASH_HA_STATE" ] || _ha_fallback_state_set local '' 0 0 false
                _okcat "外部备用已停用"
            else
                /bin/mv -f "$fallback_backup" "$CLASH_HA_CONFIG"
                return 1
            fi
            ;;
        *) _errorcat "用法：clashctl ha fallback set|test|status|disable" ;;
        esac
        ;;
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
  codex enable            启用 OpenAI/Codex 独立高可用组
  codex disable           停用 OpenAI/Codex 独立高可用组
  codex check             立即执行 OpenAI 双目标检测
  codex status            查看 OpenAI/Codex 组状态
  codex auto              在 Web UI 固定节点后恢复自动模式
  codex pin <节点全名>    固定 OpenAI/Codex 节点，完全停止自动切换
  fallback set <服务器> <HTTP端口> <SOCKS5端口> 配置并启用外部备用
  fallback test           检测全部外部备用入口
  fallback status         查看外部备用出口状态
  fallback disable        停用外部备用并恢复单层本地节点组
  lan enable [CIDR] [用户] [地址] 开启局域网代理和客户端订阅
  lan disable             关闭局域网入口
  log [-n 行数]           查看 HA 日志

EOF
        ;;
    *) _errorcat "未知 HA 子命令：$1" ;;
    esac
}
