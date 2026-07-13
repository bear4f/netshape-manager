#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NETSHAPE_LIB_ONLY=1
# shellcheck source=../netshape-manager.sh
. "$ROOT/netshape-manager.sh"

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf 'FAIL: %s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
  printf 'PASS: %s\n' "$label"
}

assert_eq 450 "$(recommended_rate 500 speed)" '500M speed'
assert_eq 430 "$(recommended_rate 500 balanced)" '500M balanced'
assert_eq 400 "$(recommended_rate 500 stable)" '500M stable'
assert_eq 950 "$(recommended_rate 1000 speed)" '1G speed'
assert_eq 900 "$(recommended_rate 1000 balanced)" '1G balanced'
assert_eq 850 "$(recommended_rate 1000 stable)" '1G stable'
assert_eq speed "$(default_profile_for_rtt 80)" '80ms profile'
assert_eq balanced "$(default_profile_for_rtt 160)" '160ms profile'
assert_eq stable "$(default_profile_for_rtt 220)" '220ms profile'
assert_eq 33554432 "$(calculate_tcp_max 450 160 1024)" '450M 160ms 1GiB buffer'
assert_eq 67108864 "$(calculate_tcp_max 950 160 2048)" '950M 160ms 2GiB buffer'
assert_eq 8388608 "$(calculate_tcp_max 100 20 256)" 'small-memory floor/cap'
assert_eq /proc/sys/net/ipv4/tcp_rmem "$(sysctl_path net.ipv4.tcp_rmem)" 'sysctl key path'
assert_eq 550 "$(calculate_htb_burst_kb 450)" '450M HTB burst'
assert_eq 1160 "$(calculate_htb_burst_kb 950)" '950M HTB burst'

printf '%s\n' 'All self-tests passed.'
