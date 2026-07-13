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
assert_eq '推荐均衡' "$(profile_label balanced)" 'Chinese profile label'
assert_eq '自动检测' "$(shaper_label auto)" 'Chinese shaper label'

tc_log="$(mktemp)"
need_root() { :; }
has() { return 0; }
load_config() {
  RATE_MBPS=900
  SHAPING=on
  SHAPER_MODE=auto
  LINE_MBPS=1000
  RTT_MS=160
  PROFILE=balanced
  IFACE=auto
}
save_config() { :; }
resolve_iface() { printf '%s\n' eth-test; }
modprobe() { :; }
tc() {
  local first=1 arg line=''
  for arg in "$@"; do
    (( first == 1 )) || printf ' ' >> "$tc_log"
    printf '%s' "$arg" >> "$tc_log"
    line="${line}${line:+ }${arg}"
    first=0
  done
  printf '\n' >> "$tc_log"
  if [[ "${TC_REJECT_HTB:-0}" == 1 && " $line " == *' htb '* ]]; then
    return 1
  fi
}
apply_shape >/dev/null
assert_eq 'qdisc del dev eth-test root' "$(sed -n '1p' "$tc_log")" 'remove old root before HTB'
assert_eq 'qdisc add dev eth-test root handle 1: htb default 10 r2q 1000' "$(sed -n '2p' "$tc_log")" 'create fresh HTB root'

: > "$tc_log"
TC_REJECT_HTB=1
apply_shape >/dev/null 2>&1
assert_eq 'qdisc add dev eth-test root handle 1: tbf rate 900mbit burst 1099kb latency 50ms' "$(sed -n '4p' "$tc_log")" 'fallback to TBF root'
assert_eq tbf "$SHAPER_MODE" 'remember compatible shaper'
rm -f "$tc_log"

printf '%s\n' 'All self-tests passed.'
