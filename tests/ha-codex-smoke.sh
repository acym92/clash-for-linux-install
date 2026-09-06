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

printf 'HA Codex smoke test passed\n'
