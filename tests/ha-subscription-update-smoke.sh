#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export CLASHCTL_HOME=$root
. "$root/scripts/cmd/clashctl.sh"

BIN_YQ=${YQ_BIN:-$root/bin/yq}
[ -x "$BIN_YQ" ] || { printf 'Set YQ_BIN to a yq v4 executable\n' >&2; exit 2; }

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/clash-ha-sub-update.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
CLASH_HA_CONFIG="$test_dir/ha.yaml"
CLASH_HA_SUB_UPDATE_STATE="$test_dir/state.yaml"
CLASH_HA_LOG="$test_dir/ha.log"
CLASH_CONFIG_RUNTIME="$test_dir/runtime.yaml"
printf 'mixed-port: 7890\n' >"$CLASH_CONFIG_RUNTIME"
cat >"$CLASH_HA_CONFIG" <<'EOF'
subscription-update:
  enabled: true
  interval: 21600
  retry-interval: 1
  defer-when-active: true
EOF
printf 'old-a\n' >"$test_dir/a.yaml"
printf 'old-b\n' >"$test_dir/b.yaml"

_sub_names() { printf 'A\nB\n'; }
_sub_get() { printf '%s/%s.yaml\n' "$test_dir" "${1,,}"; }
update_count=0
build_count=0
active_count=2
_sub_update() { update_count=$((update_count + 1)); printf 'new-a\n' >"$test_dir/a.yaml"; }
_ha_active_connections() { printf '%s\n' "$active_count"; }
_ha_build_and_restart() { build_count=$((build_count + 1)); }
_ha_client_config() { :; }

_ha_subscription_update_if_due
[ "$update_count" -eq 1 ]
[ "$build_count" -eq 0 ]
[ "$("$BIN_YQ" '.pending' "$CLASH_HA_SUB_UPDATE_STATE")" = true ]

NEXT=0 "$BIN_YQ" -i '."next-attempt" = (env(NEXT) | tonumber)' "$CLASH_HA_SUB_UPDATE_STATE"
active_count=0
_ha_subscription_update_if_due
[ "$update_count" -eq 1 ]
[ "$build_count" -eq 1 ]
[ "$("$BIN_YQ" '.pending' "$CLASH_HA_SUB_UPDATE_STATE")" = false ]

_ha_subscription_update_if_due
[ "$update_count" -eq 1 ]
[ "$build_count" -eq 1 ]

printf 'HA subscription update smoke test passed\n'
