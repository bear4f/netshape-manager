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

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

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
assert_eq 550 "$(calculate_htb_burst_kb 450 throughput)" '450M HTB burst (throughput)'
assert_eq 1160 "$(calculate_htb_burst_kb 950 throughput)" '950M HTB burst (throughput)'
assert_eq 55 "$(calculate_htb_burst_kb 450 policer)" '450M HTB burst (policer)'
assert_eq 116 "$(calculate_htb_burst_kb 950 policer)" '950M HTB burst (policer)'
assert_eq '推荐均衡' "$(profile_label balanced)" 'Chinese profile label'
assert_eq '多设备自适应（不限制整机总速）' "$(limit_mode_label adaptive)" 'adaptive mode label'
assert_eq 'fq（连接公平排队，不限速）' "$(queue_label on adaptive fq)" 'adaptive queue label'
assert_eq 'fq maxrate（单条 TCP 连接上限）' "$(queue_label on perflow fq)" 'perflow queue label'
assert_eq 'TBF + fq（兼容整机总出口）' "$(queue_label on total tbf)" 'total TBF queue label'
assert_eq 'fq（连接公平排队，不限速）' "$(queue_label off total htb)" 'paused queue label'
assert_eq 'HTB + fq maxrate（总出口＋单连接上限）' "$(queue_label on combo htb)" 'combo queue label'
assert_eq 'fq maxrate（单条 TCP 连接上限）' "$(queue_label on combo fq)" 'combo no-total queue label'

# The whole point of TUNED_KEYS is that rollback covers everything tune sets.
# Drift between the two is exactly the bug this list exists to prevent.
declared_keys="$(printf '%s\n' $TUNED_KEYS | sort)"
applied_keys="$(grep -oE 'append_sysctl "\$temp" [a-z]+(\.[a-z0-9_-]+)+' "$ROOT/netshape-manager.sh" \
  | awk '{print $3}' | sort -u)"
if [[ "$declared_keys" != "$applied_keys" ]]; then
  printf 'FAIL: TUNED_KEYS does not match append_sysctl calls\n' >&2
  diff <(printf '%s\n' "$declared_keys") <(printf '%s\n' "$applied_keys") >&2 || true
  exit 1
fi
printf 'PASS: TUNED_KEYS covers every tuned sysctl (%s keys)\n' "$(printf '%s\n' "$declared_keys" | wc -l | tr -d ' ')"

assert_eq 53 "$(calculate_htb_burst_kb 430 policer)" '430M policer burst'
assert_eq 256 "$(calculate_htb_burst_kb 2300 policer)" 'policer burst ceiling'
assert_eq 32 "$(calculate_htb_burst_kb 100 policer)" 'policer burst floor'
assert_eq 525 "$(calculate_htb_burst_kb 430 throughput)" '430M throughput burst'
assert_eq 2048 "$(calculate_htb_burst_kb 2300 throughput)" 'throughput burst ceiling'
assert_eq 53 "$(calculate_htb_burst_kb 430)" 'burst defaults to policer'

assert_eq '10240 2048' "$(fq_leaf_limits 512)" 'small RAM fq leaf limits'
assert_eq '40960 8192' "$(fq_leaf_limits 2048)" 'normal fq leaf limits'

assert_eq '2 倍 BDP' "$(buffer_cap_reason 450 160 2048)" 'buffer pinned by BDP'
assert_eq '受 1024 MB 内存限制' "$(buffer_cap_reason 950 160 1024)" 'buffer pinned by RAM'
assert_eq '下限 8 MiB' "$(buffer_cap_reason 100 20 2048)" 'buffer pinned by floor'
# The RAM ladder must stay at or below the tcp_mem budget rule on every tier.
for _mem in 256 512 1024 2048 4096 8192 65536; do
  _cap="$(memory_buffer_cap "$_mem")"
  _budget="$(tcp_mem_budget_cap "$_mem")"
  (( _cap <= _budget )) || { printf 'FAIL: buffer cap %s exceeds tcp_mem budget %s at %s MB\n' "$_cap" "$_budget" "$_mem" >&2; exit 1; }
done
printf 'PASS: buffer cap stays within the tcp_mem budget on every RAM tier\n'

assert_eq 2300 "$(tc_rate_to_mbps 2300Mbit)" 'tc Mbit parsing'
assert_eq 1000 "$(tc_rate_to_mbps 1Gbit)" 'tc Gbit parsing'
assert_eq 900 "$(tc_rate_to_mbps 900Mbit)" 'tc Mbit parsing exact'
assert_eq 2 "$(tc_rate_to_mbps 1500Kbit)" 'tc Kbit parsing'
assert_eq 0 "$(tc_rate_to_mbps 100Kbit)" 'tc sub-Mbit parsing'
assert_eq 2300 "$(tc_rate_to_mbps 2300000000bit)" 'tc bare bit parsing'

