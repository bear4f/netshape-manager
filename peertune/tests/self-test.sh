#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PEERTUNE_LIB_ONLY=1
# shellcheck source=../peertune.sh
. "$ROOT/peertune.sh"

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf 'FAIL: %s: expected [%s], got [%s]\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
  printf 'PASS: %s\n' "$label"
}

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# ── 拥塞控制优选 ───────────────────────────────────────────────────────────
assert_eq bbr3 "$(pick_congestion_control 'reno cubic bbr bbr2 bbr3')" 'prefers BBRv3'
assert_eq bbr2 "$(pick_congestion_control 'reno cubic bbr bbr2')" 'prefers BBRv2 over v1'
assert_eq bbr "$(pick_congestion_control 'reno cubic bbr')" 'falls back to plain bbr'
assert_eq cubic "$(pick_congestion_control 'reno cubic')" 'falls back to cubic'
# Substring must not match: "bbrplus" is a different algorithm.
assert_eq cubic "$(pick_congestion_control 'cubic bbrplus')" 'does not match bbr as a substring'
pick_congestion_control 'reno' >/dev/null 2>&1 && fail 'unknown-only list should fail' || pass 'reports failure when nothing usable'

# ── 缓冲上限 ───────────────────────────────────────────────────────────────
# 1 Gbps x 250ms x 2 = 62.5 MB, rounded up to whole MiB.
assert_eq 62914560 "$(calc_buffer_max 1000 250 4096)" '1G/250ms buffer on 4G RAM'
assert_eq '2 倍 BDP @ 250 ms' "$(buffer_reason 1000 250 4096)" 'reason is the BDP rule'
# Below 1 GB the tcp_mem budget (98304 pages / 8 = 48 MiB) binds first.
assert_eq 50331648 "$(calc_buffer_max 1000 250 512)" 'tcp_mem budget caps a small box'
assert_eq '受 512 MB 内存限制' "$(buffer_reason 1000 250 512)" 'reason names the RAM cap'
assert_eq 8388608 "$(calc_buffer_max 100 20 4096)" 'floor applies to tiny BDP'
assert_eq '下限 8 MiB' "$(buffer_reason 100 20 4096)" 'reason names the floor'
# The point of the whole design: a low coverage RTT is a hard ceiling.
low="$(calc_buffer_max 1000 40 4096)"
high="$(calc_buffer_max 1000 250 4096)"
(( high > low * 4 )) || fail 'coverage RTT should dominate the buffer size'
pass 'under-sizing coverage RTT costs more than 4x the ceiling'
for m in 512 1024 2048 4096 65536; do
  cap="$(calc_buffer_max 100000 3000 "$m")"
  budget="$(buffer_budget_cap "$m")"
  (( cap <= budget )) || fail "buffer $cap exceeds tcp_mem budget $budget at ${m}MB"
  (( cap <= 268435456 )) || fail "buffer $cap exceeds the 256 MiB ceiling at ${m}MB"
done
pass 'buffer never exceeds the tcp_mem budget or 256 MiB'

# ── 判定阈值 ───────────────────────────────────────────────────────────────
assert_eq '队列健康' "$(bloat_verdict 1.2)" 'low bloat'
assert_eq '有排队' "$(bloat_verdict 2.0)" 'moderate bloat'
assert_eq '排队膨胀' "$(bloat_verdict 4.5)" 'high bloat'
assert_eq '稳' "$(jitter_verdict 0.05)" 'low jitter'
assert_eq '抖' "$(jitter_verdict 0.2)" 'moderate jitter'
assert_eq '剧烈抖' "$(jitter_verdict 0.45)" 'high jitter'
assert_eq '干净' "$(retrans_verdict 0.01)" 'clean retrans'
assert_eq '偏高' "$(retrans_verdict 0.5)" 'elevated retrans'
assert_eq '丢包重' "$(retrans_verdict 2.0)" 'heavy retrans'

# The combination is what carries the diagnosis, so check the corners.
[[ "$(diagnose_peer 4.0 0.4 0.02)" == *"接入网排队膨胀"* ]] || fail 'bloat without loss = access-network queue'
pass 'bloat without loss is diagnosed as access-network queueing'
[[ "$(diagnose_peer 1.2 0.05 2.5)" == *"路径丢包或限速器"* ]] || fail 'loss without bloat = policer'
pass 'loss without bloat is diagnosed as a policer'
[[ "$(diagnose_peer 2.5 0.05 2.5)" == *"既排队又丢包"* ]] || fail 'both = punched through'
pass 'loss with bloat is diagnosed as punching through'
[[ "$(diagnose_peer 1.1 0.5 0.01)" == *"链路抖动大"* ]] || fail 'jitter alone = radio'
pass 'jitter alone is diagnosed as a wobbling radio link'
assert_eq '健康' "$(diagnose_peer 1.1 0.05 0.01)" 'clean peer is healthy'

