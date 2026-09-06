#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export CLASHCTL_HOME=$root
. "$root/scripts/cmd/clashctl.sh"

test_calls=$(mktemp "${TMPDIR:-/tmp}/clash-ha-codex-calls.XXXXXX")
trap 'rm -f -- "$test_calls"' EXIT
_node_urlencode() { printf '%s' "$1"; }
_node_curl() {
    printf '%s\n' "$2" >>"$test_calls"
    printf '{}\n200'
}

CLASHCTL_NODE_EXPECTED_STATUS=401 _node_delay_rows CODEX-HA 'https://api.openai.com/v1/models' 8000 node-one >/dev/null
grep -q 'expected=401' "$test_calls"

: >"$test_calls"
unset CLASHCTL_NODE_EXPECTED_STATUS
_node_delay_rows HA-AUTO 'https://www.gstatic.com/generate_204' 5000 node-one >/dev/null
! grep -q 'expected=' "$test_calls"

rows=$'[S] other\t50\n[S] 香港 01\t60\n[S] 日本 01\t70\n[S] 台湾 01\t150'
[ "$(_ha_select_best 100 taiwan,japan,hong-kong,other true <<<"$rows")" = $'[S] 台湾 01\t150' ]

CLASH_HA_CONFIG=$(mktemp "${TMPDIR:-/tmp}/clash-ha-codex-config.XXXXXX")
CLASH_HA_CODEX_STATE=$(mktemp "${TMPDIR:-/tmp}/clash-ha-codex-state.XXXXXX")
trap 'rm -f -- "$test_calls" "$CLASH_HA_CONFIG" "$CLASH_HA_CODEX_STATE"' EXIT
cp "$root/resources/ha.yaml" "$CLASH_HA_CONFIG"
"$BIN_YQ" -i '.enabled = true | .codex.enabled = true | .codex.absolute-improvement = 10 | .codex.relative-improvement = 0 | .codex.performance-confirmations = 3 | .codex.cooldown = 0' "$CLASH_HA_CONFIG"

service_is_active() { return 0; }
mock_entry_selected=CODEX-HA
current_node=A
apply_count=0
_node_now() { [ "$1" = CODEX ] && printf '%s\n' "$mock_entry_selected" || printf '%s\n' "$current_node"; }
_node_members() { printf 'A\nB\n'; }
_node_apply() { apply_count=$((apply_count + 1)); current_node=$2; }
_ha_codex_active_connections() { printf '0\n'; }
probe_rows=$'A\t200\nB\t100'
_ha_codex_healthy_rows() { printf '%s\n' "$probe_rows"; }

# A Web UI leaf selection is persisted and never invokes the automatic selector.
mock_entry_selected=B
_ha_codex_check_once
[ "$apply_count" -eq 0 ]
[ "$("$BIN_YQ" '.codex.mode' "$CLASH_HA_CONFIG")" = fixed ]
[ "$("$BIN_YQ" '.codex."pinned-node"' "$CLASH_HA_CONFIG")" = B ]

# Performance confirmation must be consecutive: B,B,A,B,B does not switch.
mock_entry_selected=CODEX-HA
"$BIN_YQ" -n '{"checked-at": 1, "last-switch": 0, "failures": 0, "candidate": "", "candidate-count": 0}' >"$CLASH_HA_CODEX_STATE"
_ha_codex_check_once
_ha_codex_check_once
probe_rows=$'A\t100\nB\t200'
_ha_codex_check_once
probe_rows=$'A\t200\nB\t100'
_ha_codex_check_once
_ha_codex_check_once
[ "$apply_count" -eq 0 ]
_ha_codex_check_once
[ "$apply_count" -eq 1 ]
[ "$current_node" = B ]

# Region priority can switch to Taiwan within the 100ms tolerance after confirmation.
current_node='[S] 日本'
apply_count=0
probe_rows=$'[S] 日本\t70\n[S] 台湾\t150'
"$BIN_YQ" -n '{"checked-at": 1, "last-switch": 0, "failures": 0, "candidate": "", "candidate-count": 0}' >"$CLASH_HA_CODEX_STATE"
_node_members() { printf '[S] 日本\n[S] 台湾\n'; }
_ha_codex_check_once
_ha_codex_check_once
_ha_codex_check_once
[ "$apply_count" -eq 1 ]
[ "$current_node" = '[S] 台湾' ]

printf 'HA Codex smoke test passed\n'
