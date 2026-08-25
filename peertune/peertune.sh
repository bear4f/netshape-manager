#!/usr/bin/env bash
# peertune - per-peer TCP visibility and population-safe tuning for Linux relays.
#
# netshape-manager assumes one client with a fixed capacity behind a fixed RTT,
# which is what makes "one per-flow cap + one RTT" the right model there.
# peertune assumes the opposite: a population of clients whose capacity and
# latency both move (5G, several regions, evening congestion). You cannot tune
# a distribution by picking a point out of it, so this tool does two things
# instead: it shows you the distribution per peer, and it sets global bounds
# that are safe for every member of it.
#
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="0.1.0"
PROGRAM="peertune"
INSTALL_FILE="/usr/local/sbin/peertune"
CLI_FILE="/usr/local/bin/peertune"
CONFIG_FILE="/etc/peertune.conf"
SYSCTL_FILE="/etc/sysctl.d/99-zz-peertune.conf"
SERVICE_FILE="/etc/systemd/system/peertune.service"
STATE_DIR="/var/lib/peertune"
SNAPSHOT_FILE="$STATE_DIR/pre-tune.snapshot"
LOCK_FILE="$STATE_DIR/lock"

NETSHAPE_CONFIG="/etc/netshape-manager.conf"
NETSHAPE_SYSCTL="/etc/sysctl.d/99-zz-netshape-manager.conf"
NETSHAPE_SERVICE="netshape-manager.service"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

if [[ ! -t 1 || "${NO_COLOR:-}" ]]; then
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' DIM='' BOLD='' RESET=''
fi

RULE_HEAVY='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
RULE_LIGHT='──────────────────────────────────────────────────────────────────────'

rule_heavy() { printf '%b%s%b\n' "$CYAN" "$RULE_HEAVY" "$RESET"; }
rule_light() { printf '%b%s%b\n' "$DIM" "$RULE_LIGHT" "$RESET"; }

panel_title() {
  printf '\n'
  rule_heavy
  printf '%b  %s%b  %bv%s%b\n' "$BOLD" "$1" "$RESET" "$DIM" "$VERSION" "$RESET"
  rule_heavy
}

log()  { printf '%b[OK]%b %s\n' "$GREEN" "$RESET" "$*"; }
info() { printf '%b[INFO]%b %s\n' "$BLUE" "$RESET" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%b[ERROR]%b %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

has() { command -v "$1" >/dev/null 2>&1; }
is_uint() { [[ ${1:-} =~ ^[0-9]+$ ]]; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行：sudo $PROGRAM $*"; }

PEERTUNE_LOCKED=0
take_lock() {
  (( PEERTUNE_LOCKED == 1 )) && return 0
  has flock || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  exec 9>"$LOCK_FILE" 2>/dev/null || return 0
  flock -w 10 9 || die "另一个 peertune 进程正在修改配置，请稍后重试"
  PEERTUNE_LOCKED=1
}

# ── 配置 ───────────────────────────────────────────────────────────────────

default_config() {
  # Never a measured number. See coverage_note() for why.
  COVERAGE_RTT_MS=250
  PORT_MBPS=1000
  TOTAL_MBPS=0
  IFACE="auto"
  QDISC_MODE="auto"
  SAMPLES=4
  INTERVAL_S=3
  GROUP_BY="ip"
}

load_config() {
  default_config
  [[ -r "$CONFIG_FILE" ]] || return 0
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      COVERAGE_RTT_MS) is_uint "$value" && (( value >= 20 && value <= 3000 )) && COVERAGE_RTT_MS="$value" ;;
      PORT_MBPS) is_uint "$value" && (( value >= 10 && value <= 100000 )) && PORT_MBPS="$value" ;;
      TOTAL_MBPS) is_uint "$value" && (( value == 0 || (value >= 10 && value <= 100000) )) && TOTAL_MBPS="$value" ;;
      IFACE) [[ "$value" =~ ^[a-zA-Z0-9_.:-]+$ ]] && IFACE="$value" ;;
      QDISC_MODE) [[ "$value" =~ ^(auto|cake|fq_codel|fq)$ ]] && QDISC_MODE="$value" ;;
      SAMPLES) is_uint "$value" && (( value >= 2 && value <= 60 )) && SAMPLES="$value" ;;
      INTERVAL_S) is_uint "$value" && (( value >= 1 && value <= 60 )) && INTERVAL_S="$value" ;;
      GROUP_BY) [[ "$value" =~ ^(ip|net)$ ]] && GROUP_BY="$value" ;;
    esac
  done < "$CONFIG_FILE"
  # A rejected value on the final line must not take the caller down.
  return 0
}

save_config() {
  local temp
  mkdir -p "$(dirname "$CONFIG_FILE")"
  temp="$(mktemp "${CONFIG_FILE}.XXXXXX")"
  chmod 0644 "$temp"
  {
    printf '# peertune persistent configuration\n'
    printf 'COVERAGE_RTT_MS=%s\n' "$COVERAGE_RTT_MS"
    printf 'PORT_MBPS=%s\n' "$PORT_MBPS"
    printf 'TOTAL_MBPS=%s\n' "$TOTAL_MBPS"
    printf 'IFACE=%s\n' "$IFACE"
    printf 'QDISC_MODE=%s\n' "$QDISC_MODE"
    printf 'SAMPLES=%s\n' "$SAMPLES"
    printf 'INTERVAL_S=%s\n' "$INTERVAL_S"
    printf 'GROUP_BY=%s\n' "$GROUP_BY"
  } > "$temp"
  mv -f "$temp" "$CONFIG_FILE"
}

# ── 环境探测 ───────────────────────────────────────────────────────────────

detect_iface() {
  local iface=''
  if has ip; then
    iface="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
    [[ -n "$iface" ]] || iface="$(ip -o -6 route show to default 2>/dev/null | awk '{print $5; exit}')"
  fi
  printf '%s\n' "$iface"
}

resolve_iface() {
  local resolved="${IFACE:-auto}"
  [[ "$resolved" == auto ]] && resolved="$(detect_iface)"
  [[ -n "$resolved" ]] || die "未找到默认出口网卡；可在 $CONFIG_FILE 中设置 IFACE"
  [[ -d "/sys/class/net/$resolved" ]] || die "网卡不存在：$resolved"
  printf '%s\n' "$resolved"
}

