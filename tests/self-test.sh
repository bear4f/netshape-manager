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
assert_eq 18874368 "$(calculate_tcp_max 450 160 1024)" '450M 160ms 2xBDP buffer'
assert_eq 38797312 "$(calculate_tcp_max 950 160 2048)" '950M 160ms 2xBDP buffer'
assert_eq 8388608 "$(calculate_tcp_max 100 20 256)" 'small-memory floor/cap'
assert_eq 33554432 "$(calculate_tcp_max 950 160 1024)" 'RAM tier caps buffer'
assert_eq /proc/sys/net/ipv4/tcp_rmem "$(sysctl_path net.ipv4.tcp_rmem)" 'sysctl key path'
assert_eq '32768 49152 98304' "$(tcp_mem_values 512)" 'small RAM tcp_mem'
assert_eq '65536 98304 196608' "$(tcp_mem_values 2047)" 'mid RAM tcp_mem'
assert_eq '131072 196608 393216' "$(tcp_mem_values 8192)" 'large RAM tcp_mem'
assert_eq 550 "$(calculate_htb_burst_kb 450)" '450M HTB burst'
assert_eq 1160 "$(calculate_htb_burst_kb 950)" '950M HTB burst'
assert_eq '推荐均衡' "$(profile_label balanced)" 'Chinese profile label'
assert_eq '多设备自适应（不限制整机总速）' "$(limit_mode_label adaptive)" 'adaptive mode label'
assert_eq 'fq（连接公平排队，不限速）' "$(queue_label on adaptive fq)" 'adaptive queue label'
assert_eq 'fq maxrate（单条 TCP 连接上限）' "$(queue_label on perflow fq)" 'perflow queue label'
assert_eq 'TBF + fq（兼容整机总出口）' "$(queue_label on total tbf)" 'total TBF queue label'
assert_eq 'fq（连接公平排队，不限速）' "$(queue_label off total htb)" 'paused queue label'
assert_eq 'HTB + fq maxrate（总出口＋单连接上限）' "$(queue_label on combo htb)" 'combo queue label'
assert_eq 'fq maxrate（单条 TCP 连接上限）' "$(queue_label on combo fq)" 'combo no-total queue label'

render_test() {
  SHAPING="$1" LIMIT_MODE="$2" RATE_MBPS="$3" RTT_MS=160 SHAPER_MODE="$4" TOTAL_MBPS="${5:-0}"
  render_menu
}
menu_out="$(render_test on combo 430 htb 2300)"
[[ "$menu_out" == *'▸ 1) 430 Mbps'* && "$menu_out" == *'整机 ≤ 2300 Mbps'* ]] || { printf 'FAIL: combo 430 menu marker\n' >&2; exit 1; }
printf 'PASS: combo 430 menu marker\n'
menu_out="$(render_test on combo 850 htb 2300)"
[[ "$menu_out" == *'▸ 3) 850 Mbps'* ]] || { printf 'FAIL: combo 850 menu marker\n' >&2; exit 1; }
printf 'PASS: combo 850 menu marker\n'
menu_out="$(render_test on adaptive 450 fq)"
[[ "$menu_out" == *'▸ 6) 不限速自适应'* ]] || { printf 'FAIL: adaptive menu marker\n' >&2; exit 1; }
printf 'PASS: adaptive menu marker\n'
menu_out="$(render_test off combo 430 htb 2300)"
[[ "$menu_out" == *'已暂停人为限速'* && "$menu_out" != *'▸ 1)'* ]] || { printf 'FAIL: paused menu state\n' >&2; exit 1; }
printf 'PASS: paused menu state\n'

tc_log="$(mktemp)"
need_root() { :; }
has() { return 0; }
load_config() {
  RATE_MBPS="${TEST_RATE_MBPS:-900}"
  TOTAL_MBPS="${TEST_TOTAL_MBPS:-0}"
  SHAPING=on
  SHAPER_MODE=auto
  LIMIT_MODE="${TEST_LIMIT_MODE:-total}"
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
  if [[ "${TC_REJECT_CAKE:-0}" == 1 && " $line " == *' cake '* ]]; then
    return 1
  fi
  if [[ "${TC_REJECT_HTB:-0}" == 1 && " $line " == *' htb '* ]]; then
    return 1
  fi
}
apply_shape >/dev/null
assert_eq 'qdisc del dev eth-test root' "$(sed -n '1p' "$tc_log")" 'remove old root before shaping'
assert_eq 'qdisc add dev eth-test root cake bandwidth 900mbit besteffort dual-dsthost' "$(sed -n '2p' "$tc_log")" 'prefer CAKE per-device fairness'
assert_eq cake "$SHAPER_MODE" 'remember CAKE shaper'

: > "$tc_log"
TC_REJECT_CAKE=1
apply_shape >/dev/null 2>&1
assert_eq 'qdisc add dev eth-test root handle 1: htb default 10 r2q 1000' "$(sed -n '4p' "$tc_log")" 'fallback to HTB root'
assert_eq htb "$SHAPER_MODE" 'remember HTB shaper'

: > "$tc_log"
TC_REJECT_CAKE=1
TC_REJECT_HTB=1
apply_shape >/dev/null 2>&1
assert_eq 'qdisc add dev eth-test root handle 1: tbf rate 900mbit burst 1099kb latency 50ms' "$(sed -n '6p' "$tc_log")" 'fallback to TBF root'
assert_eq tbf "$SHAPER_MODE" 'remember compatible shaper'

: > "$tc_log"
unset TC_REJECT_CAKE TC_REJECT_HTB
TEST_LIMIT_MODE=combo
TEST_RATE_MBPS=430
TEST_TOTAL_MBPS=2300
apply_shape >/dev/null
assert_eq 'class add dev eth-test parent 1: classid 1:10 htb rate 2300mbit ceil 2300mbit burst 2048kb cburst 2048kb quantum 15140' "$(sed -n '3p' "$tc_log")" 'combo HTB total class'
assert_eq 'qdisc add dev eth-test parent 1:10 handle 10: fq maxrate 430mbit' "$(sed -n '4p' "$tc_log")" 'combo per-flow maxrate child'
assert_eq htb "$SHAPER_MODE" 'combo records htb'

: > "$tc_log"
TEST_TOTAL_MBPS=0
apply_shape >/dev/null
assert_eq 'qdisc add dev eth-test root fq maxrate 430mbit' "$(sed -n '2p' "$tc_log")" 'combo without total uses fq maxrate'
assert_eq fq "$SHAPER_MODE" 'combo records fq when total off'

: > "$tc_log"
TEST_LIMIT_MODE=adaptive
apply_shape >/dev/null
assert_eq 'qdisc replace dev eth-test root fq' "$(sed -n '2p' "$tc_log")" 'adaptive mode uses unlimited fq'
assert_eq fq "$SHAPER_MODE" 'adaptive mode records fq'
rm -f "$tc_log"

has() { [[ "$1" != nginx ]]; }
snippet_out="$(write_nginx_snippet 2>&1)"
[[ "$snippet_out" == *'跳过 Emby 反代片段'* ]] || { printf 'FAIL: skip snippet without nginx\n' >&2; exit 1; }
printf 'PASS: skip snippet without nginx\n'

printf '%s\n' 'All self-tests passed.'