assert_eq fq "$(expected_root_qdisc off combo htb 2300)" 'paused expects fq'
assert_eq fq "$(expected_root_qdisc on adaptive fq 0)" 'adaptive expects fq'
assert_eq fq "$(expected_root_qdisc on perflow fq 0)" 'perflow expects fq'
assert_eq fq "$(expected_root_qdisc on combo auto 0)" 'combo without total expects fq'
assert_eq htb "$(expected_root_qdisc on combo htb 2300)" 'combo with total expects htb'
assert_eq cake "$(expected_root_qdisc on total cake 900)" 'total expects recorded shaper'

has() { [[ "$1" == tc ]]; }
tc() { printf 'qdisc fq 8001: root refcnt 2 limit 10000p\n'; }
assert_eq '' "$(qdisc_drift eth-test on combo auto 0)" 'fq matches combo without total'
assert_eq fq "$(qdisc_drift eth-test on combo htb 2300)" 'fq flagged when HTB expected'
tc() { printf 'qdisc htb 1: root refcnt 2 r2q 1000\n'; }
assert_eq '' "$(qdisc_drift eth-test on combo htb 2300)" 'htb matches combo with total'
assert_eq htb "$(qdisc_drift eth-test off combo htb 2300)" 'htb flagged while paused'
assert_eq '' "$(qdisc_drift eth-test on total auto 900)" 'auto accepts any shaper qdisc'
tc() { return 1; }
assert_eq '' "$(qdisc_drift eth-test on combo htb 2300)" 'no drift claim without tc output'

has() { [[ "$1" == nstat ]]; }
nstat() { printf 'TcpOutSegs 1000000 0.0\nTcpRetransSegs 3000 0.0\n'; }
assert_eq 0.30 "$(retrans_rate)" 'retransmission percentage'
assert_eq '干净' "$(retrans_verdict 0.002)" 'clean retransmission verdict'
assert_eq '偏高，线路或档位需要留意' "$(retrans_verdict 0.30)" 'elevated retransmission verdict'
assert_eq '撞限速器，建议把单连接上限降一档' "$(retrans_verdict 1.40)" 'policer retransmission verdict'
nstat() { printf 'TcpOutSegs 0 0.0\nTcpRetransSegs 0 0.0\n'; }
assert_eq '' "$(retrans_rate)" 'no rate without sent segments'
has() { return 1; }
assert_eq '' "$(retrans_rate)" 'no rate without nstat'
assert_eq none "$(nginx_snippet_state)" 'no snippet state without nginx'

# A rejected value on the last line must not make load_config exit non-zero,
# which errexit would turn into the whole script dying.
cfg_dir="$(mktemp -d)"
printf 'RATE_MBPS=430\nBURST_MODE=evil\n' > "$cfg_dir/conf"
# shellcheck disable=SC2218  # load_config comes from the sourced script above
CONFIG_FILE="$cfg_dir/conf" load_config
assert_eq policer "$BURST_MODE" 'bad BURST_MODE falls back to the default'
assert_eq 430 "$RATE_MBPS" 'valid keys still load alongside a rejected one'
printf 'INITCWND=9999\n' > "$cfg_dir/conf"
# shellcheck disable=SC2218
CONFIG_FILE="$cfg_dir/conf" load_config
assert_eq 32 "$INITCWND" 'out-of-range INITCWND falls back to the default'
rm -rf "$cfg_dir"

# ── 落地鸡：固定缓冲，与 RTT/BDP 无关 ─────────────────────────────────────
# Measured on a real landing box: 1ms to every relay, and the ~1Gbps ceiling
# was an upstream policer, not a buffer shortage. So the ceiling is fixed.
assert_eq 33554432 "$(landing_buffer_cap 2048)" 'landing buffer is 32 MiB at 2G RAM'
assert_eq 33554432 "$(landing_buffer_cap 1024)" 'landing buffer is 32 MiB at exactly 1G RAM'
assert_eq 16777216 "$(landing_buffer_cap 512)" 'landing buffer drops to 16 MiB below 1G RAM'
(( $(landing_buffer_cap 512) <= 16777216 )) || fail 'small-RAM landing cap must not exceed 16 MiB'
pass 'small-RAM landing cap stays within 16 MiB'
# The whole point: no origin RTT, however large, may move it.
for _o in 150 250 500 3000; do
  ORIGIN_RTT_MS="$_o"
  (( $(landing_buffer_cap 2048) == 33554432 )) \
    || fail "landing buffer moved with ORIGIN_RTT_MS=$_o"
done
pass 'landing buffer ignores ORIGIN_RTT_MS entirely'

# ── 落地鸡：端口档位 → HTB cap（约 98% 线速）──────────────────────────────
assert_eq 490 "$(landing_recommended_cap 500)" '500M port maps to 490'
assert_eq 980 "$(landing_recommended_cap 1000)" '1G port maps to 980'
assert_eq 1960 "$(landing_recommended_cap 2000)" '2G port maps to 1960'
assert_eq 2450 "$(landing_recommended_cap 2500)" '2.5G port maps to 2450'
assert_eq 392 "$(landing_recommended_cap 400)" 'an unlisted port falls back to 98%'
# The old 1G->900 / 500->450 tiers threw away 8% of the line for nothing.
(( $(landing_recommended_cap 1000) > 900 )) || fail 'the 1G tier must beat the old 900'
pass 'the new tiers are less conservative than the old ones'