mem_total_mb() {
  awk '/^MemTotal:/ {printf "%d\n", $2 / 1024; found=1} END {if (!found) print 0}' /proc/meminfo 2>/dev/null || printf '0\n'
}

format_mb() { awk -v b="${1:-0}" 'BEGIN {printf "%.0f MiB\n", b / 1048576}'; }

# ── 拥塞控制 ───────────────────────────────────────────────────────────────

# BBRv1's bandwidth estimate is a max-filter over roughly ten round trips, so
# when a radio link degrades it keeps sending at the old estimate for whole
# seconds. v2 and v3 react to loss and ECN and are far gentler on exactly the
# links this tool is aimed at, so prefer them whenever the kernel offers them.
# Note that XanMod ships BBRv3 under the plain name "bbr", which is why
# running_cc_note() reports what is actually active rather than assuming.
pick_congestion_control() {
  local available=" ${1:-} " candidate
  for candidate in bbr3 bbr2 bbr; do
    [[ "$available" == *" $candidate "* ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  [[ "$available" == *" cubic "* ]] && { printf 'cubic\n'; return 0; }
  printf '\n'
  return 1
}

available_cc() {
  [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]] || return 0
  tr -d '\n' < /proc/sys/net/ipv4/tcp_available_congestion_control
}

cc_note() {
  case "${1:-}" in
    bbr3) printf 'BBRv3，对无线/抖动链路最友好\n' ;;
    bbr2) printf 'BBRv2，会响应丢包与 ECN\n' ;;
    bbr) printf 'BBR（内核未区分版本；XanMod 等把 v3 也叫 bbr，实际版本见 doctor）\n' ;;
    cubic) printf 'Cubic，内核没有 BBR 时的回退\n' ;;
    *) printf '未知\n' ;;
  esac
}

# ── 缓冲上限 ───────────────────────────────────────────────────────────────

# The socket buffer ceiling is also an in-flight ceiling, so it has to cover
# the farthest client you serve. Sizing it from a measured RTT is the trap:
# a measurement is one random point out of a distribution that spans 2-3x
# across carriers and doubles again at peak hours. The costs are asymmetric —
# over-sizing costs some BBR overshoot on the worst path, under-sizing is a
# hard ceiling nobody can see or diagnose. So this is a coverage figure, not
# a measurement, and it is deliberately generous.
coverage_note() {
  local rtt="${1:-250}"
  printf '覆盖 RTT %s ms —— 这是覆盖值不是实测值：\n' "$rtt"
  printf '  优化线 40-70ms｜香港 ~145ms｜美西 160-180ms｜欧美 230-250ms｜晚高峰 300ms+\n'
  printf '  估高只多付一点 BBR 超发；估低是查不出来的硬天花板。\n'
}

# Cap one socket at an eighth of the global TCP budget so eight large flows
# still fit, and never past 256 MiB.
buffer_budget_cap() {
  local mem="${1:-1024}" pages
  pages="$(tcp_mem_values "$mem" | awk '{print $3}')"
  printf '%s\n' $(( pages * 4096 / 8 ))
}

tcp_mem_values() {
  local mem="${1:-1024}"
  if (( mem < 1024 )); then
    printf '32768 49152 98304\n'
  elif (( mem < 4096 )); then
    printf '65536 98304 196608\n'
  else
    printf '131072 196608 393216\n'
  fi
}

calc_buffer_max() {
  local rate="${1:-1000}" rtt="${2:-250}" mem="${3:-1024}" target cap
  target=$(( rate * rtt * 125 * 2 ))
  (( target < 8388608 )) && target=8388608
  target=$(( (target + 1048575) / 1048576 * 1048576 ))
  cap="$(buffer_budget_cap "$mem")"
  (( cap > 268435456 )) && cap=268435456
  (( target > cap )) && target="$cap"
  printf '%s\n' "$target"
}

buffer_reason() {
  local rate="${1:-1000}" rtt="${2:-250}" mem="${3:-1024}" target cap
  target=$(( rate * rtt * 125 * 2 ))
  cap="$(buffer_budget_cap "$mem")"
  (( cap > 268435456 )) && cap=268435456
  if (( target < 8388608 )); then
    printf '下限 8 MiB\n'
  elif (( target > cap )); then
    printf '受 %s MB 内存限制\n' "$mem"
  else
    printf '2 倍 BDP @ %s ms\n' "$rtt"
  fi
}

# ── 每客户端观测 ───────────────────────────────────────────────────────────

# Normalises `ss -tin` into one row per connection per sample:
#   key  peer  cc  rtt  rttvar  minrtt  retrans  data_segs_out  mbps  cwnd
# `ss` prints a socket line followed by an indented info line, and drops the
# State column when a state filter is used, so both layouts are handled.
SS_PARSE_AWK='
function tomb(v,   n) {
  n = v + 0
  if (v ~ /Gbps/) return n * 1000
  if (v ~ /Mbps/) return n
  if (v ~ /Kbps/) return n / 1000
  return n / 1000000
}
function ipof(a,   i) {
  if (substr(a, 1, 1) == "[") { i = index(a, "]"); return (i > 2) ? substr(a, 2, i - 2) : a }
  i = length(a)
  while (i > 0 && substr(a, i, 1) != ":") i--
  return (i > 1) ? substr(a, 1, i - 1) : a
}
/^[ \t]/ {
  if (peer == "") next
  cc = $1; rtt = ""; rttvar = ""; minrtt = ""; retr = 0; dsegs = 0; cwnd = 0; mbps = 0
  for (i = 1; i <= NF; i++) {
    f = $i
    if (f ~ /^rtt:/) {
      s = substr(f, 5); p = index(s, "/")
      if (p > 0) { rtt = substr(s, 1, p - 1) + 0; rttvar = substr(s, p + 1) + 0 }
      else rtt = s + 0
    }
    else if (f ~ /^minrtt:/) minrtt = substr(f, 8) + 0
    else if (f ~ /^retrans:/) { s = substr(f, 9); p = index(s, "/"); retr = ((p > 0) ? substr(s, p + 1) : s) + 0 }
    else if (f ~ /^data_segs_out:/) dsegs = substr(f, 15) + 0
    else if (f ~ /^cwnd:/) cwnd = substr(f, 6) + 0
    else if (f == "delivery_rate" && i < NF) mbps = tomb($(i + 1))
  }
  # No RTT estimate yet, or nothing ever sent: nothing to say about this one.
  if (rtt == "" || rtt <= 0 || dsegs <= 0) { peer = ""; next }
  if (minrtt == "" || minrtt <= 0) minrtt = rtt
  if (rttvar == "") rttvar = 0
  printf "%s\t%s\t%s\t%.3f\t%.3f\t%.3f\t%d\t%d\t%.3f\t%d\n", \
    local "|" peer, ipof(peer), cc, rtt, rttvar, minrtt, retr, dsegs, mbps, cwnd
  peer = ""
  next
}
{
  peer = ""
  if (NF >= 5 && $1 ~ /^[A-Z][A-Z0-9_-]*$/) { local = $4; peer = $5 }
  else if (NF >= 4) { local = $3; peer = $4 }
}
'

