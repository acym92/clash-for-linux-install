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
CLASH_PROFILES_LOCK="$test_dir/profiles.lock"
cp "$root/resources/ha.yaml" "$CLASH_HA_CONFIG"
"$BIN_YQ" -i '.subscription-update."retry-interval" = 1' "$CLASH_HA_CONFIG"
printf 'old-a\n' >"$test_dir/a.yaml"
printf 'old-b\n' >"$test_dir/b.yaml"
_sub_names() { printf 'A\nB\n'; }
_sub_get() { printf '%s/%s.yaml\n' "$test_dir" "${1,,}"; }
_sub_update() {
    printf 'download\n' >>"$test_dir/downloads"
    printf 'version-%s\n' "$(wc -l <"$test_dir/downloads")" >"$test_dir/a.yaml"
    [ ! -f "$test_dir/download-fail" ]
}
active_count=2
_ha_active_connections() { printf '%s\n' "$active_count"; }
_ha_build_and_reload() { [ ! -f "$test_dir/apply-fail" ] || return 1; printf 'reload\n' >>"$test_dir/applies"; }
_ha_build_and_restart() { [ ! -f "$test_dir/apply-fail" ] || return 1; printf 'restart\n' >>"$test_dir/applies"; }
_ha_client_config() { :; }
count() { if [ -f "$1" ]; then wc -l <"$1"; else printf '0\n'; fi; }
state() { "$BIN_YQ" "$1" "$CLASH_HA_SUB_UPDATE_STATE"; }

# Reload with active connections, then avoid repeating successful work.
_ha_subscription_update_if_due
[ "$(count "$test_dir/downloads")" -eq 1 ]
[ "$(count "$test_dir/applies")" -eq 1 ]
[ "$(state '.pending')" = false ]
grep -qx reload "$test_dir/applies"
_ha_subscription_update_if_due
[ "$(count "$test_dir/downloads")" -eq 1 ]
[ "$(count "$test_dir/applies")" -eq 1 ]

# Restart mode protects connections without suppressing subsequent downloads.
"$BIN_YQ" -i '.subscription-update."apply-mode" = "restart"' "$CLASH_HA_CONFIG"
_ha_subscription_update_if_due --force
[ "$(state '.pending')" = true ]
[ "$(count "$test_dir/downloads")" -eq 2 ]
[ "$(count "$test_dir/applies")" -eq 1 ]
"$BIN_YQ" -i '."next-apply" = 0' "$CLASH_HA_SUB_UPDATE_STATE"
_ha_subscription_update_if_due
[ "$(count "$test_dir/downloads")" -eq 2 ]
"$BIN_YQ" -i '."next-download" = 0' "$CLASH_HA_SUB_UPDATE_STATE"
_ha_subscription_update_if_due
[ "$(count "$test_dir/downloads")" -eq 3 ]
[ "$(state '.pending')" = true ]
active_count=0
"$BIN_YQ" -i '."next-apply" = 0' "$CLASH_HA_SUB_UPDATE_STATE"
_ha_subscription_update_if_due
[ "$(state '.pending')" = false ]
[ "$(count "$test_dir/applies")" -eq 2 ]
grep -q restart "$test_dir/applies"

# Failed applies remain pending while newer downloads replace the pending cache.
"$BIN_YQ" -i '.subscription-update."apply-mode" = "reload"' "$CLASH_HA_CONFIG"
touch "$test_dir/apply-fail"
active_count=20
_ha_subscription_update_if_due --force
[ "$(state '.pending')" = true ]
[ "$(count "$test_dir/applies")" -eq 2 ]
"$BIN_YQ" -i '."next-download" = 0' "$CLASH_HA_SUB_UPDATE_STATE"
_ha_subscription_update_if_due
[ "$(count "$test_dir/downloads")" -eq 5 ]
[ "$(state '.pending-fingerprint')" = "$(_ha_profiles_fingerprint)" ]
rm "$test_dir/apply-fail"
touch "$test_dir/download-fail"
_ha_subscription_update_if_due --force
[ "$(state '.pending')" = false ]
[ "$(count "$test_dir/applies")" -eq 3 ]
[ "$(cat "$test_dir/b.yaml")" = old-b ]
[ "$(state '."applied-fingerprint"')" = "$(_ha_profiles_fingerprint)" ]
[ "$(state '."next-download"')" -le "$(( $(date +%s) + 1 ))" ]

# Migrate a legacy pending state whose combined retry timestamp is far ahead.
rm "$test_dir/download-fail"
"$BIN_YQ" -i 'del(."next-download", ."next-apply") | .pending = true | ."last-attempt" = 1 | ."next-attempt" = 9999999999' "$CLASH_HA_SUB_UPDATE_STATE"
_ha_subscription_update_if_due
[ "$(count "$test_dir/downloads")" -eq 7 ]
[ "$(state '.pending')" = false ]
printf 'HA subscription scheduling regression tests passed\n'