# ── 落地鸡：小突发 ────────────────────────────────────────────────────────
# ~1ms of tokens rounded to a 16 KiB boundary. A policer judges instantaneous
# rate, and landing faces the provider's limiter directly.
assert_eq 128 "$(landing_burst_kb 980)" '980M burst lands on 128 KiB'
assert_eq 64 "$(landing_burst_kb 490)" '490M burst'
assert_eq 240 "$(landing_burst_kb 1960)" '1960M burst'
assert_eq 32 "$(landing_burst_kb 100)" 'burst floor is 32 KiB'
assert_eq 256 "$(landing_burst_kb 100000)" 'burst ceiling is 256 KiB'
# Must be far below relay's 10ms bucket at the same rate.
(( $(landing_burst_kb 980) < $(calculate_htb_burst_kb 980 throughput) / 4 )) \
  || fail 'landing burst should be far smaller than the throughput bucket'
pass 'landing burst is far below the 10ms throughput bucket'

# ── 落地鸡：浅 fq 叶子 ────────────────────────────────────────────────────
assert_eq '10000 256' "$(landing_fq_leaf_limits)" 'landing fq leaf is 10000 / 256'
# relay keeps its own memory-scaled depths, untouched.
assert_eq '40960 8192' "$(fq_leaf_limits 2048)" 'relay fq leaf is unchanged'

assert_eq '落地鸡' "$(role_short landing)" 'landing short label'
assert_eq '中转/观看' "$(role_short relay)" 'relay short label'

render_test() {
  SHAPING="$1" LIMIT_MODE="$2" RATE_MBPS="$3" RTT_MS=160 SHAPER_MODE="$4" TOTAL_MBPS="${5:-0}"
  ROLE=relay ORIGIN_RTT_MS=150
  render_menu
}
landing_render_test() {
  SHAPING="${1:-on}" LIMIT_MODE="${2:-total}" RATE_MBPS="${3:-980}"
  ROLE=landing RTT_MS=1 ORIGIN_RTT_MS=150 SHAPER_MODE=htb BURST_MODE=policer
  TOTAL_MBPS="$RATE_MBPS" INITCWND=0
  render_landing_menu
}
landing_out="$(landing_render_test)"
[[ "$landing_out" == *'NetShape · 落地鸡'* && "$landing_out" == *'HTB 出口'* ]] \
  || fail 'landing panel header'
pass 'landing panel leads with the HTB cap'
[[ "$landing_out" == *'980 Mbps'* && "$landing_out" == *'到中转     1 ms'* ]] \
  || fail 'landing panel shows cap and relay RTT'
pass 'landing panel shows the aggregate cap and the 1ms relay RTT'
[[ "$landing_out" == *'burst 128 KiB'* && "$landing_out" == *'fq leaf 10000 / 256'* ]] \
  || fail 'landing panel shows burst and leaf depth'
pass 'landing panel shows burst and fq leaf depth'
[[ "$landing_out" == *'initcwnd'*'关闭'* ]] || fail 'landing panel should show initcwnd off'
pass 'landing panel shows initcwnd disabled'
[[ "$landing_out" == *'32 MiB'* ]] || fail 'landing panel should show the fixed buffer'
pass 'landing panel shows the fixed 32 MiB buffer'
# The home-broadband tiers and the deprecated origin RTT are both gone.
[[ "$landing_out" != *'家宽档位'* && "$landing_out" != *'430 Mbps —— 500M 家宽'* ]] \
  || fail 'landing panel still offers home-broadband tiers'
pass 'landing panel drops the home-broadband tiers'
[[ "$landing_out" != *'回源参考'* ]] || fail 'landing panel should not show the deprecated origin RTT'
pass 'landing panel no longer shows the deprecated origin RTT'
[[ "$landing_out" == *'u)'*'卸载'* ]] || fail 'landing panel should offer uninstall'
pass 'landing panel offers uninstall'
landing_out="$(landing_render_test on adaptive 1000)"
[[ "$landing_out" == *'未设上限'* && "$landing_out" == *'没有 aggregate 上限'* ]] \
  || fail 'unshaped landing must warn'
pass 'landing without an aggregate cap warns about the upstream policer'

menu_out="$(render_test on combo 430 htb 2300)"
[[ "$menu_out" == *'l) 切换为落地鸡模式'* && "$menu_out" == *'机器角色  中转/观看'* ]] \
  || { printf 'FAIL: relay panel offers the landing switch\n' >&2; exit 1; }