ss_parse() { awk "$SS_PARSE_AWK"; }

# Aggregates the sample rows into one line per peer. Retransmissions are a
# delta between the first and last sighting of each connection, not a lifetime
# average: a connection that had a bad minute an hour ago is not having one now.
AGGREGATE_AWK='
function sortarr(a, n,   i, j, t) {
  for (i = 2; i <= n; i++) { t = a[i]; j = i - 1
    while (j > 0 && a[j] > t) { a[j + 1] = a[j]; j-- }
    a[j + 1] = t }
}
function at(a, n, q,   idx) {
  idx = int(q * n + 0.5); if (idx < 1) idx = 1; if (idx > n) idx = n
  return a[idx]
}
function groupof(ip,   i, c, out) {
  if (mode != "net") return ip
  if (index(ip, ":") > 0) {                       # IPv6: keep the first four groups
    c = 0
    for (i = 1; i <= length(ip); i++) {
      if (substr(ip, i, 1) == ":") c++
      if (c == 4) return substr(ip, 1, i - 1) "::/64"
    }
    return ip
  }
  c = 0                                            # IPv4: /24
  for (i = length(ip); i > 0; i--) if (substr(ip, i, 1) == ".") { return substr(ip, 1, i - 1) ".0/24" }
  return ip
}
{
  key = $1; g = groupof($2); cc = $3
  rtt = $4 + 0; rttvar = $5 + 0; minrtt = $6 + 0
  retr = $7 + 0; dsegs = $8 + 0; mbps = $9 + 0; cwnd = $10 + 0
  if (!(key in firstseen)) { firstseen[key] = 1; fretr[key] = retr; fsegs[key] = dsegs; kgroup[key] = g }
  lretr[key] = retr; lsegs[key] = dsegs
  n = ++cnt[g]
  rtts[g, n] = rtt
  rates[g, n] = mbps
  vsum[g] += rttvar
  if (!(g in gmin) || minrtt < gmin[g]) gmin[g] = minrtt
  if (cwnd > gcwnd[g]) gcwnd[g] = cwnd
  ccname[g] = cc
}
END {
  for (key in firstseen) {
    g = kgroup[key]
    conns[g]++
    dr = lretr[key] - fretr[key]; ds = lsegs[key] - fsegs[key]
    # Fall back to the connection lifetime when it produced no traffic during
    # the window; labelled the same way because it is still that peer rate.
    if (ds <= 0) { dr = lretr[key]; ds = lsegs[key] }
    if (ds > 0) { sumretr[g] += dr; sumsegs[g] += ds }
  }
  for (g in cnt) {
    n = cnt[g]
    for (i = 1; i <= n; i++) { r[i] = rtts[g, i]; m[i] = rates[g, i] }
    sortarr(r, n); sortarr(m, n)
    p50 = at(r, n, 0.50); p95 = at(r, n, 0.95)
    jit = (p50 > 0) ? (vsum[g] / n) / p50 : 0
    bloat = (gmin[g] > 0) ? p50 / gmin[g] : 1
    rpct = (sumsegs[g] > 0) ? sumretr[g] * 100 / sumsegs[g] : 0
    printf "%s\t%d\t%s\t%.1f\t%.1f\t%.1f\t%.3f\t%.2f\t%.4f\t%.1f\t%d\n", \
      g, conns[g], ccname[g], p50, p95, gmin[g], jit, bloat, rpct, at(m, n, 0.50), gcwnd[g]
  }
}
'

# ── 判定 ───────────────────────────────────────────────────────────────────

# rtt / minrtt is how many times the path's own floor the queue has grown to.
# It is the cleanest available signal for a bufferbloated access network,
# which is what a 5G downlink almost always is.
bloat_verdict() {
  awk -v b="${1:-1}" 'BEGIN {
    if (b < 1.5) print "队列健康";
    else if (b < 3) print "有排队";
    else print "排队膨胀";
  }'
}

# rttvar / rtt. A radio link that is scheduling around you shows up here long
# before it shows up in throughput.
jitter_verdict() {
  awk -v j="${1:-0}" 'BEGIN {
    if (j < 0.1) print "稳";
    else if (j < 0.3) print "抖";
    else print "剧烈抖";
  }'
}

# Same thresholds as netshape: across seven real hosts the clean side topped
# out at 0.0017% and the lowest reading from a policed path was 1.354%.
retrans_verdict() {
  awk -v p="${1:-0}" 'BEGIN {
    if (p < 0.1) print "干净";
    else if (p < 1) print "偏高";
    else print "丢包重";
  }'
}

# The whole point of collecting three independent signals is that their
# combination says something none of them says alone.
diagnose_peer() {
  local bloat="${1:-1}" jitter="${2:-0}" retrans="${3:-0}"
  awk -v b="$bloat" -v j="$jitter" -v r="$retrans" 'BEGIN {
    if (b >= 3 && r < 1) {
      print "接入网排队膨胀（典型 5G/家宽上行）——瓶颈队列不在你的服务器上，服务端限速无效，靠 BBRv3 或降 pacing";
      exit
    }
    if (r >= 1 && b < 2) { print "路径丢包或限速器——重传高但没有排队，降单流速率有用"; exit }
    if (r >= 1 && b >= 2) { print "既排队又丢包——多半打穿了限速器，优先降速率"; exit }
    if (j >= 0.3) { print "链路抖动大（无线调度/换手）——速率波动来自这里，不是你的配置"; exit }
    if (b >= 1.5) { print "轻微排队，可接受"; exit }
    print "健康";
  }'
}