# ── ss 解析 ────────────────────────────────────────────────────────────────
# Real `ss -tin` layout: a socket line, then an indented info line.
read -r -d '' SS_SAMPLE <<'EOF' || true
ESTAB 0 0 10.0.0.1:443 203.0.113.5:51234
	 bbr wscale:8,7 rto:236 rtt:35.5/2.25 ato:40 mss:1448 cwnd:120 bytes_acked:52428800 data_segs_out:35900 send 391Mbps lastsnd:4 pacing_rate 387Mbps delivery_rate 240.0Mbps retrans:0/125 minrtt:32.1
ESTAB 0 0 10.0.0.1:443 198.51.100.9:44321
	 cubic wscale:7,7 rto:1200 rtt:180.0/60.0 ato:40 mss:1448 cwnd:30 data_segs_out:9000 send 19.3Mbps pacing_rate 20Mbps delivery_rate 15.0Mbps retrans:2/900 minrtt:45.0
EOF
parsed="$(printf '%s\n' "$SS_SAMPLE" | ss_parse)"
assert_eq 2 "$(printf '%s\n' "$parsed" | wc -l | tr -d ' ')" 'parses both connections'
row1="$(printf '%s\n' "$parsed" | head -1)"
assert_eq '10.0.0.1:443|203.0.113.5:51234' "$(printf '%s' "$row1" | cut -f1)" 'connection key'
assert_eq '203.0.113.5' "$(printf '%s' "$row1" | cut -f2)" 'peer IP without port'
assert_eq 'bbr' "$(printf '%s' "$row1" | cut -f3)" 'congestion control name'
assert_eq '35.500' "$(printf '%s' "$row1" | cut -f4)" 'rtt'
assert_eq '2.250' "$(printf '%s' "$row1" | cut -f5)" 'rttvar'
assert_eq '32.100' "$(printf '%s' "$row1" | cut -f6)" 'minrtt'
assert_eq '125' "$(printf '%s' "$row1" | cut -f7)" 'retrans takes the cumulative half'
assert_eq '35900' "$(printf '%s' "$row1" | cut -f8)" 'data_segs_out'
assert_eq '240.000' "$(printf '%s' "$row1" | cut -f9)" 'delivery_rate in Mbps'
assert_eq '120' "$(printf '%s' "$row1" | cut -f10)" 'cwnd'

# ss drops the State column when a state filter is used; both must work.
noshape="$(printf '0 0 10.0.0.1:443 203.0.113.5:51234\n\t bbr rtt:20.0/1.0 data_segs_out:100 retrans:0/1 minrtt:19.0\n' | ss_parse)"
assert_eq '203.0.113.5' "$(printf '%s' "$noshape" | cut -f2)" 'parses the stateless layout too'

# Units other than Mbps have to be normalised or fast peers look idle.
units="$(printf 'ESTAB 0 0 10.0.0.1:443 1.1.1.1:1\n\t bbr rtt:10.0/1.0 data_segs_out:10 retrans:0/0 delivery_rate 2.5Gbps minrtt:9.0\n' | ss_parse)"
assert_eq '2500.000' "$(printf '%s' "$units" | cut -f9)" 'Gbps normalised to Mbps'
units="$(printf 'ESTAB 0 0 10.0.0.1:443 1.1.1.1:1\n\t bbr rtt:10.0/1.0 data_segs_out:10 retrans:0/0 delivery_rate 800Kbps minrtt:9.0\n' | ss_parse)"
assert_eq '0.800' "$(printf '%s' "$units" | cut -f9)" 'Kbps normalised to Mbps'

# IPv6 peers are bracketed and full of colons; the port strip must not eat them.
v6="$(printf 'ESTAB 0 0 [2001:db8::1]:443 [2001:db8:abcd:1::5]:9999\n\t bbr rtt:12.0/1.0 data_segs_out:50 retrans:0/0 minrtt:11.0\n' | ss_parse)"
assert_eq '2001:db8:abcd:1::5' "$(printf '%s' "$v6" | cut -f2)" 'IPv6 peer keeps its colons'

# Sockets with no RTT yet or nothing sent carry no signal and must be dropped,
# otherwise they drag every average toward zero.
empty="$(printf 'ESTAB 0 0 10.0.0.1:443 1.1.1.1:1\n\t bbr data_segs_out:0 retrans:0/0\n' | ss_parse || true)"
assert_eq '' "$empty" 'idle socket with no rtt is skipped'
empty="$(printf 'ESTAB 0 0 10.0.0.1:443 1.1.1.1:1\n\t bbr rtt:10.0/1.0 data_segs_out:0 retrans:0/0 minrtt:9.0\n' | ss_parse || true)"
assert_eq '' "$empty" 'socket that never sent is skipped'