printf 'PASS: relay panel offers the landing switch\n'
menu_out="$(render_test on combo 430 htb 2300)"
[[ "$menu_out" == *'▸ 1) 430 Mbps'* && "$menu_out" == *'整机 ≤ 2300 Mbps'* ]] || { printf 'FAIL: combo 430 menu marker\n' >&2; exit 1; }
printf 'PASS: combo 430 menu marker\n'
menu_out="$(render_test on combo 850 htb 2300)"
[[ "$menu_out" == *'▸ 3) 850 Mbps'* ]] || { printf 'FAIL: combo 850 menu marker\n' >&2; exit 1; }
printf 'PASS: combo 850 menu marker\n'
menu_out="$(render_test on combo 600 htb 2300)"
[[ "$menu_out" == *'▸ 5) 自定义单条连接上限'* && "$menu_out" == *'当前：600 Mbps'* ]] || { printf 'FAIL: custom rate menu marker\n' >&2; exit 1; }
printf 'PASS: custom rate menu marker\n'
menu_out="$(render_test on adaptive 450 fq)"
[[ "$menu_out" == *'▸ 7) 不限速自适应'* ]] || { printf 'FAIL: adaptive menu marker\n' >&2; exit 1; }
printf 'PASS: adaptive menu marker\n'
menu_out="$(render_test off combo 430 htb 2300)"
[[ "$menu_out" == *'已暂停人为限速'* && "$menu_out" != *'▸ 1)'* ]] || { printf 'FAIL: paused menu state\n' >&2; exit 1; }
printf 'PASS: paused menu state\n'
[[ "$menu_out" == *'p) 恢复人为限速'* ]] || { printf 'FAIL: paused offers resume key\n' >&2; exit 1; }
printf 'PASS: paused offers resume key\n'
menu_out="$(render_test on combo 430 htb 2300)"
[[ "$menu_out" == *'p) 暂停人为限速'* && "$menu_out" == *'a) 重新应用当前配置'* ]] || { printf 'FAIL: menu offers pause and reapply keys\n' >&2; exit 1; }
printf 'PASS: menu offers pause and reapply keys\n'

tc_log="$(mktemp)"
STATE_DIR="$(mktemp -d)"
need_root() { :; }
take_lock() { :; }
has() { return 0; }
mem_total_mb() { printf '%s\n' "${TEST_MEM_MB:-2048}"; }
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
  BURST_MODE="${TEST_BURST_MODE:-policer}"
  INITCWND=32
}
save_config() { :; }
resolve_iface() { printf '%s\n' eth-test; }
modprobe() { :; }
# Only mutations are logged: `tc ... show` is a query, and logging it would
# make the assertions below depend on how often the code inspects state.
tc() {
  local first=1 arg line=''
  for arg in "$@"; do
    line="${line}${line:+ }${arg}"
  done
  case "${2:-}" in
    show) return "${TC_SHOW_RC:-0}" ;;
  esac
  for arg in "$@"; do
    (( first == 1 )) || printf ' ' >> "$tc_log"
    printf '%s' "$arg" >> "$tc_log"
    first=0
  done
  printf '\n' >> "$tc_log"
  if [[ "${TC_REJECT_CAKE:-0}" == 1 && " $line " == *' cake '* ]]; then
    return 1
  fi
  if [[ "${TC_REJECT_HTB:-0}" == 1 && " $line " == *' htb '* ]]; then
    return 1
  fi
  if [[ "${TC_REJECT_FQ_LIMITS:-0}" == 1 && " $line " == *' flow_limit '* ]]; then
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
assert_eq 'qdisc add dev eth-test root handle 1: tbf rate 900mbit burst 110kb latency 50ms' "$(sed -n '6p' "$tc_log")" 'fallback to TBF root'
assert_eq tbf "$SHAPER_MODE" 'remember compatible shaper'

: > "$tc_log"
unset TC_REJECT_CAKE TC_REJECT_HTB
TEST_LIMIT_MODE=combo
TEST_RATE_MBPS=430
TEST_TOTAL_MBPS=2300
apply_shape >/dev/null
assert_eq 'class add dev eth-test parent 1: classid 1:10 htb rate 2300mbit ceil 2300mbit burst 256kb cburst 256kb quantum 15140' "$(sed -n '3p' "$tc_log")" 'combo HTB total class'
assert_eq 'qdisc add dev eth-test parent 1:10 handle 10: fq limit 40960 flow_limit 8192 maxrate 430mbit' "$(sed -n '4p' "$tc_log")" 'combo per-flow maxrate child'
assert_eq htb "$SHAPER_MODE" 'combo records htb'

: > "$tc_log"
TEST_TOTAL_MBPS=0
apply_shape >/dev/null
assert_eq 'qdisc add dev eth-test root fq limit 40960 flow_limit 8192 maxrate 430mbit' "$(sed -n '2p' "$tc_log")" 'combo without total uses fq maxrate'
assert_eq fq "$SHAPER_MODE" 'combo records fq when total off'

: > "$tc_log"
TEST_LIMIT_MODE=adaptive
apply_shape >/dev/null
assert_eq 'qdisc replace dev eth-test root fq' "$(sed -n '2p' "$tc_log")" 'adaptive mode uses unlimited fq'
assert_eq fq "$SHAPER_MODE" 'adaptive mode records fq'

