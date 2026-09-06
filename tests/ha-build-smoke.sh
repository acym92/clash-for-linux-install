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

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/clash-ha-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
CLASH_RESOURCES_DIR=$test_dir
CLASH_HA_CONFIG=$root/resources/ha.yaml
CLASHCTL_KERNEL=mihomo

_sub_current() { printf 'A\n'; }
_sub_names() { printf 'A\nB\n'; }
_sub_get() {
    [ "$2" = path ] || return 0
    case $1 in
    A) printf '%s/tests/fixtures/ha-profile-a.yaml\n' "$root" ;;
    B) printf '%s/tests/fixtures/ha-profile-b.yaml\n' "$root" ;;
    esac
}
_valid_config() { return 0; }

_ha_build_config
[ "$_HA_BUILD_COUNT" -eq 2 ]
[ "$("$BIN_YQ" -o=json -I=0 '.proxies | map(.name)' "$_HA_BUILD_FILE")" = '["[A] node-one","[B] node-two"]' ]
[ "$("$BIN_YQ" '.proxy-groups[] | select(.name == "HA-AUTO") | .proxies | length' "$_HA_BUILD_FILE")" = 2 ]
[ "$("$BIN_YQ" -o=json -I=0 '.proxy-groups[] | select(.name == "PROXY") | .proxies' "$_HA_BUILD_FILE")" = '["HA-AUTO"]' ]
[ "$("$BIN_YQ" -o=json -I=0 '.rules' "$_HA_BUILD_FILE")" = '["MATCH,PROXY"]' ]

codex_config="$test_dir/ha-codex.yaml"
"$BIN_YQ" '.codex.enabled = true' "$root/resources/ha.yaml" >"$codex_config"
CLASH_HA_CONFIG=$codex_config
_ha_build_config
[ "$_HA_BUILD_COUNT" -eq 2 ]
[ "$("$BIN_YQ" '.proxy-groups[] | select(.name == "CODEX-HA") | .proxies | length' "$_HA_BUILD_FILE")" = 2 ]
[ "$("$BIN_YQ" -o=json -I=0 '.proxy-groups[] | select(.name == "CODEX") | .proxies' "$_HA_BUILD_FILE")" = '["CODEX-HA","[A] node-one","[B] node-two"]' ]
[ "$("$BIN_YQ" -o=json -I=0 '.rules | .[0:5]' "$_HA_BUILD_FILE")" = '["DOMAIN-SUFFIX,chatgpt.com,CODEX","DOMAIN-SUFFIX,openai.com,CODEX","DOMAIN-SUFFIX,oaistatic.com,CODEX","DOMAIN-SUFFIX,oaiusercontent.com,CODEX","DOMAIN-SUFFIX,oaisidekickupdates.blob.core.windows.net,CODEX"]' ]
[ "$("$BIN_YQ" '.rules[-1]' "$_HA_BUILD_FILE")" = 'MATCH,PROXY' ]
[ "$("$BIN_YQ" '.profile."store-selected"' "$_HA_BUILD_FILE")" = true ]

PINNED='[B] node-two' "$BIN_YQ" '.codex.mode = "fixed" | .codex."pinned-node" = strenv(PINNED)' "$codex_config" >"${codex_config}.new"
mv "${codex_config}.new" "$codex_config"
_ha_build_config
[ "$("$BIN_YQ" '.proxy-groups[] | select(.name == "CODEX") | .proxies[0]' "$_HA_BUILD_FILE")" = '[B] node-two' ]

printf 'HA config smoke test passed\n'