# ── 聚合 ───────────────────────────────────────────────────────────────────
# Two samples of one connection: retransmissions must come out as the delta
# (150-100=50 over 11000-10000=1000 segs = 5%), not the lifetime 150/11000.
agg_in="$(printf 'k1\t203.0.113.5\tbbr\t100.0\t10.0\t50.0\t100\t10000\t20.0\t40\nk1\t203.0.113.5\tbbr\t200.0\t30.0\t50.0\t150\t11000\t10.0\t40\n')"
agg="$(printf '%s' "$agg_in" | awk -v mode=ip "$AGGREGATE_AWK")"
assert_eq '203.0.113.5' "$(printf '%s' "$agg" | cut -f1)" 'aggregates under the peer IP'
assert_eq '1' "$(printf '%s' "$agg" | cut -f2)" 'counts one connection, not one per sample'
assert_eq '5.0000' "$(printf '%s' "$agg" | cut -f9)" 'retransmissions are a window delta'
assert_eq '50.0' "$(printf '%s' "$agg" | cut -f6)" 'keeps the lowest minrtt'
# p50 of {100,200} at index int(0.5*2+0.5)=1 -> 100; bloat = 100/50 = 2.
assert_eq '2.00' "$(printf '%s' "$agg" | cut -f8)" 'bloat is rtt p50 over the path floor'

# /24 grouping folds one person's several devices into one row.
net_in="$(printf 'k1\t203.0.113.5\tbbr\t100.0\t10.0\t50.0\t0\t1000\t20.0\t40\nk2\t203.0.113.77\tbbr\t120.0\t10.0\t60.0\t0\t1000\t20.0\t40\n')"
net_agg="$(printf '%s' "$net_in" | awk -v mode=net "$AGGREGATE_AWK")"
assert_eq 1 "$(printf '%s\n' "$net_agg" | wc -l | tr -d ' ')" 'the /24 collapses to one row'
assert_eq '203.0.113.0/24' "$(printf '%s' "$net_agg" | cut -f1)" 'group is named as a /24'
assert_eq '2' "$(printf '%s' "$net_agg" | cut -f2)" 'both connections counted in the group'
ip_agg="$(printf '%s' "$net_in" | awk -v mode=ip "$AGGREGATE_AWK")"
assert_eq 2 "$(printf '%s\n' "$ip_agg" | wc -l | tr -d ' ')" 'per-IP grouping keeps them apart'
v6_agg="$(printf 'k1\t2001:db8:abcd:1::5\tbbr\t100.0\t10.0\t50.0\t0\t1000\t20.0\t40\n' | awk -v mode=net "$AGGREGATE_AWK")"
assert_eq '2001:db8:abcd:1::/64' "$(printf '%s' "$v6_agg" | cut -f1)" 'IPv6 groups to a /64'

# A connection idle across the whole window still reports its lifetime rate
# rather than dividing by zero.
idle_agg="$(printf 'k1\t1.1.1.1\tbbr\t10.0\t1.0\t9.0\t5\t1000\t1.0\t10\nk1\t1.1.1.1\tbbr\t10.0\t1.0\t9.0\t5\t1000\t1.0\t10\n' | awk -v mode=ip "$AGGREGATE_AWK")"
assert_eq '0.5000' "$(printf '%s' "$idle_agg" | cut -f9)" 'idle connection falls back to lifetime rate'

# ── 配置 ───────────────────────────────────────────────────────────────────
cfg="$(mktemp -d)"
printf 'COVERAGE_RTT_MS=300\nPORT_MBPS=2500\nQDISC_MODE=evil\n' > "$cfg/conf"
CONFIG_FILE="$cfg/conf" load_config
assert_eq 300 "$COVERAGE_RTT_MS" 'valid coverage RTT loads'
assert_eq 2500 "$PORT_MBPS" 'valid port speed loads'
assert_eq auto "$QDISC_MODE" 'rejected qdisc mode falls back to the default'
printf 'COVERAGE_RTT_MS=5\n' > "$cfg/conf"
CONFIG_FILE="$cfg/conf" load_config
assert_eq 250 "$COVERAGE_RTT_MS" 'out-of-range coverage RTT falls back'
rm -rf "$cfg"

# ── 与 netshape 的冲突检测 ─────────────────────────────────────────────────
NETSHAPE_CONFIG="$(mktemp)"
netshape_conflict && pass 'detects an installed netshape' || fail 'should detect netshape config'
rm -f "$NETSHAPE_CONFIG"
NETSHAPE_CONFIG=/nonexistent/a; NETSHAPE_SYSCTL=/nonexistent/b
has() { return 1; }
netshape_conflict && fail 'should not report a conflict on a clean box' || pass 'no conflict on a clean box'

printf '%s\n' 'All peertune self-tests passed.'