# An fq that rejects limit/flow_limit must retry plain rather than look like
# "HTB unsupported" and drag the whole machine down to the TBF fallback.
: > "$tc_log"
TEST_LIMIT_MODE=combo
TEST_RATE_MBPS=430
TEST_TOTAL_MBPS=2300
TC_REJECT_FQ_LIMITS=1
apply_shape >/dev/null 2>&1
assert_eq 'qdisc add dev eth-test parent 1:10 handle 10: fq maxrate 430mbit' "$(sed -n '5p' "$tc_log")" 'fq leaf retries without limits'
assert_eq htb "$SHAPER_MODE" 'old fq does not force the TBF fallback'
unset TC_REJECT_FQ_LIMITS

: > "$tc_log"
TEST_MEM_MB=512
apply_shape >/dev/null 2>&1
assert_eq 'qdisc add dev eth-test parent 1:10 handle 10: fq limit 10240 flow_limit 2048 maxrate 430mbit' "$(sed -n '4p' "$tc_log")" 'small-memory box gets shallower fq leaves'
unset TEST_MEM_MB

: > "$tc_log"
TEST_BURST_MODE=throughput
apply_shape >/dev/null 2>&1
assert_eq 'class add dev eth-test parent 1: classid 1:10 htb rate 2300mbit ceil 2300mbit burst 2048kb cburst 2048kb quantum 15140' "$(sed -n '3p' "$tc_log")" 'throughput burst mode reaches tc'
unset TEST_BURST_MODE

# mq is rebuilt by the kernel with fq leaves; collapsing it to a single root fq
# permanently costs a multi-queue NIC its per-queue structure.
: > "$tc_log"
printf 'mq\n' > "$STATE_DIR/baseline-qdisc"
restore_default_qdisc eth-test
assert_eq 'qdisc del dev eth-test root' "$(cat "$tc_log")" 'mq baseline is left for the kernel to rebuild'
: > "$tc_log"
restore_baseline_qdisc eth-test
assert_eq 'qdisc del dev eth-test root' "$(cat "$tc_log")" 'mq baseline is not re-added on uninstall'
: > "$tc_log"
printf 'fq_codel\n' > "$STATE_DIR/baseline-qdisc"
restore_baseline_qdisc eth-test
assert_eq 'qdisc replace dev eth-test root fq_codel' "$(sed -n '2p' "$tc_log")" 'named baseline qdisc is restored on uninstall'
: > "$tc_log"
printf 'pfifo_fast\n' > "$STATE_DIR/baseline-qdisc"
restore_default_qdisc eth-test
assert_eq 'qdisc replace dev eth-test root fq' "$(sed -n '2p' "$tc_log")" 'non-mq baseline still gets fq while shaping is paused'
rm -f "$STATE_DIR/baseline-qdisc"

# verify_shaper must compare numbers: tc prints 1000mbit back as "1Gbit".
tc() { printf 'class htb 1:10 root rate 1Gbit ceil 1Gbit burst 256Kb\n'; }
verify_shaper eth-test htb 1000 || { printf 'FAIL: verify accepts unit-normalised rate\n' >&2; exit 1; }
printf 'PASS: verify accepts unit-normalised rate\n'
verify_shaper eth-test htb 2300 2>/dev/null && { printf 'FAIL: verify should reject a mismatched rate\n' >&2; exit 1; }
printf 'PASS: verify rejects a mismatched rate\n'
tc() { printf 'qdisc noqueue 0: root refcnt 2\n'; }
verify_shaper eth-test htb 1000 2>/dev/null && { printf 'FAIL: verify should reject a missing class\n' >&2; exit 1; }
printf 'PASS: verify rejects a missing shaper\n'
rm -f "$tc_log"; rm -rf "$STATE_DIR"

has() { [[ "$1" != nginx ]]; }
snippet_out="$(write_nginx_snippet 2>&1)"
[[ "$snippet_out" == *'跳过 Emby 反代片段'* ]] || { printf 'FAIL: skip snippet without nginx\n' >&2; exit 1; }
printf 'PASS: skip snippet without nginx\n'

has() { return 0; }
audit_dir="$(mktemp -d)"
NGINX_SNIPPET="$audit_dir/netshape-emby-proxy.conf"
: > "$NGINX_SNIPPET"
nginx() { printf 'server { location / { proxy_pass http://emby; } }\n'; }
audit_out="$(nginx_audit 2>&1)"
[[ "$audit_out" == *'没有任何站点 include'* && "$audit_out" == *'未发现 proxy_buffering off'* ]] || { printf 'FAIL: audit flags missing include\n' >&2; exit 1; }
printf 'PASS: audit flags missing include\n'
nginx() { printf 'include %s;\nproxy_buffering off;\n' "$NGINX_SNIPPET"; }
audit_out="$(nginx_audit 2>&1)"
[[ "$audit_out" == *'片段已被 include'* && "$audit_out" == *'已找到 proxy_buffering off'* ]] || { printf 'FAIL: audit confirms applied snippet\n' >&2; exit 1; }
printf 'PASS: audit confirms applied snippet\n'
rm -rf "$audit_dir"

