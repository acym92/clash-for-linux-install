#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export CLASHCTL_HOME=$root
. "$root/scripts/cmd/clashctl.sh"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/clash-startup-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
CLASH_RESOURCES_DIR=$test_dir
CLASH_SUPERVISOR_PID="$test_dir/supervisor.pid"
CLASH_SUPERVISOR_ENABLED="$test_dir/supervisor.enabled"
CLASH_SUPERVISOR_LOG="$test_dir/supervisor.log"
CLASH_SUPERVISOR_HEARTBEAT="$test_dir/supervisor.heartbeat"
CLASHCTL_KERNEL=mihomo
CLASHCTL_SERVICE_READY_TIMEOUT=2
service_is_active() { test -f "$test_dir/kernel"; }
service_start() { touch "$test_dir/kernel"; }
_detect_proxy_port() { :; }
_ha_ensure_services() { touch "$test_dir/auxiliary"; }
_supervisor_start() { touch "$test_dir/supervisor-started"; }
_node_curl() {
    local checks=0
    [ ! -f "$test_dir/checks" ] || checks=$(cat "$test_dir/checks")
    checks=$((checks + 1))
    printf '%s\n' "$checks" >"$test_dir/checks"
    [ "$checks" -ge 3 ]
}
# The process exists before the API; auxiliary startup must wait, not be skipped.
on_service_only
[ "$(cat "$test_dir/checks")" -ge 3 ]
[ -f "$test_dir/auxiliary" ] && [ -f "$test_dir/supervisor-started" ]

# Failed readiness is bounded and still enables recovery and auxiliary startup.
rm "$test_dir/auxiliary" "$test_dir/supervisor-started"
_node_curl() { return 1; }
if on_service_only; then printf 'Unready API reported success\n' >&2; exit 1; fi
[ -f "$test_dir/auxiliary" ] && [ -f "$test_dir/supervisor-started" ]

# Repair missing components, and honor an explicitly disabled supervisor.
_node_curl() { return 0; }
touch "$CLASH_SUPERVISOR_ENABLED"
rm "$test_dir/kernel" "$test_dir/auxiliary"
_supervisor_step
[ -f "$test_dir/kernel" ] && [ -f "$test_dir/auxiliary" ]
[ -s "$CLASH_SUPERVISOR_HEARTBEAT" ]
rm "$test_dir/auxiliary"
_supervisor_step
[ -f "$test_dir/auxiliary" ]
rm "$CLASH_SUPERVISOR_ENABLED" "$test_dir/kernel" "$test_dir/auxiliary"
_supervisor_step
[ ! -f "$test_dir/kernel" ] && [ ! -f "$test_dir/auxiliary" ]
printf 'Startup/readiness/supervisor regression tests passed\n'
