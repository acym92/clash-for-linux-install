#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export CLASHCTL_HOME=$root
. "$root/scripts/cmd/clashctl.sh"

BIN_YQ=${YQ_BIN:-$root/bin/yq}
[ -x "$BIN_YQ" ] || {
    printf 'Set YQ_BIN to a yq v4 executable\n' >&2
    exit 2
}

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/clash-ha-fallback.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
CLASH_HA_CONFIG="$test_dir/ha.yaml"
CLASH_HA_STATE="$test_dir/state.yaml"
CLASH_HA_LOG="$test_dir/ha.log"
CLASH_CONFIG_RUNTIME="$test_dir/runtime.yaml"
entry_file="$test_dir/entry"
local_file="$test_dir/local"

SERVER=192.168.31.47 "$BIN_YQ" '
  .enabled = true |
  .failure-confirmations = 2 |
  .fallback.enabled = true |
  .fallback.recovery-confirmations = 2 |
  .fallback.recovery-stable-seconds = 0 |
  .fallback.defer-recovery-when-active = true |
  .fallback.upstreams = [
    {"name": "JSSS-SOCKS", "type": "socks5", "server": strenv(SERVER), "port": 9099, "udp": true},
    {"name": "JSSS-HTTP", "type": "http", "server": strenv(SERVER), "port": 9098}
  ]' "$root/resources/ha.yaml" >"$CLASH_HA_CONFIG"
printf 'mixed-port: 7890\n' >"$CLASH_CONFIG_RUNTIME"
printf 'HA-LOCAL\n' >"$entry_file"
printf 'A\n' >"$local_file"

service_is_active() { return 0; }
_node_now() {
    case $1 in
    HA-AUTO) cat "$entry_file" ;;
    HA-LOCAL) cat "$local_file" ;;
    *) return 1 ;;
    esac
}
_node_members() { printf 'A\nB\n'; }
_node_apply() {
    case $1 in
    HA-AUTO) printf '%s\n' "$2" >"$entry_file" ;;
    HA-LOCAL) printf '%s\n' "$2" >"$local_file" ;;
    *) return 1 ;;
    esac
}
_node_urlencode() { printf '%s' "$1"; }
mock_delay_rows=''
mock_confirm_row=''
_node_delay_rows() { printf '%s\n' "$mock_delay_rows"; }
_node_delay_one() { printf '%s\n' "$mock_confirm_row"; }
_ha_fallback_choose() { printf 'JSSS-SOCKS\n'; }
_ha_active_connections() { printf '0\n'; }
_ha_recover() { return 0; }

# Two consecutive rounds with no usable local node switch the outer group.
_ha_check_once
[ "$(cat "$entry_file")" = HA-LOCAL ]
[ "$("$BIN_YQ" '.failures' "$CLASH_HA_STATE")" = 1 ]
_ha_check_once
[ "$(cat "$entry_file")" = JSSS-SOCKS ]
[ "$("$BIN_YQ" '.route' "$CLASH_HA_STATE")" = fallback ]
[ "$("$BIN_YQ" '."fallback-node"' "$CLASH_HA_STATE")" = JSSS-SOCKS ]

# A local node must pass both targets for two rounds before traffic returns.
mock_delay_rows=$'B\t80'
mock_confirm_row=$'B\t90'
_ha_check_once
[ "$(cat "$entry_file")" = JSSS-SOCKS ]
[ "$("$BIN_YQ" '."recovery-count"' "$CLASH_HA_STATE")" = 1 ]
_ha_check_once
[ "$(cat "$entry_file")" = HA-LOCAL ]
[ "$(cat "$local_file")" = B ]
[ "$("$BIN_YQ" '.route' "$CLASH_HA_STATE")" = local ]

printf 'HA external fallback smoke test passed\n'