# ── 落地鸡：sysctl 只写该写的 ─────────────────────────────────────────────
prof_dir="$(mktemp -d)"
_orig_sysctl_file="$SYSCTL_FILE"; _orig_state="$STATE_DIR"
SYSCTL_FILE="$prof_dir/99-landing.conf"; STATE_DIR="$prof_dir"
SNAPSHOT_FILE="$prof_dir/snap"
has() { [[ "$1" != sysctl && "$1" != modprobe ]]; }
choose_congestion_control() { printf 'bbr\n'; }
mem_total_mb() { printf '%s\n' "${TEST_MEM_MB:-2048}"; }
write_landing_sysctl_profile >/dev/null 2>&1
landing_conf="$(cat "$SYSCTL_FILE")"

# Every key the brief says landing must set.
for _k in net.ipv4.tcp_congestion_control net.core.default_qdisc \
          net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
          net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_window_scaling \
          net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_no_metrics_save \
          net.ipv4.tcp_fastopen net.ipv4.tcp_mtu_probing net.ipv4.tcp_ecn \
          net.core.netdev_max_backlog net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min; do
  [[ "$landing_conf" == *"$_k "* ]] || fail "landing profile is missing $_k"
done
pass 'landing writes every key it is supposed to'
[[ "$landing_conf" == *'net.core.rmem_max = 33554432'* ]] || fail 'landing rmem_max should be 32 MiB'
[[ "$landing_conf" == *'net.ipv4.tcp_rmem = 4096 87380 33554432'* ]] || fail 'landing tcp_rmem'
[[ "$landing_conf" == *'net.ipv4.tcp_wmem = 4096 16384 33554432'* ]] || fail 'landing tcp_wmem'
[[ "$landing_conf" == *'net.ipv4.tcp_fastopen = 3'* ]] || fail 'landing enables TFO'
[[ "$landing_conf" == *'net.ipv4.udp_rmem_min = 8192'* ]] || fail 'landing udp_rmem_min'
pass 'landing buffer values match the measured baseline'

# The forbidden list: system-policy knobs a speed tool must not own.
for _k in net.ipv4.tcp_mem net.ipv4.tcp_adv_win_scale net.ipv4.tcp_notsent_lowat \
          net.ipv4.tcp_fastopen_blackhole_timeout_sec net.ipv4.tcp_tw_reuse \
          net.ipv4.tcp_fin_timeout net.ipv4.tcp_keepalive_time \
          net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes \
          net.ipv4.tcp_max_tw_buckets net.ipv4.ip_local_port_range \
          net.core.somaxconn net.ipv4.tcp_max_syn_backlog \
          net.netfilter.nf_conntrack_max vm.min_free_kbytes; do
  [[ "$landing_conf" != *"$_k"* ]] || fail "landing must not write $_k"
done
pass 'landing writes none of the forbidden keys'

TEST_MEM_MB=512
write_landing_sysctl_profile >/dev/null 2>&1
[[ "$(cat "$SYSCTL_FILE")" == *'net.core.rmem_max = 16777216'* ]] \
  || fail 'small-RAM landing should cap at 16 MiB'
pass 'landing drops to 16 MiB on a sub-1G box'
unset TEST_MEM_MB

# Relay must still emit the full set it always did.
ROLE=relay RATE_MBPS=430 RTT_MS=160 LINE_MBPS=500
need_root() { :; }
take_lock() { :; }
take_snapshot() { :; }
load_config() { :; }
release_unmanaged_keys() { :; }
swap_total_mb() { printf '2048\n'; }
write_sysctl_profile >/dev/null 2>&1
relay_conf="$(cat "$SYSCTL_FILE")"
for _k in net.ipv4.tcp_mem net.ipv4.tcp_adv_win_scale net.ipv4.tcp_notsent_lowat \
          net.ipv4.tcp_tw_reuse net.ipv4.tcp_fin_timeout net.ipv4.tcp_keepalive_time \
          net.core.somaxconn net.ipv4.ip_local_port_range; do
  [[ "$relay_conf" == *"$_k "* ]] || fail "relay lost $_k"
done
pass 'relay still writes its full original key set'
[[ "$relay_conf" == *'net.ipv4.tcp_fastopen = 0'* ]] || fail 'relay keeps TFO off'
pass 'relay keeps TCP Fast Open off for cross-border middleboxes'
SYSCTL_FILE="$_orig_sysctl_file"; STATE_DIR="$_orig_state"
rm -rf "$prof_dir"

# ── 落地鸡：fq 叶子在老内核上的回退 ───────────────────────────────────────
# Rejecting limit/flow_limit must not be read as "HTB unsupported".
tc_log="$(mktemp)"
has() { return 0; }
tc() {
  local IFS=' '
  local line="$*"
  printf '%s\n' "$line" >> "$tc_log"
  [[ "${TC_REJECT_FQ_LIMITS:-0}" == 1 && "$line" == *flow_limit* ]] && return 1
  return 0
}
: > "$tc_log"
add_landing_fq_leaf eth-test 1:10 10: /dev/null
assert_eq 'qdisc add dev eth-test parent 1:10 handle 10: fq limit 10000 flow_limit 256' \
  "$(head -1 "$tc_log")" 'landing fq leaf uses bare integers, no trailing p'