collect_samples() {
  local samples="$1" interval="$2" out="$3" i
  : > "$out"
  for (( i = 1; i <= samples; i++ )); do
    ss -tinH 2>/dev/null | ss_parse >> "$out" || true
    if (( i < samples )); then sleep "$interval"; fi
  done
  # Without this the loop leaks the last guard's status and errexit kills us.
  return 0
}

cmd_scan() {
  load_config
  local samples="$SAMPLES" interval="$INTERVAL_S" group="$GROUP_BY" min_conn=1 raw agg
  while (( $# )); do
    case "$1" in
      --samples) [[ $# -ge 2 ]] || die "--samples 缺少值"; samples="$2"; shift 2 ;;
      --interval) [[ $# -ge 2 ]] || die "--interval 缺少值"; interval="$2"; shift 2 ;;
      --group) [[ $# -ge 2 ]] || die "--group 缺少值"; group="$2"; shift 2 ;;
      --min-conn) [[ $# -ge 2 ]] || die "--min-conn 缺少值"; min_conn="$2"; shift 2 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  is_uint "$samples" && (( samples >= 2 && samples <= 60 )) || die "--samples 需为 2-60"
  is_uint "$interval" && (( interval >= 1 && interval <= 60 )) || die "--interval 需为 1-60"
  is_uint "$min_conn" && (( min_conn >= 1 )) || die "--min-conn 需为正整数"
  [[ "$group" =~ ^(ip|net)$ ]] || die "--group 只能是 ip 或 net"
  has ss || die "缺少 ss；请安装 iproute2"

  panel_title 'peertune 客户端分布'
  info "采样 ${samples} 次 × ${interval}s，按 $( [[ "$group" == net ]] && printf '网段' || printf 'IP' )聚合…"
  raw="$(mktemp)"; agg="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$raw' '$agg'" RETURN
  collect_samples "$samples" "$interval" "$raw"
  if [[ ! -s "$raw" ]]; then
    warn "采样窗口内没有任何活跃 TCP 连接（有流量时再测）"
    return 0
  fi
  awk -v mode="$group" "$AGGREGATE_AWK" "$raw" | sort -t"$(printf '\t')" -k8,8gr > "$agg"

  printf '\n'
  # Hand-spaced: printf pads by character count, and every CJK header cell is
  # two display columns wide, so %-24s and friends would not line up with the
  # ASCII data rows below.
  printf '  %b客户端                  连接  RTT50  RTT95   最低   抖动   膨胀    重传%%%b\n' "$BOLD" "$RESET"
  rule_light
  local peer conns cc p50 p95 minrtt jit bloat rpct mbps cwnd shown=0 unhealthy=0
  while IFS=$'\t' read -r peer conns cc p50 p95 minrtt jit bloat rpct mbps cwnd; do
    (( conns >= min_conn )) || continue
    shown=$((shown + 1))
    local color="$GREEN"
    if awk -v b="$bloat" -v r="$rpct" -v j="$jit" \
      'BEGIN {exit !(b >= 3 || r >= 1 || j >= 0.3)}'; then
      color="$YELLOW"; unhealthy=$((unhealthy + 1))
    fi
    printf '  %b%-24s%b %4s %6s %6s %6s %6s %6s %8s\n' \
      "$color" "$peer" "$RESET" "$conns" "$p50" "$p95" "$minrtt" "$jit" "$bloat" "$rpct"
    printf '    %b%s ｜ %s ｜ %s ｜ %s ｜ 中位 %s Mbps ｜ cwnd %s%b\n' "$DIM" \
      "$(bloat_verdict "$bloat")" "$(jitter_verdict "$jit")" "$(retrans_verdict "$rpct")" \
      "$cc" "$mbps" "$cwnd" "$RESET"
    printf '    %b→ %s%b\n' "$DIM" "$(diagnose_peer "$bloat" "$jit" "$rpct")" "$RESET"
  done < "$agg"
  rule_light
  if (( shown == 0 )); then
    warn "没有满足 --min-conn ${min_conn} 的客户端"
    return 0
  fi
  if (( unhealthy > 0 )); then
    printf '  %b%s/%s 个客户端有问题（黄色那几行）。这是一个分布，不是一个数——%b\n' \
      "$BOLD" "$unhealthy" "$shown" "$RESET"
    printf '  %b给所有人套同一个单流限速，只会让健康的那批变慢，对卡的那批毫无作用。%b\n' "$DIM" "$RESET"
  else
    printf '  %b%s 个客户端全部健康。%b\n' "$GREEN" "$shown" "$RESET"
  fi
  printf '  %b膨胀 = RTT50 / 该路径最低 RTT，>3 说明对端接入网在囤队列%b\n' "$DIM" "$RESET"
  printf '  %b抖动 = rttvar / RTT50，>0.3 是无线链路的典型特征%b\n' "$DIM" "$RESET"
  printf '  %b重传%% 取采样窗口内的增量，不是连接生命周期的平均值%b\n' "$DIM" "$RESET"
}

# ── 调优 ───────────────────────────────────────────────────────────────────

TUNED_KEYS='
net.core.default_qdisc
net.ipv4.tcp_congestion_control
net.core.rmem_max
net.core.wmem_max
net.core.rmem_default
net.core.wmem_default
net.ipv4.tcp_rmem
net.ipv4.tcp_wmem
net.ipv4.tcp_mem
net.ipv4.tcp_moderate_rcvbuf
net.ipv4.tcp_window_scaling
net.ipv4.tcp_adv_win_scale
net.ipv4.tcp_notsent_lowat
net.ipv4.tcp_sack
net.ipv4.tcp_dsack
net.ipv4.tcp_timestamps
net.ipv4.tcp_mtu_probing
net.ipv4.tcp_slow_start_after_idle
net.ipv4.tcp_no_metrics_save
net.ipv4.tcp_ecn
net.ipv4.tcp_frto
net.core.netdev_max_backlog
net.core.somaxconn
net.ipv4.tcp_max_syn_backlog
net.ipv4.tcp_tw_reuse
net.ipv4.tcp_fin_timeout
'

sysctl_path() { printf '/proc/sys/%s\n' "$(printf '%s' "$1" | tr '.' '/')"; }

append_sysctl() {
  local file="$1" key="$2" value="$3"
  if [[ -e "$(sysctl_path "$key")" ]]; then
    printf '%s = %s\n' "$key" "$value" >> "$file"
  else
    warn "当前内核不支持 ${key}，已跳过"
  fi
}

take_snapshot() {
  local key value
  [[ -e "$SNAPSHOT_FILE" ]] && return 0
  mkdir -p "$STATE_DIR"
  {
    printf '# peertune pre-tune snapshot %s\n' "$(date -u +%FT%TZ 2>/dev/null || printf 'unknown')"
    printf '# KERNEL=%s\n' "$(uname -r 2>/dev/null || printf 'unknown')"
    for key in $TUNED_KEYS; do
      [[ -e "$(sysctl_path "$key")" ]] || continue
      value="$(sysctl -n "$key" 2>/dev/null)" || continue
      [[ -n "$value" ]] || continue
      printf '%s=%s\n' "$key" "$value"
    done
  } > "$SNAPSHOT_FILE"
  chmod 0644 "$SNAPSHOT_FILE"
  log "已保存出厂快照：$SNAPSHOT_FILE"
}

restore_snapshot() {
  local key value restored=0
  [[ -r "$SNAPSHOT_FILE" ]] || { warn "找不到快照，已调优的内核参数会保留到下次重启"; return 0; }
  while IFS='=' read -r key value; do
    [[ "$key" == \#* || -z "$key" || -z "$value" ]] && continue
    sysctl -qw "$key=$value" >/dev/null 2>&1 && restored=$((restored + 1))
  done < "$SNAPSHOT_FILE"
  log "已按快照还原 ${restored} 项内核参数"
}

# peertune and netshape both own the root qdisc and a sysctl drop-in. Running
# both means whichever ran last wins, silently, and the user cannot tell which
# settings are live. Refuse rather than fight over it.
netshape_conflict() {
  local found=0
  [[ -e "$NETSHAPE_CONFIG" || -e "$NETSHAPE_SYSCTL" ]] && found=1
  has systemctl && systemctl is-enabled "$NETSHAPE_SERVICE" >/dev/null 2>&1 && found=1
  (( found == 1 ))
}

require_no_netshape() {
  netshape_conflict || return 0
  warn "检测到本机装有 netshape-manager。"
  warn "两者都会接管 root qdisc 和 sysctl，同时装等于谁最后跑谁生效，且看不出来。"
  printf '\n  先卸载它，再回来跑 peertune：\n'
  printf '    %bsudo netshape uninstall%b\n\n' "$BOLD" "$RESET"
  printf '  netshape 的卸载会按快照还原内核参数，不会留下半套配置。\n'
  die "已中止，未做任何改动"
}

write_sysctl_profile() {
  local mem bufmax cc avail temp notsent
  mem="$(mem_total_mb)"; (( mem > 0 )) || mem=1024
  bufmax="$(calc_buffer_max "$PORT_MBPS" "$COVERAGE_RTT_MS" "$mem")"
  avail="$(available_cc)"
  has modprobe && modprobe tcp_bbr >/dev/null 2>&1 || true
  avail="$(available_cc)"
  cc="$(pick_congestion_control "$avail")" || die "内核没有可用的拥塞控制算法"
  # Keep unsent data in the socket short so a capacity drop does not leave
  # megabytes queued that must drain before the app can react to a seek.
  notsent=16384

  mkdir -p "$(dirname "$SYSCTL_FILE")" "$STATE_DIR"
  temp="$(mktemp "${SYSCTL_FILE}.XXXXXX")"
  {
    printf '# Generated by peertune %s - do not hand edit.\n' "$VERSION"
    printf '# coverage-RTT=%sms port=%sMbps RAM=%sMB\n\n' "$COVERAGE_RTT_MS" "$PORT_MBPS" "$mem"
  } > "$temp"

  append_sysctl "$temp" net.core.default_qdisc fq
  append_sysctl "$temp" net.ipv4.tcp_congestion_control "$cc"
  append_sysctl "$temp" net.core.rmem_default 262144
  append_sysctl "$temp" net.core.wmem_default 262144
  append_sysctl "$temp" net.core.rmem_max "$bufmax"
  append_sysctl "$temp" net.core.wmem_max "$bufmax"
  append_sysctl "$temp" net.ipv4.tcp_rmem "4096 131072 $bufmax"
  append_sysctl "$temp" net.ipv4.tcp_wmem "4096 65536 $bufmax"
  append_sysctl "$temp" net.ipv4.tcp_mem "$(tcp_mem_values "$mem")"
  append_sysctl "$temp" net.ipv4.tcp_moderate_rcvbuf 1
  append_sysctl "$temp" net.ipv4.tcp_window_scaling 1
  append_sysctl "$temp" net.ipv4.tcp_adv_win_scale 1
  append_sysctl "$temp" net.ipv4.tcp_notsent_lowat "$notsent"
  append_sysctl "$temp" net.ipv4.tcp_sack 1
  append_sysctl "$temp" net.ipv4.tcp_dsack 1
  append_sysctl "$temp" net.ipv4.tcp_timestamps 1
  append_sysctl "$temp" net.ipv4.tcp_mtu_probing 1
  append_sysctl "$temp" net.ipv4.tcp_slow_start_after_idle 0
  append_sysctl "$temp" net.ipv4.tcp_no_metrics_save 1
  # Arbitrary clients behind unknown middleboxes: neither is worth the risk.
  append_sysctl "$temp" net.ipv4.tcp_ecn 0
  append_sysctl "$temp" net.ipv4.tcp_frto 0
  append_sysctl "$temp" net.core.netdev_max_backlog 16384
  append_sysctl "$temp" net.core.somaxconn 4096
  append_sysctl "$temp" net.ipv4.tcp_max_syn_backlog 4096
  append_sysctl "$temp" net.ipv4.tcp_tw_reuse 1
  append_sysctl "$temp" net.ipv4.tcp_fin_timeout 15

  chmod 0644 "$temp"
  mv -f "$temp" "$SYSCTL_FILE"
  has sysctl && { sysctl -p "$SYSCTL_FILE" >/dev/null || die "sysctl 加载失败；配置保留在 $SYSCTL_FILE"; }
  log "TCP 已更新：${cc}（$(cc_note "$cc")）"
  log "缓冲上限 $(format_mb "$bufmax")（$(buffer_reason "$PORT_MBPS" "$COVERAGE_RTT_MS" "$mem")）"
}

# No per-flow rate cap anywhere in here. With clients whose capacity spans an
# order of magnitude there is no single number that is not either useless for
# the slow ones or a throttle on the fast ones. Per-host fairness plus AQM
# needs no such number: it bounds the queue instead of the rate.
apply_qdisc() {
  local iface="$1" mode="${QDISC_MODE:-auto}" selected='' err
  err="$(mktemp)"
  has modprobe && {
    modprobe sch_cake >/dev/null 2>&1 || true
    modprobe sch_fq_codel >/dev/null 2>&1 || true
    modprobe sch_fq >/dev/null 2>&1 || true
  }
  tc qdisc del dev "$iface" root 2>/dev/null || true

  if [[ "$mode" == auto || "$mode" == cake ]]; then
    if (( TOTAL_MBPS > 0 )); then
      tc qdisc add dev "$iface" root cake bandwidth "${TOTAL_MBPS}mbit" besteffort dual-dsthost 2> "$err" && selected=cake
    else
      # Unlimited CAKE still does host isolation and COBALT AQM; it simply
      # does not shape. That is what we want when the bottleneck is remote.
      tc qdisc add dev "$iface" root cake besteffort dual-dsthost 2> "$err" && selected=cake
    fi
  fi
  if [[ -z "$selected" && ( "$mode" == auto || "$mode" == fq_codel ) ]]; then
    tc qdisc add dev "$iface" root fq_codel 2>> "$err" && selected=fq_codel
  fi
  if [[ -z "$selected" ]]; then
    tc qdisc add dev "$iface" root fq 2>> "$err" && selected=fq
  fi
  if [[ -z "$selected" ]]; then
    local detail; detail="$(tail -n 1 "$err" 2>/dev/null || true)"
    rm -f "$err"
    die "无法设置队列。${detail:+内核返回：$detail}"
  fi
  rm -f "$err"
  QDISC_MODE="$selected"
  case "$selected" in
    cake) log "已启用 CAKE dual-dsthost：按客户端公平 + AQM$( (( TOTAL_MBPS > 0 )) && printf '，总出口 ≤ %s Mbps' "$TOTAL_MBPS" )" ;;
    fq_codel) warn "本机没有 CAKE，退到 fq_codel（有 AQM，但没有按客户端公平）" ;;
    fq) warn "本机没有 CAKE/fq_codel，退到 fq（只有 pacing，没有 AQM）" ;;
  esac
}

write_service() {
  {
    printf '%s\n' '[Unit]'
    printf '%s\n' 'Description=peertune population-safe TCP tuning'
    printf '%s\n' 'After=network-online.target'
    printf '%s\n' 'Wants=network-online.target'
    printf '\n%s\n' '[Service]'
    printf '%s\n' 'Type=oneshot'
    printf 'ExecStart=%s apply\n' "$INSTALL_FILE"
    printf '%s\n' 'RemainAfterExit=yes'
    printf '\n%s\n' '[Install]'
    printf '%s\n' 'WantedBy=multi-user.target'
  } > "$SERVICE_FILE"
  chmod 0644 "$SERVICE_FILE"
}

install_files() {
  [[ "$(uname -s)" == Linux ]] || die "仅支持 Linux"
  has ip || die "缺少 ip；请安装 iproute2"
  has tc || die "缺少 tc；请安装 iproute2"
  has ss || die "缺少 ss；请安装 iproute2"
  has sysctl || die "缺少 sysctl；请安装 procps"
  has systemctl || die "当前版本需要 systemd"
  mkdir -p "$STATE_DIR"
  if [[ ! -e "$INSTALL_FILE" || ! "$0" -ef "$INSTALL_FILE" ]]; then
    install -m 0755 "$0" "$INSTALL_FILE"
  fi
  ln -sfn "$INSTALL_FILE" "$CLI_FILE"
  write_service
  systemctl daemon-reload
  systemctl enable peertune.service >/dev/null
  log "已安装命令与开机服务"
}

apply_all() {
  need_root "$@"
  take_lock
  load_config
  take_snapshot
  local iface; iface="$(resolve_iface)"
  write_sysctl_profile
  apply_qdisc "$iface"
  save_config
}

cmd_tune() {
  need_root "$@"
  take_lock
  load_config
  while (( $# )); do
    case "$1" in
      --coverage-rtt) [[ $# -ge 2 ]] || die "--coverage-rtt 缺少值"; COVERAGE_RTT_MS="$2"; shift 2 ;;
      --port) [[ $# -ge 2 ]] || die "--port 缺少值"; PORT_MBPS="$2"; shift 2 ;;
      --total) [[ $# -ge 2 ]] || die "--total 缺少值"; TOTAL_MBPS="$2"; shift 2 ;;
      --qdisc) [[ $# -ge 2 ]] || die "--qdisc 缺少值"; QDISC_MODE="$2"; shift 2 ;;
      --iface) [[ $# -ge 2 ]] || die "--iface 缺少值"; IFACE="$2"; shift 2 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  is_uint "$COVERAGE_RTT_MS" && (( COVERAGE_RTT_MS >= 20 && COVERAGE_RTT_MS <= 3000 )) || die "无效 --coverage-rtt（20-3000）"
  is_uint "$PORT_MBPS" && (( PORT_MBPS >= 10 && PORT_MBPS <= 100000 )) || die "无效 --port"
  is_uint "$TOTAL_MBPS" && (( TOTAL_MBPS == 0 || (TOTAL_MBPS >= 10 && TOTAL_MBPS <= 100000) )) || die "无效 --total（0 = 不限）"
  [[ "$QDISC_MODE" =~ ^(auto|cake|fq_codel|fq)$ ]] || die "无效 --qdisc"
  require_no_netshape
  save_config
  install_files
  apply_all
  printf '\n'
  coverage_note "$COVERAGE_RTT_MS"
}

cmd_status() {
  load_config
  local iface mem bufmax cc qdisc
  iface="$(detect_iface)"; [[ "$IFACE" != auto ]] && iface="$IFACE"
  mem="$(mem_total_mb)"; (( mem > 0 )) || mem=1024
  bufmax="$(calc_buffer_max "$PORT_MBPS" "$COVERAGE_RTT_MS" "$mem")"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'unknown')"
  qdisc="$(has tc && [[ -n "$iface" ]] && tc qdisc show dev "$iface" 2>/dev/null | awk '$1 == "qdisc" {print $2; exit}' || true)"

  panel_title 'peertune 状态'
  printf '  网卡:      %s\n' "${iface:-未检测到}"
  printf '  覆盖 RTT:  %s ms%b（覆盖值，不是实测）%b\n' "$COVERAGE_RTT_MS" "$DIM" "$RESET"
  printf '  端口参考:  %s Mbps\n' "$PORT_MBPS"
  printf '  缓冲上限:  %s（%s）\n' "$(format_mb "$bufmax")" "$(buffer_reason "$PORT_MBPS" "$COVERAGE_RTT_MS" "$mem")"
  printf '  拥塞控制:  %s —— %s\n' "$cc" "$(cc_note "$cc")"
  printf '  根队列:    %s\n' "${qdisc:-未知}"
  if (( TOTAL_MBPS > 0 )); then
    printf '  总出口:    ≤ %s Mbps\n' "$TOTAL_MBPS"
  else
    printf '  总出口:    不限（CAKE 仍做按客户端公平与 AQM）\n'
  fi
  printf '  单流上限:  %b无%b —— 客户端容量差一个数量级时，任何一个数都是错的\n' "$BOLD" "$RESET"
}

cmd_doctor() {
  load_config
  panel_title 'peertune 体检'
  local avail best cc iface qdisc
  avail="$(available_cc)"
  printf '  内核可用拥塞控制: %s\n' "${avail:-未知}"
  best="$(pick_congestion_control "$avail" || true)"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'unknown')"
  printf '  当前生效:          %s\n' "$cc"
  if [[ -n "$best" && "$best" != "$cc" ]]; then
    warn "内核提供了更适合抖动链路的 ${best}，当前却在用 ${cc}；跑 peertune apply 会切过去"
  fi
  if [[ "$cc" == bbr ]]; then
    printf '  %b注意：内核只报 "bbr"，看不出是 v1 还是 v3。XanMod 等发行版把 v3 也叫 bbr。%b\n' "$DIM" "$RESET"
    printf '  %b想确认可查：modinfo tcp_bbr 2>/dev/null | head -3%b\n' "$DIM" "$RESET"
  fi
  iface="$(detect_iface)"; [[ "$IFACE" != auto ]] && iface="$IFACE"
  if [[ -n "$iface" ]] && has tc; then
    qdisc="$(tc qdisc show dev "$iface" 2>/dev/null | awk '$1 == "qdisc" {print $2; exit}')"
    printf '  根队列:            %s\n' "${qdisc:-未知}"
    case "$qdisc" in
      cake) log "CAKE 生效，按客户端公平 + AQM 都在" ;;
      fq_codel) warn "fq_codel：有 AQM，但没有按客户端公平；装 sch_cake 更合适" ;;
      fq) warn "fq：只有 pacing，没有 AQM，一个客户端可以挤占其他人" ;;
      htb|tbf) warn "根队列是 ${qdisc}，像是别的工具设的；peertune 不用固定速率整形" ;;
      '') warn "读不到根队列" ;;
    esac
  fi
  if netshape_conflict; then
    printf '\n'
    warn "本机同时装有 netshape-manager —— 两者都会接管 root qdisc 和 sysctl。"
    warn "同时存在时谁最后跑谁生效，而且面板都会显示自己那一套，看不出真实状态。"
    info "只保留一个：sudo netshape uninstall，或 sudo peertune uninstall"
  fi
  printf '\n'
  coverage_note "$COVERAGE_RTT_MS"
}

cmd_uninstall() {
  need_root "$@"
  take_lock
  load_config
  local iface; iface="$(detect_iface)"; [[ "$IFACE" != auto ]] && iface="$IFACE"
  if [[ -n "$iface" ]] && has tc; then
    tc qdisc del dev "$iface" root 2>/dev/null || true
  fi
  systemctl disable --now peertune.service >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$SYSCTL_FILE" "$CONFIG_FILE"
  [[ -L "$CLI_FILE" && "$(readlink "$CLI_FILE")" == "$INSTALL_FILE" ]] && rm -f "$CLI_FILE"
  rm -f "$INSTALL_FILE"
  systemctl daemon-reload 2>/dev/null || true
  has sysctl && sysctl --system >/dev/null 2>&1 || true
  has sysctl && restore_snapshot
  rm -f "$SNAPSHOT_FILE"
  log "已卸载 peertune，根队列交还内核默认"
}

# ── 面板 ───────────────────────────────────────────────────────────────────

prompt_uint() {
  local prompt="$1" default="$2" min="$3" max="$4" value
  while true; do
    if ! read -r -p "$prompt [$default]: " value; then printf '\n' >&2; return 1; fi
    value="${value:-$default}"
    [[ "$value" == q || "$value" == Q ]] && return 1
    if is_uint "$value" && (( value >= min && value <= max )); then
      printf '%s\n' "$value"; return 0
    fi
    warn "请输入 $min-$max 之间的整数（q 返回）"
  done
}

pause_for_menu() {
  local discard
  [[ -t 0 ]] || return 0
  printf '\n'
  read -r -p "  $(printf '%b按回车返回菜单…%b' "$DIM" "$RESET")" discard || printf '\n'
}

run_action() { ( "$@" ) || warn "操作未完成，已返回菜单"; }

render_menu() {
  local cc qdisc iface mem bufmax
  iface="$(detect_iface)"; [[ "$IFACE" != auto ]] && iface="$IFACE"
  mem="$(mem_total_mb)"; (( mem > 0 )) || mem=1024
  bufmax="$(calc_buffer_max "$PORT_MBPS" "$COVERAGE_RTT_MS" "$mem")"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'unknown')"
  qdisc="$(has tc && [[ -n "$iface" ]] && tc qdisc show dev "$iface" 2>/dev/null | awk '$1 == "qdisc" {print $2; exit}' || true)"

  panel_title 'peertune 面板'
  printf '  %b面向一群客户端%b  %b容量和延迟都在变时，不设单流上限，只设安全边界%b\n' "$DIM" "$RESET" "$DIM" "$RESET"
  rule_light
  printf '  %b覆盖 RTT%b  %s ms%b（覆盖值，按最远的客户端定）%b\n' "$DIM" "$RESET" "$COVERAGE_RTT_MS" "$DIM" "$RESET"
  printf '  %b缓冲上限%b  %s\n' "$DIM" "$RESET" "$(format_mb "$bufmax")"
  printf '  %b拥塞控制%b  %s\n' "$DIM" "$RESET" "$cc"
  printf '  %b根队列%b    %s\n' "$DIM" "$RESET" "${qdisc:-未知}"
  if (( TOTAL_MBPS > 0 )); then
    printf '  %b总出口%b    ≤ %s Mbps\n' "$DIM" "$RESET" "$TOTAL_MBPS"
  else
    printf '  %b总出口%b    不限\n' "$DIM" "$RESET"
  fi
  netshape_conflict && printf '  %b[!] 同时装有 netshape-manager，两套配置会互相覆盖，按 5 看详情%b\n' "$YELLOW" "$RESET"
  rule_light
  printf '  %b1)%b %b看客户端分布%b（谁在卡、卡在哪）\n' "$BOLD" "$RESET" "$BOLD" "$RESET"
  printf '  %b2)%b 修改覆盖 RTT%b（当前：%s ms）%b\n' "$BOLD" "$RESET" "$DIM" "$COVERAGE_RTT_MS" "$RESET"
  printf '  %b3)%b 修改端口参考速率%b（当前：%s Mbps）%b\n' "$BOLD" "$RESET" "$DIM" "$PORT_MBPS" "$RESET"
  printf '  %b4)%b 修改整机总出口%b（当前：%s）%b\n' "$BOLD" "$RESET" "$DIM" \
    "$( (( TOTAL_MBPS > 0 )) && printf '%s Mbps' "$TOTAL_MBPS" || printf '不限' )" "$RESET"
  printf '  %b5)%b 体检（拥塞控制版本、队列、冲突检查）\n' "$BOLD" "$RESET"
  printf '  %b6)%b 状态\n' "$BOLD" "$RESET"
  printf '  %ba)%b 重新应用当前配置\n' "$BOLD" "$RESET"
  printf '  %b0)%b 退出\n' "$BOLD" "$RESET"
  rule_light
}

menu() {
  [[ -t 0 ]] || { usage; return; }
  local answer value
  [[ ${EUID:-$(id -u)} -eq 0 ]] || warn "当前不是 root，面板为只读模式；要修改请运行：sudo peertune"
  while true; do
    load_config
    render_menu
    if ! read -r -p '  请选择 [0-6 / a]: ' answer; then printf '\n'; return 0; fi
    case "$answer" in
      1) run_action cmd_scan ;;
      2)
        if value="$(prompt_uint '  覆盖 RTT（ms，按最远的客户端定，q 返回）' "$COVERAGE_RTT_MS" 20 3000)"; then
          run_action cmd_tune --coverage-rtt "$value"
        else info "已取消"; continue; fi
        ;;
      3)
        if value="$(prompt_uint '  端口参考速率（Mbps，q 返回）' "$PORT_MBPS" 10 100000)"; then
          run_action cmd_tune --port "$value"
        else info "已取消"; continue; fi
        ;;
      4)
        if value="$(prompt_uint '  整机总出口（Mbps，0 = 不限，q 返回）' "$TOTAL_MBPS" 0 100000)"; then
          run_action cmd_tune --total "$value"
        else info "已取消"; continue; fi
        ;;
      5) run_action cmd_doctor ;;
      6) run_action cmd_status ;;
      a|A) run_action apply_all ;;
      0|q|Q) return 0 ;;
      *) warn "无效选项"; continue ;;
    esac
    pause_for_menu
  done
}

