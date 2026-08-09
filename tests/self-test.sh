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
applied_keys="$(grep -oE 'append_sysctl "\$temp" [a-z]+(\.[a-z0-9_]+)+' "$ROOT/netshape-manager.sh" \
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
CONFIG_FILE="$cfg_dir/conf" load_config
assert_eq policer "$BURST_MODE" 'bad BURST_MODE falls back to the default'
assert_eq 430 "$RATE_MBPS" 'valid keys still load alongside a rejected one'
printf 'INITCWND=9999\n' > "$cfg_dir/conf"
CONFIG_FILE="$cfg_dir/conf" load_config
assert_eq 32 "$INITCWND" 'out-of-range INITCWND falls back to the default'
rm -rf "$cfg_dir"

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

printf '%s\n' 'All self-tests passed.'