: > "$tc_log"
TC_REJECT_FQ_LIMITS=1
add_landing_fq_leaf eth-test 1:10 10: /dev/null || fail 'fq leaf should fall back'
assert_eq 'qdisc add dev eth-test parent 1:10 handle 10: fq' \
  "$(sed -n 2p "$tc_log")" 'landing fq leaf falls back to plain fq'
unset TC_REJECT_FQ_LIMITS
# A failing HTB step must not leave half a class behind.
: > "$tc_log"
tc() {
  local IFS=' '
  printf '%s\n' "$*" >> "$tc_log"
  [[ "$1 $2" == "class add" ]] && return 1
  return 0
}
try_landing_htb eth-test 980 128 /dev/null && fail 'a failing class add should fail the attempt'
[[ "$(tail -1 "$tc_log")" == 'qdisc del dev eth-test root' ]] \
  || fail 'a failed HTB attempt must tear the root down'
pass 'a failed HTB attempt leaves no half-built class'
rm -f "$tc_log"

# ── 落地鸡：切换过来会清掉 initcwnd ───────────────────────────────────────
route_log="$(mktemp)"
has() { [[ "$1" == ip ]]; }
ROUTE_HOOK="$(mktemp)"
ip() {
  if [[ "$1 $2" == "route show" ]]; then printf '%s\n' "$ROUTE_SPEC"; return 0; fi
  if [[ "$1 $2" == "route replace" ]]; then shift 2; local IFS=' '; printf '%s\n' "$*" >> "$route_log"; return 0; fi
  return 0
}
ROUTE_SPEC='default via 10.0.0.1 dev eth0 proto dhcp metric 100 initcwnd 32 initrwnd 32'
clear_initcwnd >/dev/null 2>&1
assert_eq 'default via 10.0.0.1 dev eth0 proto dhcp metric 100' "$(cat "$route_log")" \
  'switching to landing strips initcwnd and initrwnd from the default route'
[[ ! -e "$ROUTE_HOOK" ]] || fail 'the networkd hook must be removed too'
pass 'the initcwnd route hook is removed as well'
: > "$route_log"
ROUTE_SPEC='default via 10.0.0.1 dev eth0 proto dhcp metric 100'
clear_initcwnd >/dev/null 2>&1
assert_eq '' "$(cat "$route_log")" 'a route without initcwnd is left alone'
rm -f "$route_log"

# ── 落地鸡：set_landing 的最终状态 ────────────────────────────────────────
# Re-source to restore every function earlier sections stubbed out: this block
# needs a real load_config/save_config round trip to prove what set_landing
# actually persists. (unset -f would delete them, not restore them.)
. "$ROOT/netshape-manager.sh"
cfg2="$(mktemp -d)"
CONFIG_FILE="$cfg2/conf"
has() { return 1; }
need_root() { :; }
take_lock() { :; }
apply_all() { :; }
default_config
ROLE=relay RTT_MS=160 INITCWND=32
save_config
set_landing 980 >/dev/null 2>&1
load_config
assert_eq landing "$ROLE" 'set_landing switches the role'
assert_eq total "$LIMIT_MODE" 'set_landing uses an aggregate limit mode'
assert_eq htb "$SHAPER_MODE" 'set_landing pins HTB rather than auto'
assert_eq policer "$BURST_MODE" 'set_landing uses the small burst'
assert_eq 0 "$INITCWND" 'set_landing disables initcwnd'
assert_eq 1 "$RTT_MS" 'landing defaults to a 1ms relay RTT'
assert_eq 980 "$RATE_MBPS" 'set_landing stores the aggregate cap'
# An existing landing box keeps a hand-set RTT when the cap changes.
RTT_MS=2; save_config
set_landing 1960 >/dev/null 2>&1
load_config
assert_eq 2 "$RTT_MS" 'changing the cap does not reset a hand-set landing RTT'
assert_eq 1960 "$RATE_MBPS" 'the new cap is stored'
# Unlimited landing is allowed but must not pretend to have a shaper.
set_landing 0 >/dev/null 2>&1
load_config
assert_eq adaptive "$LIMIT_MODE" 'an unlimited landing box is adaptive'
assert_eq fq "$SHAPER_MODE" 'an unlimited landing box records fq'
# Going back to relay restores relay-shaped defaults.
set_relay_role >/dev/null 2>&1
load_config
assert_eq relay "$ROLE" 'set_relay_role switches back'
assert_eq 430 "$RATE_MBPS" 'returning to relay restores a per-flow default'
assert_eq 160 "$RTT_MS" 'returning to relay restores a cross-border RTT'
assert_eq 32 "$INITCWND" 'returning to relay restores initcwnd'
rm -rf "$cfg2"

# ── 二次审查发现的三个 bug，各配一条回归 ─────────────────────────────────