usage() {
  cat <<'EOF'
peertune - 面向"一群客户端"的 TCP 观测与调优

netshape 假设客户端是一台固定容量的家宽设备，所以"一个 RTT + 一个单连接上限"
是对的。peertune 假设客户端是一群容量和延迟都在变的设备（5G、多地区、晚高峰）。
对一个分布不能取一个点来调，所以这里只做两件事：把分布显示出来，把全局边界设安全。

  peertune                      打开面板
  peertune scan                 采样每个客户端的 RTT 分布、抖动、排队膨胀、重传
  peertune scan --group net     按 /24 聚合（同一个人多设备时更好看）
  peertune scan --samples 8 --interval 5
  peertune tune                 应用调优（首次会安装自身与开机服务）
  peertune tune --coverage-rtt 250 --port 1000 --total 0
  peertune apply                重新应用已保存的配置
  peertune status               当前配置
  peertune doctor               拥塞控制版本、队列类型、与 netshape 的冲突检查
  peertune uninstall            卸载并按快照还原内核参数

三个关键指标（scan 输出）：
  膨胀 = RTT50 / 该路径最低 RTT   >3 说明对端接入网在囤队列（5G 的典型特征）
  抖动 = rttvar / RTT50           >0.3 是无线链路调度的典型特征
  重传% 取采样窗口内的增量        <0.1 干净，>1 基本是丢包或限速器

为什么没有"单连接限速"：客户端容量差一个数量级时，任何一个固定数字要么对慢的
那批不生效，要么在限制快的那批。CAKE 的 dual-dsthost 做按客户端公平 + AQM，
不需要知道任何一个客户端的速率。

为什么覆盖 RTT 不去实测：同一时刻不同运营商能差 2-3 倍，晚高峰再翻一倍，测出来
只是分布里随机的一个点。估高只多付一点 BBR 超发，估低是查不出来的硬天花板。
EOF
}

main() {
  local command="${1:-menu}"
  case "$command" in
    menu) load_config; menu ;;
    scan) shift; cmd_scan "$@" ;;
    tune) shift; cmd_tune "$@" ;;
    apply) apply_all ;;
    status) cmd_status ;;
    doctor) cmd_doctor ;;
    uninstall) cmd_uninstall ;;
    help|-h|--help) usage ;;
    version|--version) printf '%s %s\n' "$PROGRAM" "$VERSION" ;;
    *) die "未知命令：${command}（用 --help 查看帮助）" ;;
  esac
}

if [[ "${PEERTUNE_LIB_ONLY:-0}" != 1 ]]; then
  main "$@"
fi
