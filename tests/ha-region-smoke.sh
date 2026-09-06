#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export CLASHCTL_HOME=$root
. "$root/scripts/cmd/clashctl.sh"

order=taiwan,japan,hong-kong,other
rows=$'[S] other\t50\n[S] 香港 01\t60\n[S] 日本 01\t70\n[S] 台湾 01\t100'

[ "$(_ha_select_best 50 "$order" true <<<"$rows")" = $'[S] 台湾 01\t100' ]
[ "$(_ha_select_best 49 "$order" true <<<"$rows")" = $'[S] 日本 01\t70' ]
[ "$(_ha_select_best 50 "$order" false <<<"$rows")" = $'[S] other\t50' ]
[ "$(_ha_region_key '[A] 🇹🇼 台北')" = taiwan ]
[ "$(_ha_region_key '[A] JP-TCP-01')" = japan ]
[ "$(_ha_region_key '[A] HK-01')" = hong-kong ]
_ha_mode_allows_performance_switch auto
! _ha_mode_allows_performance_switch hold
! _ha_mode_allows_performance_switch pin
_ha_mode_allows_failure_switch auto
_ha_mode_allows_failure_switch hold
! _ha_mode_allows_failure_switch pin

printf 'HA region preference smoke test passed\n'