# 1. softnet_stat is hex, and strtonum() is gawk-only. On Debian's mawk the
#    old expression aborted and read 0, which then claimed "no local drops"
#    regardless of the truth. The replacement must parse hex on any awk.
softnet_fixture="$(mktemp)"
printf '00000001 0000002a 00000000 00000000\n0000000b 00000016 00000000 00000000\n' > "$softnet_fixture"
hex_sum="$(awk '
  function hex(x,   i, c, v, d) {
    v = 0; x = tolower(x)
    for (i = 1; i <= length(x); i++) {
      d = index("0123456789abcdef", substr(x, i, 1)) - 1
      if (d < 0) return v
      v = v * 16 + d
    }
    return v
  }
  {s += hex($2)} END {printf "%d\n", s}' "$softnet_fixture")"
# 0x2a = 42, 0x16 = 22 -> 64
assert_eq 64 "$hex_sum" 'softnet hex columns parse without gawk extensions'
# Comments may name it; code may not call it.
grep -v '^[[:space:]]*#' "$ROOT/netshape-manager.sh" | grep -q 'strtonum(' \
  && fail 'strtonum() is a gawk extension and must not be called'
pass 'no gawk-only builtins remain in the script'
rm -f "$softnet_fixture"

# 2. release_unmanaged_keys must never overwrite a value somebody else changed
#    after NetShape wrote it. Restoring the factory value there would quietly
#    undo the user's own tuning.
rel_dir="$(mktemp -d)"
_sf="$SYSCTL_FILE"; _snap="$SNAPSHOT_FILE"
SYSCTL_FILE="$rel_dir/ns.conf"; SNAPSHOT_FILE="$rel_dir/snap"
printf 'net.ipv4.tcp_fin_timeout = 15\nnet.ipv4.tcp_keepalive_time = 600\n' > "$SYSCTL_FILE"
printf '# PRISTINE=1\nnet.ipv4.tcp_fin_timeout=60\nnet.ipv4.tcp_keepalive_time=7200\n' > "$SNAPSHOT_FILE"
rel_log="$rel_dir/log"
has() { [[ "$1" == sysctl ]]; }
# keepalive still holds what we wrote (600); fin_timeout was changed to 30.
sysctl() {
  if [[ "$1" == -qw ]]; then printf '%s\n' "$2" >> "$rel_log"; return 0; fi
  if [[ "$1" == -n ]]; then
    case "$2" in
      net.ipv4.tcp_fin_timeout) printf '30\n' ;;
      net.ipv4.tcp_keepalive_time) printf '600\n' ;;
    esac
    return 0
  fi
}
: > "$rel_log"
release_unmanaged_keys "$LANDING_TUNED_KEYS" >/dev/null 2>&1
[[ "$(cat "$rel_log")" != *tcp_fin_timeout* ]] \
  || fail 'a key the user changed after us must not be restored'
pass 'a sysctl the user changed after us is left alone'
[[ "$(cat "$rel_log")" == *'net.ipv4.tcp_keepalive_time=7200'* ]] \
  || fail 'a key still holding our value should be restored'
pass 'a sysctl still holding our value is restored to the factory snapshot'
# Without a pristine snapshot nothing may be written at all.
printf '# PRISTINE=0\nnet.ipv4.tcp_fin_timeout=60\n' > "$SNAPSHOT_FILE"
: > "$rel_log"
release_unmanaged_keys "$LANDING_TUNED_KEYS" >/dev/null 2>&1
assert_eq '' "$(cat "$rel_log")" 'a non-pristine snapshot must not be replayed as defaults'
SYSCTL_FILE="$_sf"; SNAPSHOT_FILE="$_snap"
rm -rf "$rel_dir"

# 3. A config written by an older build carries INITCWND=32. An in-place
#    upgrade must land on the landing invariant rather than keep re-applying
#    an initial window to the default route forever.
mig_dir="$(mktemp -d)"
_cf="$CONFIG_FILE"; CONFIG_FILE="$mig_dir/conf"
printf 'ROLE=landing\nLIMIT_MODE=total\nRATE_MBPS=900\nINITCWND=32\n' > "$CONFIG_FILE"
load_config
assert_eq 0 "$INITCWND" 'an upgraded landing config is forced to initcwnd 0'
assert_eq 900 "$RATE_MBPS" 'an upgraded landing config keeps its explicit cap'
assert_eq total "$LIMIT_MODE" 'an upgraded landing config keeps its limit mode'
# Migration A: unlimited must stay unlimited, never guessed into a preset.
printf 'ROLE=landing\nLIMIT_MODE=adaptive\nRATE_MBPS=1000\nTOTAL_MBPS=0\n' > "$CONFIG_FILE"
load_config
assert_eq adaptive "$LIMIT_MODE" 'an unlimited landing config stays unlimited on upgrade'
assert_eq 1000 "$RATE_MBPS" 'an unlimited landing config is not rewritten to a preset'
# Migration C: relay is untouched by the landing invariant.
printf 'ROLE=relay\nINITCWND=32\nRATE_MBPS=430\n' > "$CONFIG_FILE"
load_config
assert_eq 32 "$INITCWND" 'relay keeps its initcwnd through the same code path'
assert_eq relay "$ROLE" 'relay role survives'
CONFIG_FILE="$_cf"
rm -rf "$mig_dir"

printf '%s\n' 'All self-tests passed.'
