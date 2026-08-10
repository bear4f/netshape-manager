#!/usr/bin/env bash
# NetShape Manager - adaptive TCP/BBR and HTB+fq tuning for Linux relay hosts.
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="5.3.0"
PROGRAM="netshape"
INSTALL_FILE="/usr/local/sbin/netshape-manager"
CLI_FILE="/usr/local/bin/netshape"
CONFIG_FILE="/etc/netshape-manager.conf"
SYSCTL_FILE="/etc/sysctl.d/99-zz-netshape-manager.conf"
SERVICE_FILE="/etc/systemd/system/netshape-manager.service"
STATE_DIR="/var/lib/netshape-manager"
NGINX_SNIPPET="/etc/nginx/snippets/netshape-emby-proxy.conf"
SNAPSHOT_FILE="$STATE_DIR/pre-tune.snapshot"
LOCK_FILE="$STATE_DIR/lock"
ROUTE_HOOK="/etc/networkd-dispatcher/routable.d/50-netshape-initcwnd"

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

RETRANS_SAMPLE_SECS=5

RULE_HEAVY='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
RULE_LIGHT='──────────────────────────────────────'

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

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行：sudo $0 $*"
}

has() { command -v "$1" >/dev/null 2>&1; }

is_uint() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

# Serialise mutations: two SSH sessions editing the config or replacing the
# root qdisc at the same time interleave and leave both half-applied.
NETSHAPE_LOCKED=0
take_lock() {
  (( NETSHAPE_LOCKED == 1 )) && return 0
  has flock || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  exec 9>"$LOCK_FILE" 2>/dev/null || return 0
  flock -w 10 9 || die "另一个 netshape 进程正在修改配置，请稍后重试"
  NETSHAPE_LOCKED=1
}

detect_iface() {
  local iface=''
  if has ip; then
    iface="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
    [[ -n "$iface" ]] || iface="$(ip -o -6 route show to default 2>/dev/null | awk '{print $5; exit}')"
  fi
  printf '%s\n' "$iface"
}

mem_total_mb() {
  awk '/^MemTotal:/ {printf "%d\n", $2 / 1024; found=1} END {if (!found) print 0}' /proc/meminfo 2>/dev/null || printf '0\n'
}

swap_total_mb() {
  awk '/^SwapTotal:/ {printf "%d\n", $2 / 1024; found=1} END {if (!found) print 0}' /proc/meminfo 2>/dev/null || printf '0\n'
}

cpu_count() {
  if has nproc; then nproc; else awk '/^processor/ {n++} END {print n+0}' /proc/cpuinfo 2>/dev/null; fi
}

default_profile_for_rtt() {
  local rtt="$1"
  if (( rtt <= 80 )); then
    printf 'speed\n'
  elif (( rtt <= 180 )); then
    printf 'balanced\n'
  else
    printf 'stable\n'
  fi
}

recommended_rate() {
  local line="$1" profile="$2" rate
  if (( line >= 450 && line <= 550 )); then
    case "$profile" in
      speed) rate=450 ;;
      balanced) rate=430 ;;
      stable) rate=400 ;;
      *) return 1 ;;
    esac
  elif (( line >= 900 && line <= 1100 )); then
    case "$profile" in
      speed) rate=950 ;;
      balanced) rate=900 ;;
      stable) rate=850 ;;
      *) return 1 ;;
    esac
  else
    case "$profile" in
      speed) rate=$((line * 95 / 100)) ;;
      balanced) rate=$((line * 90 / 100)) ;;
      stable) rate=$((line * 85 / 100)) ;;
      *) return 1 ;;
    esac
  fi
  (( rate < 10 )) && rate=10
  printf '%s\n' "$rate"
}

tcp_mem_values() {
  # Global TCP memory in 4 KiB pages, scaled by RAM. The 1-4 GiB tier
  # uses field-proven values from a stable 2 GiB relay host.
  local mem="$1"
  if (( mem < 1024 )); then
    printf '32768 49152 98304\n'
  elif (( mem < 4096 )); then
    printf '65536 98304 196608\n'
  else
    printf '131072 196608 393216\n'
  fi
}

# A single socket must never be allowed to monopolise the global TCP budget:
# tcp_mem's ceiling divided by 8 leaves room for 8 concurrent large flows.
tcp_mem_budget_cap() {
  local mem="$1" pages
  pages="$(tcp_mem_values "$mem" | awk '{print $3}')"
  printf '%s\n' $(( pages * 4096 / 8 ))
}

memory_buffer_cap() {
  local mem="$1" cap budget
  if (( mem < 512 )); then
    cap=$((8 * 1024 * 1024))
  elif (( mem < 1024 )); then
    cap=$((16 * 1024 * 1024))
  elif (( mem < 2048 )); then
    cap=$((32 * 1024 * 1024))
  elif (( mem < 4096 )); then
    cap=$((64 * 1024 * 1024))
  else
    cap=$((128 * 1024 * 1024))
  fi
  # The ladder above is field-proven and today it is stricter than the budget
  # rule everywhere; the invariant is kept as a guard so editing the ladder
  # cannot silently let one socket eat the whole tcp_mem ceiling.
  budget="$(tcp_mem_budget_cap "$mem")"
  (( cap > budget )) && cap="$budget"
  (( cap > 268435456 )) && cap=268435456
  printf '%s\n' "$cap"
}

calculate_tcp_max() {
  local rate="$1" rtt="$2" mem="$3" bdp target cap
  # Mbps * ms * 125 = bytes in one bandwidth-delay product.
  bdp=$((rate * rtt * 125))
  # Exactly 2x BDP rounded to 1 MiB: oversized buffers let BBR hold a huge
  # cwnd on policed cross-border links and retransmissions explode.
  target=$((bdp * 2))
  (( target < 8388608 )) && target=8388608
  target=$(( (target + 1048575) / 1048576 * 1048576 ))
  cap="$(memory_buffer_cap "$mem")"
  (( target > cap )) && target="$cap"
  printf '%s\n' "$target"
}

# Which rule pinned the buffer ceiling. Without this a user who sees a
# truncated value assumes it is 2x BDP and goes looking for the problem
# somewhere else entirely.
buffer_cap_reason() {
  local rate="$1" rtt="$2" mem="$3" bdp doubled cap
  bdp=$((rate * rtt * 125))
  doubled=$((bdp * 2))
  cap="$(memory_buffer_cap "$mem")"
  if (( doubled < 8388608 )); then
    printf '下限 8 MiB\n'
  elif (( doubled > cap )); then
    printf '受 %s MB 内存限制\n' "$mem"
  else
    printf '2 倍 BDP\n'
  fi
}

# Two burst policies for the aggregate HTB class:
#   policer     ~1ms of tokens. A policer judges instantaneous rate, so a big
#               bucket is exactly what punches through it — the whole point of
#               this tool on cross-border links.
#   throughput  ~10ms of tokens, the pre-5.3 behaviour. Keep it if a large
#               burst measurably helps on a clean, unpoliced line.
calculate_htb_burst_kb() {
  local rate="$1" mode="${2:-policer}" burst
  if [[ "$mode" == throughput ]]; then
    burst=$(((rate * 1250 + 1023) / 1024))
    (( burst < 64 )) && burst=64
    (( burst > 2048 )) && burst=2048
  else
    burst=$(((rate * 125 + 1023) / 1024))
    (( burst < 32 )) && burst=32
    (( burst > 256 )) && burst=256
  fi
  printf '%s\n' "$burst"
}

# fq leaf queue depth. The kernel default of 100 packets per flow is far too
# shallow at 2 Gbit x 160ms; scaled down on small boxes so the queue itself
# cannot become the memory problem.
fq_leaf_limits() {
  local mem="$1"
  if (( mem < 1024 )); then
    printf '10240 2048\n'
  else
    printf '40960 8192\n'
  fi
}

# HTB delivers roughly 93-96% of its nominal rate, so a cap set at the port's
# line rate can never actually reach it. Only worth saying when the user has
# set the cap right up against a familiar port size.
burst_note() {
  local rate="${1:-0}"
  is_uint "$rate" && (( rate > 0 )) || return 0
  case "$rate" in
    2500|2400|2300|1000|960|950|900|500|450) ;;
    *) return 0 ;;
  esac
  info "提示：HTB 实际投递约为标称值的 93-96%，${rate} Mbps 的上限实测约 $(( rate * 93 / 100 ))-$(( rate * 96 / 100 )) Mbps"
}

profile_label() {
  case "${1:-}" in
    speed) printf '速度优先\n' ;;
    balanced) printf '推荐均衡\n' ;;
    stable) printf '稳定优先\n' ;;
    custom) printf '手动设置\n' ;;
    *) printf '未知\n' ;;
  esac
}

queue_label() {
  local shaping="${1:-on}" mode="${2:-}" shaper="${3:-}"
  if [[ "$shaping" == off || "$mode" == adaptive ]]; then
    printf 'fq（连接公平排队，不限速）\n'
    return
  fi
  if [[ "$mode" == combo ]]; then
    case "$shaper" in
      htb) printf 'HTB + fq maxrate（总出口＋单连接上限）\n' ;;
      tbf) printf 'TBF + fq maxrate（兼容总出口＋单连接上限）\n' ;;
      fq) printf 'fq maxrate（单条 TCP 连接上限）\n' ;;
      auto) printf '自动检测\n' ;;
      *) printf '未知\n' ;;
    esac
    return
  fi
  case "$shaper" in
    cake) printf 'CAKE（整机总出口＋按设备公平）\n' ;;
    htb) printf 'HTB + fq（整机总出口，按连接公平）\n' ;;
    tbf) printf 'TBF + fq（兼容整机总出口）\n' ;;
    fq) printf 'fq maxrate（单条 TCP 连接上限）\n' ;;
    auto) printf '自动检测\n' ;;
    *) printf '未知\n' ;;
  esac
}

role_label() {
  case "${1:-}" in
    relay) printf '中转/观看（客户端在家宽另一端）\n' ;;
    landing) printf '落地鸡（与中转机同区域，个位数延迟）\n' ;;
    *) printf '未知\n' ;;
  esac
}

role_short() {
  case "${1:-}" in
    relay) printf '中转/观看\n' ;;
    landing) printf '落地鸡\n' ;;
    *) printf '未知\n' ;;
  esac
}

# A landing box has two very different legs and they must not share one RTT:
#   origin -> landing   arbitrary internet RTT, this is where the bulk arrives
#   landing -> relay    single-digit ms on a clean link the user owns
# Sizing receive buffers off the relay's 5ms would cap every download from a
# distant origin, which is the opposite of what the machine is for. Send
# buffers keep the relay RTT and simply land on calculate_tcp_max's 8 MiB floor.
recv_buffer_rtt() {
  local role="${1:-relay}" rtt="${2:-160}" origin_rtt="${3:-150}"
  if [[ "$role" == landing ]]; then
    (( origin_rtt > rtt )) && { printf '%s\n' "$origin_rtt"; return; }
  fi
  printf '%s\n' "$rtt"
}

burst_mode_label() {
  case "${1:-}" in
    policer) printf '小突发（贴合限速线路，默认）\n' ;;
    throughput) printf '大突发（10ms 令牌，仅干净直连线路）\n' ;;
    *) printf '未知\n' ;;
  esac
}

burst_mode_short() {
  case "${1:-}" in
    policer) printf '小突发\n' ;;
    throughput) printf '大突发\n' ;;
    *) printf '未知\n' ;;
  esac
}

limit_mode_label() {
  case "${1:-}" in
    adaptive) printf '多设备自适应（不限制整机总速）\n' ;;
    perflow) printf '单条 TCP 连接上限\n' ;;
    total) printf '整机总出口上限\n' ;;
    combo) printf '单连接上限＋整机总出口（推荐）\n' ;;
    *) printf '未知\n' ;;
  esac
}

line_reference_label() {
  case "${1:-}" in
    500) printf '不知道/约 500 Mbps\n' ;;
    1000) printf '约 1 Gbps\n' ;;
    *) printf '自定义 %s Mbps\n' "${1:-未知}" ;;
  esac
}

# Root qdisc the current config should have produced, so the panel can spot a
# config that never got applied or was overwritten by another service.
expected_root_qdisc() {
  local shaping="${1:-on}" mode="${2:-combo}" shaper="${3:-auto}" total="${4:-0}"
  if [[ "$shaping" == off || "$mode" == adaptive || "$mode" == perflow ]]; then
    printf 'fq\n'
    return
  fi
  if [[ "$mode" == combo ]] && (( total == 0 )); then
    printf 'fq\n'
    return
  fi
  printf '%s\n' "$shaper"
}

actual_root_qdisc() {
  local iface="${1:-}"
  [[ -n "$iface" ]] || return 0
  has tc || return 0
  tc qdisc show dev "$iface" 2>/dev/null | awk 'NR==1 {print $2; exit}'
}

# Prints the actual qdisc only when it disagrees with the saved config.
qdisc_drift() {
  local iface="$1" shaping="$2" mode="$3" shaper="$4" total="$5" actual expected
  actual="$(actual_root_qdisc "$iface")"
  [[ -n "$actual" ]] || return 0
  expected="$(expected_root_qdisc "$shaping" "$mode" "$shaper" "$total")"
  case "$expected" in
    fq) [[ "$actual" == fq || "$actual" == fq_codel ]] && return 0 ;;
    auto) [[ "$actual" == cake || "$actual" == htb || "$actual" == tbf ]] && return 0 ;;
    *) [[ "$actual" == "$expected" ]] && return 0 ;;
  esac
  printf '%s\n' "$actual"
}

# Cheap enough to run on every panel render; nginx -T is not.
nginx_snippet_state() {
  has nginx || { printf 'none\n'; return; }
  [[ -e "$NGINX_SNIPPET" ]] || { printf 'missing\n'; return; }
  if grep -rqs --exclude="$(basename "$NGINX_SNIPPET")" 'netshape-emby-proxy\.conf' /etc/nginx/ 2>/dev/null; then
    printf 'ok\n'
  else
    printf 'unlinked\n'
  fi
}

tcp_seg_counters() {
  local out
  has nstat || return 1
  out="$(nstat -asz 2>/dev/null)" || return 1
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out" | awk '
    $1 == "TcpOutSegs" {sent = $2}
    $1 == "TcpRetransSegs" {retrans = $2}
    END {if (sent == "" || retrans == "") exit 1; print sent, retrans}
  '
}

# Cumulative since boot. On a host that has been up for months this is heavily
# diluted, so it is reported as a weak smoke signal only and deliberately
# carries no verdict — retrans_sample is what a decision should be based on.
retrans_rate() {
  local counters sent retrans
  counters="$(tcp_seg_counters)" || return 0
  sent="${counters%% *}"; retrans="${counters##* }"
  is_uint "$sent" && is_uint "$retrans" || return 0
  (( sent > 0 )) || return 0
  awk -v r="$retrans" -v s="$sent" 'BEGIN {printf "%.2f\n", r * 100 / s}'
}

# Retransmitted share of segments sent inside a measurement window. Costs the
# sample duration, so it belongs in status/diagnose rather than a panel render.
retrans_sample() {
  local secs="${1:-5}" first second s1 r1 s2 r2 ds dr
  first="$(tcp_seg_counters)" || return 0
  sleep "$secs"
  second="$(tcp_seg_counters)" || return 0
  s1="${first%% *}"; r1="${first##* }"
  s2="${second%% *}"; r2="${second##* }"
  is_uint "$s1" && is_uint "$r1" && is_uint "$s2" && is_uint "$r2" || return 0
  ds=$((s2 - s1)); dr=$((r2 - r1))
  # Too little traffic in the window for the ratio to mean anything.
  (( ds >= 1000 )) || return 0
  (( dr < 0 )) && return 0
  awk -v r="$dr" -v s="$ds" 'BEGIN {printf "%.3f\n", r * 100 / s}'
}

# Thresholds follow the regression published by the tcpfit project: across
# seven real hosts the clean side topped out at 0.0017% and the lowest reading
# from a host hitting a policer was 1.354%. 0.1% sits clear of both.
retrans_verdict() {
  awk -v p="${1:-0}" 'BEGIN {
    if (p < 0.1) print "干净";
    else if (p < 1) print "偏高，线路或档位需要留意";
    else print "撞限速器，建议把单连接上限降一档";
  }'
}

format_bytes() {
  local bytes="$1"
  if (( bytes >= 1073741824 )); then
    awk -v b="$bytes" 'BEGIN {printf "%.1f GiB", b/1073741824}'
  elif (( bytes >= 1048576 )); then
    awk -v b="$bytes" 'BEGIN {printf "%.0f MiB", b/1048576}'
  else
    awk -v b="$bytes" 'BEGIN {printf "%.0f KiB", b/1024}'
  fi
}

default_config() {
  LINE_MBPS=500
  RTT_MS=160
  PROFILE="custom"
  RATE_MBPS=430
  TOTAL_MBPS=0
  SHAPING="on"
  IFACE="auto"
  SHAPER_MODE="auto"
  LIMIT_MODE="combo"
  BURST_MODE="policer"
  INITCWND=32
  ROLE="relay"
  ORIGIN_RTT_MS=150
}

load_config() {
  default_config
  [[ -r "$CONFIG_FILE" ]] || return 0
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      LINE_MBPS) is_uint "$value" && LINE_MBPS="$value" ;;
      RTT_MS) is_uint "$value" && RTT_MS="$value" ;;
      PROFILE) [[ "$value" =~ ^(speed|balanced|stable|custom)$ ]] && PROFILE="$value" ;;
      RATE_MBPS) is_uint "$value" && RATE_MBPS="$value" ;;
      TOTAL_MBPS) is_uint "$value" && TOTAL_MBPS="$value" ;;
      SHAPING) [[ "$value" =~ ^(on|off)$ ]] && SHAPING="$value" ;;
      IFACE) [[ "$value" =~ ^[a-zA-Z0-9_.:-]+$ ]] && IFACE="$value" ;;
      SHAPER_MODE) [[ "$value" =~ ^(auto|cake|htb|tbf|fq)$ ]] && SHAPER_MODE="$value" ;;
      LIMIT_MODE) [[ "$value" =~ ^(adaptive|perflow|total|combo)$ ]] && LIMIT_MODE="$value" ;;
      BURST_MODE) [[ "$value" =~ ^(policer|throughput)$ ]] && BURST_MODE="$value" ;;
      INITCWND) is_uint "$value" && (( value == 0 || (value >= 2 && value <= 64) )) && INITCWND="$value" ;;
      ROLE) [[ "$value" =~ ^(relay|landing)$ ]] && ROLE="$value" ;;
      ORIGIN_RTT_MS) is_uint "$value" && (( value >= 1 && value <= 3000 )) && ORIGIN_RTT_MS="$value" ;;
    esac
  done < "$CONFIG_FILE"
  # A rejected value on the final line would otherwise make load_config exit
  # non-zero and take the whole script down with it under errexit.
  return 0
}

save_config() {
  local temp
  mkdir -p "$(dirname "$CONFIG_FILE")"
  temp="$(mktemp "${CONFIG_FILE}.XXXXXX")"
  chmod 0644 "$temp"
  {
    printf '# NetShape Manager persistent configuration\n'
    printf 'LINE_MBPS=%s\n' "$LINE_MBPS"
    printf 'RTT_MS=%s\n' "$RTT_MS"
    printf 'PROFILE=%s\n' "$PROFILE"
    printf 'RATE_MBPS=%s\n' "$RATE_MBPS"
    printf 'TOTAL_MBPS=%s\n' "$TOTAL_MBPS"
    printf 'SHAPING=%s\n' "$SHAPING"
    printf 'IFACE=%s\n' "$IFACE"
    printf 'SHAPER_MODE=%s\n' "$SHAPER_MODE"
    printf 'LIMIT_MODE=%s\n' "$LIMIT_MODE"
    printf 'BURST_MODE=%s\n' "$BURST_MODE"
    printf 'INITCWND=%s\n' "$INITCWND"
    printf 'ROLE=%s\n' "$ROLE"
    printf 'ORIGIN_RTT_MS=%s\n' "$ORIGIN_RTT_MS"
  } > "$temp"
  mv -f "$temp" "$CONFIG_FILE"
}

sysctl_path() {
  printf '/proc/sys/%s\n' "$(printf '%s' "$1" | tr '.' '/')"
}

append_sysctl() {
  local file="$1" key="$2" value="$3" path
  path="$(sysctl_path "$key")"
  if [[ -e "$path" ]]; then
    printf '%s = %s\n' "$key" "$value" >> "$file"
  else
    warn "当前内核不支持 ${key}，已跳过"
  fi
}

# Every kernel key write_sysctl_profile touches. Rollback is only as complete
# as this list, so tests/self-test.sh asserts it against the actual
# append_sysctl calls — a key added to one and not the other fails the build.
TUNED_KEYS='
vm.swappiness
vm.min_free_kbytes
kernel.panic
net.core.default_qdisc
net.ipv4.tcp_congestion_control
net.core.somaxconn
net.core.netdev_max_backlog
net.ipv4.tcp_max_syn_backlog
net.ipv4.tcp_syncookies
net.ipv4.tcp_window_scaling
net.ipv4.tcp_sack
net.ipv4.tcp_dsack
net.ipv4.tcp_timestamps
net.ipv4.tcp_no_metrics_save
net.ipv4.tcp_moderate_rcvbuf
net.core.rmem_default
net.core.wmem_default
net.core.rmem_max
net.core.wmem_max
net.core.optmem_max
net.ipv4.tcp_rmem
net.ipv4.tcp_wmem
net.ipv4.tcp_mem
net.ipv4.tcp_adv_win_scale
net.ipv4.tcp_notsent_lowat
net.ipv4.tcp_mtu_probing
net.ipv4.tcp_ecn
net.ipv4.tcp_frto
net.ipv4.tcp_fastopen
net.ipv4.tcp_fastopen_blackhole_timeout_sec
net.ipv4.tcp_slow_start_after_idle
net.ipv4.tcp_tw_reuse
net.ipv4.tcp_fin_timeout
net.ipv4.tcp_keepalive_time
net.ipv4.tcp_keepalive_intvl
net.ipv4.tcp_keepalive_probes
net.ipv4.udp_rmem_min
net.ipv4.udp_wmem_min
net.ipv4.ip_local_port_range
net.ipv4.tcp_max_tw_buckets
fs.file-max
net.netfilter.nf_conntrack_max
'

# Removing the sysctl file does not put the running kernel back: every key
# stays at the tuned value until reboot. The snapshot is what makes uninstall
# actually undo something.
take_snapshot() {
  local key value pristine=1
  [[ -e "$SNAPSHOT_FILE" ]] && return 0
  mkdir -p "$STATE_DIR"
  # An existing profile means the live values are already ours, so they cannot
  # serve as a factory baseline. Recorded anyway (refusing would break every
  # in-place upgrade) but flagged, so uninstall can say what it can restore.
  if [[ -e "$SYSCTL_FILE" ]]; then
    pristine=0
    warn "检测到已有 NetShape sysctl 配置但没有出厂快照。"
    warn "现在记录的是「已调优」状态，卸载只能回到这里，无法回到出厂值。"
  fi
  {
    printf '# NetShape Manager pre-tune snapshot %s\n' "$(date -u +%FT%TZ 2>/dev/null || printf 'unknown')"
    printf '# PRISTINE=%s\n' "$pristine"
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

snapshot_is_pristine() {
  [[ -r "$SNAPSHOT_FILE" ]] || return 1
  grep -q '^# PRISTINE=1$' "$SNAPSHOT_FILE"
}

restore_snapshot() {
  local key value restored=0
  if [[ ! -r "$SNAPSHOT_FILE" ]]; then
    warn "找不到快照，只移除了配置文件；已调优的内核参数会保留到下次重启"
    return 0
  fi
  # Tab and newline only in IFS, so a value like "4096 87380 33554432" is
  # written back whole rather than being split into three sysctl calls.
  while IFS='=' read -r key value; do
    [[ "$key" == \#* || -z "$key" ]] && continue
    [[ -n "$value" ]] || continue
    sysctl -qw "$key=$value" >/dev/null 2>&1 && restored=$((restored + 1))
  done < "$SNAPSHOT_FILE"
  if snapshot_is_pristine; then
    log "已按出厂快照还原 ${restored} 项内核参数"
  else
    warn "已还原 ${restored} 项内核参数，但快照记录的是安装时的已调优状态，不是出厂值"
  fi
}

choose_congestion_control() {
  local available=''
  has modprobe && modprobe tcp_bbr >/dev/null 2>&1 || true
  [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]] && available="$(< /proc/sys/net/ipv4/tcp_available_congestion_control)"
  if [[ " $available " == *" bbr "* ]]; then
    printf 'bbr\n'
  elif [[ " $available " == *" cubic "* ]]; then
    warn "内核未提供 BBR，自动回退到 cubic"
    printf 'cubic\n'
  else
    awk '{print $1}' /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || printf 'cubic\n'
  fi
}

write_sysctl_profile() {
  need_root "$@"
  take_lock
  load_config
  take_snapshot
  local mem rmax wmax backlog notsent cc temp min_free tcpmem rrtt
  local somaxconn syn_backlog tw_buckets file_max port_range conntrack
  mem="$(mem_total_mb)"
  (( mem > 0 )) || mem=1024
  rrtt="$(recv_buffer_rtt "$ROLE" "$RTT_MS" "$ORIGIN_RTT_MS")"
  rmax="$(calculate_tcp_max "$RATE_MBPS" "$rrtt" "$mem")"
  wmax="$(calculate_tcp_max "$RATE_MBPS" "$RTT_MS" "$mem")"
  if (( mem < 1024 )); then backlog=4096; else backlog=16384; fi
  if (( mem < 1024 )); then min_free=32768; else min_free=65536; fi
  if (( rrtt >= 120 )); then notsent=16384; else notsent=32768; fi
  tcpmem="$(tcp_mem_values "$mem")"
  # A landing box is an exit: thousands of short-lived outbound connections,
  # so the limits that bite are table sizes and ephemeral ports, not bandwidth.
  if [[ "$ROLE" == landing ]]; then
    somaxconn=8192; syn_backlog=8192; port_range='10240 65535'
    if (( mem < 1024 )); then
      tw_buckets=65536; file_max=262144; conntrack=131072
    else
      tw_buckets=262144; file_max=1048576; conntrack=524288
    fi
  else
    somaxconn=2048; syn_backlog=2048; port_range='32768 60999'
    tw_buckets=32768; file_max=262144; conntrack=65536
  fi
  has modprobe && modprobe sch_fq >/dev/null 2>&1 || true
  cc="$(choose_congestion_control)"

  mkdir -p "$(dirname "$SYSCTL_FILE")" "$STATE_DIR"
  temp="$(mktemp "${SYSCTL_FILE}.XXXXXX")"
  {
    printf '# Generated by NetShape Manager %s - do not hand edit.\n' "$VERSION"
    printf '# Inputs: role=%s line=%sMbps rate=%sMbps RTT=%sms recv-RTT=%sms RAM=%sMB\n\n' \
      "$ROLE" "$LINE_MBPS" "$RATE_MBPS" "$RTT_MS" "$rrtt" "$mem"
  } > "$temp"

  append_sysctl "$temp" vm.swappiness 10
  append_sysctl "$temp" vm.min_free_kbytes "$min_free"
  append_sysctl "$temp" kernel.panic 10
  append_sysctl "$temp" net.core.default_qdisc fq
  append_sysctl "$temp" net.ipv4.tcp_congestion_control "$cc"
  append_sysctl "$temp" net.core.somaxconn "$somaxconn"
  append_sysctl "$temp" net.core.netdev_max_backlog "$backlog"
  append_sysctl "$temp" net.ipv4.tcp_max_syn_backlog "$syn_backlog"
  append_sysctl "$temp" net.ipv4.tcp_syncookies 1
  append_sysctl "$temp" net.ipv4.tcp_window_scaling 1
  append_sysctl "$temp" net.ipv4.tcp_sack 1
  append_sysctl "$temp" net.ipv4.tcp_dsack 1
  append_sysctl "$temp" net.ipv4.tcp_timestamps 1
  append_sysctl "$temp" net.ipv4.tcp_no_metrics_save 1
  append_sysctl "$temp" net.ipv4.tcp_moderate_rcvbuf 1
  append_sysctl "$temp" net.core.rmem_default 262144
  append_sysctl "$temp" net.core.wmem_default 262144
  append_sysctl "$temp" net.core.rmem_max "$rmax"
  append_sysctl "$temp" net.core.wmem_max "$wmax"
  append_sysctl "$temp" net.core.optmem_max 4194304
  # Modest defaults so video seeks do not burst; max grows via autotuning.
  append_sysctl "$temp" net.ipv4.tcp_rmem "4096 87380 $rmax"
  append_sysctl "$temp" net.ipv4.tcp_wmem "4096 65536 $wmax"
  append_sysctl "$temp" net.ipv4.tcp_mem "$tcpmem"
  append_sysctl "$temp" net.ipv4.tcp_adv_win_scale 1
  append_sysctl "$temp" net.ipv4.tcp_notsent_lowat "$notsent"
  append_sysctl "$temp" net.ipv4.tcp_mtu_probing 1
  # Cross-border middleboxes: ECN / F-RTO / TCP Fast Open cause blackholes.
  append_sysctl "$temp" net.ipv4.tcp_ecn 0
  append_sysctl "$temp" net.ipv4.tcp_frto 0
  append_sysctl "$temp" net.ipv4.tcp_fastopen 0
  append_sysctl "$temp" net.ipv4.tcp_fastopen_blackhole_timeout_sec 0
  append_sysctl "$temp" net.ipv4.tcp_slow_start_after_idle 0
  append_sysctl "$temp" net.ipv4.tcp_tw_reuse 1
  append_sysctl "$temp" net.ipv4.tcp_fin_timeout 15
  append_sysctl "$temp" net.ipv4.tcp_keepalive_time 600
  append_sysctl "$temp" net.ipv4.tcp_keepalive_intvl 60
  append_sysctl "$temp" net.ipv4.tcp_keepalive_probes 5
  append_sysctl "$temp" net.ipv4.udp_rmem_min 16384
  append_sysctl "$temp" net.ipv4.udp_wmem_min 16384
  # Exit-node scaling. Written for both roles so rollback always has a value
  # to restore; the landing tier is simply much larger.
  append_sysctl "$temp" net.ipv4.ip_local_port_range "$port_range"
  append_sysctl "$temp" net.ipv4.tcp_max_tw_buckets "$tw_buckets"
  append_sysctl "$temp" fs.file-max "$file_max"
  # Only present when conntrack is loaded; a full table silently drops new
  # connections and looks exactly like an upstream problem.
  append_sysctl "$temp" net.netfilter.nf_conntrack_max "$conntrack"

  chmod 0644 "$temp"
  mv -f "$temp" "$SYSCTL_FILE"

  if has sysctl; then
    sysctl -p "$SYSCTL_FILE" >/dev/null || die "sysctl 加载失败；配置文件保留在 $SYSCTL_FILE 供检查"
  fi
  if [[ "$ROLE" == landing ]]; then
    log "TCP 配置已更新（落地鸡）：${cc}，接收缓冲 $(format_bytes "$rmax")（按回源 ${rrtt}ms 计算），发送缓冲 $(format_bytes "$wmax")"
  else
    log "TCP 配置已更新：${cc}，缓冲上限 $(format_bytes "$rmax")（$(buffer_cap_reason "$RATE_MBPS" "$rrtt" "$mem")），notsent ${notsent}B"
  fi
  if (( rmax < RATE_MBPS * rrtt * 125 )); then
    warn "内存较小，TCP 缓冲上限低于单流 BDP；高 RTT 下单连接可能无法跑满线路"
  fi
  if (( mem <= 1024 )) && (( $(swap_total_mb) == 0 )); then
    warn "本机 ${mem} MB 内存且没有 swap：TCP 缓冲一涨内核会直接杀进程，"
    warn "表现为「测速跑一半掉速」。建议加 1-2G swap 再长期使用。"
  fi
}

resolve_iface() {
  load_config
  local resolved="$IFACE"
  [[ "$resolved" == auto ]] && resolved="$(detect_iface)"
  [[ -n "$resolved" ]] || die "未找到默认出口网卡；可在 $CONFIG_FILE 中设置 IFACE"
  [[ -d "/sys/class/net/$resolved" ]] || die "网卡不存在：$resolved"
  printf '%s\n' "$resolved"
}

root_qdisc_kind() {
  local iface="${1:-}"
  [[ -n "$iface" ]] || return 0
  has tc || return 0
  tc qdisc show dev "$iface" 2>/dev/null | awk '$1 == "qdisc" {print $2; exit}'
}

baseline_qdisc() {
  [[ -r "$STATE_DIR/baseline-qdisc" ]] || return 0
  head -n 1 "$STATE_DIR/baseline-qdisc" 2>/dev/null
}

# Recorded once, before netshape first replaces the root qdisc, so uninstall
# can put back what the machine actually shipped with.
record_baseline_qdisc() {
  local iface="$1" kind
  [[ -e "$STATE_DIR/baseline-qdisc" ]] && return 0
  kind="$(root_qdisc_kind "$iface")"
  [[ -n "$kind" ]] || return 0
  case "$kind" in
    htb|tbf|cake) return 0 ;;   # already one of ours, not a baseline
  esac
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$kind" > "$STATE_DIR/baseline-qdisc"
}

# Used when shaping is paused or falls back: we want fq semantics, but on a
# multi-queue NIC deleting the root brings back mq with fq leaves (because
# default_qdisc=fq), which is strictly better than collapsing it to one fq.
restore_default_qdisc() {
  local iface="$1" baseline
  baseline="$(baseline_qdisc)"
  tc qdisc del dev "$iface" root 2>/dev/null || true
  case "$baseline" in
    mq|mqprio|noqueue) return 0 ;;
  esac
  tc qdisc replace dev "$iface" root fq 2>/dev/null || \
    tc qdisc replace dev "$iface" root fq_codel 2>/dev/null || true
}

# Uninstall path: put the original qdisc back rather than leaving the machine
# on fq forever. mq/noqueue are rebuilt by the kernel and must not be re-added.
restore_baseline_qdisc() {
  local iface="$1" baseline
  baseline="$(baseline_qdisc)"
  tc qdisc del dev "$iface" root 2>/dev/null || true
  case "$baseline" in
    ''|mq|mqprio|noqueue|pfifo_fast) return 0 ;;
    *) tc qdisc replace dev "$iface" root "$baseline" 2>/dev/null || true ;;
  esac
}

# A root qdisc we did not put there and cannot faithfully rebuild belongs to
# someone else's tuning; replacing it silently is how configuration disappears.
qdisc_guard() {
  local iface="$1" kind reply
  kind="$(root_qdisc_kind "$iface")"
  case "$kind" in
    ''|mq|mqprio|noqueue|pfifo_fast|fq|fq_codel|htb|tbf|cake) return 0 ;;
  esac
  warn "本机根 qdisc 是 ${kind}，不是 NetShape 能原样重建的类型。"
  warn "继续会替换它，卸载时只能恢复成 ${kind} 的默认参数，自定义配置会丢失。"
  [[ -t 0 ]] || return 0
  read -r -p '  仍要继续？[y/N]: ' reply || return 1
  [[ "$reply" =~ ^[Yy]$ ]]
}

# tc normalises units on output (1000mbit prints as "1Gbit"), so verification
# has to compare numbers, not strings.
tc_rate_to_mbps() {
  awk -v s="${1:-}" 'BEGIN {
    if (!match(s, /^[0-9.]+/)) exit 1
    v = substr(s, RSTART, RLENGTH) + 0
    u = substr(s, RSTART + RLENGTH)
    if (u ~ /^[Gg]/) v *= 1000
    else if (u ~ /^[Kk]/) v /= 1000
    else if (u !~ /^[Mm]/) v /= 1000000
    printf "%d\n", v + 0.5
  }'
}

# Confirm against the kernel instead of trusting tc's exit code.
verify_shaper() {
  local iface="$1" kind="$2" want="$3" field='' got=''
  has tc || return 0
  case "$kind" in
    htb) field=rate; got="$(tc class show dev "$iface" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "rate") {print $(i+1); exit}}')" ;;
    tbf) field=rate; got="$(tc qdisc show dev "$iface" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "rate") {print $(i+1); exit}}')" ;;
    cake) field=bandwidth; got="$(tc qdisc show dev "$iface" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "bandwidth") {print $(i+1); exit}}')" ;;
    fq) field=maxrate; got="$(tc qdisc show dev "$iface" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "maxrate") {print $(i+1); exit}}')" ;;
    *) return 0 ;;
  esac
  if [[ -z "$got" ]]; then
    warn "tc 未报告 ${kind} 的 ${field}，限速可能没有真正生效：tc qdisc show dev ${iface}"
    return 1
  fi
  got="$(tc_rate_to_mbps "$got")" || return 0
  is_uint "$got" || return 0
  if ! awk -v g="$got" -v w="$want" 'BEGIN {exit !(g >= w * 0.98 && g <= w * 1.02)}'; then
    warn "实际生效速率 ${got} Mbps 与期望的 ${want} Mbps 不符：tc qdisc show dev ${iface}"
    return 1
  fi
  return 0
}

# fq leaf shared by the HTB and TBF paths. Old kernels reject limit/flow_limit;
# retrying plain keeps that from looking like "HTB unsupported" and falling
# through to the compatibility shaper.
add_fq_leaf() {
  local iface="$1" parent="$2" handle="$3" maxrate="$4" mem="$5" error_file="$6"
  local limits limit flow_limit args=()
  limits="$(fq_leaf_limits "$mem")"
  limit="${limits%% *}"; flow_limit="${limits##* }"
  args=(fq limit "$limit" flow_limit "$flow_limit")
  [[ -n "$maxrate" ]] && args+=(maxrate "${maxrate}mbit")
  tc qdisc add dev "$iface" parent "$parent" handle "$handle" "${args[@]}" 2>> "$error_file" && return 0
  args=(fq)
  [[ -n "$maxrate" ]] && args+=(maxrate "${maxrate}mbit")
  tc qdisc add dev "$iface" parent "$parent" handle "$handle" "${args[@]}" 2>> "$error_file"
}

try_cake() {
  # dual-dsthost: fair share per destination device first, then per flow,
  # so one device's multi-connection download cannot starve another's stream.
  local iface="$1" rate="$2" error_file="$3"
  tc qdisc del dev "$iface" root 2>/dev/null || true
  tc qdisc add dev "$iface" root cake bandwidth "${rate}mbit" besteffort dual-dsthost 2> "$error_file" || return 1
}

try_htb_fq() {
  local iface="$1" rate="$2" burst_kb="$3" error_file="$4" maxrate="${5:-}" mem="${6:-1024}"
  tc qdisc del dev "$iface" root 2>/dev/null || true
  tc qdisc add dev "$iface" root handle 1: htb default 10 r2q 1000 2> "$error_file" || return 1
  tc class add dev "$iface" parent 1: classid 1:10 htb rate "${rate}mbit" ceil "${rate}mbit" burst "${burst_kb}kb" cburst "${burst_kb}kb" quantum 15140 2>> "$error_file" || return 1
  add_fq_leaf "$iface" 1:10 10: "$maxrate" "$mem" "$error_file" || return 1
}

try_tbf_fq() {
  local iface="$1" rate="$2" burst_kb="$3" error_file="$4" maxrate="${5:-}" mem="${6:-1024}"
  tc qdisc del dev "$iface" root 2>/dev/null || true
  tc qdisc add dev "$iface" root handle 1: tbf rate "${rate}mbit" burst "${burst_kb}kb" latency 50ms 2> "$error_file" || return 1
  add_fq_leaf "$iface" 1:1 10: "$maxrate" "$mem" "$error_file" || return 1
}

try_fq_maxrate() {
  local iface="$1" rate="$2" error_file="$3" mem="${4:-1024}"
  local limits limit flow_limit
  limits="$(fq_leaf_limits "$mem")"
  limit="${limits%% *}"; flow_limit="${limits##* }"
  tc qdisc del dev "$iface" root 2>/dev/null || true
  tc qdisc add dev "$iface" root fq limit "$limit" flow_limit "$flow_limit" maxrate "${rate}mbit" 2> "$error_file" && return 0
  tc qdisc add dev "$iface" root fq maxrate "${rate}mbit" 2>> "$error_file" || return 1
}

# Larger initial windows shave RTTs off the start of every connection, which
# on a high-BDP cross-border path is exactly the play/seek feel. Rewritten
# from the live default route so its other attributes survive.
apply_initcwnd() {
  local iface="$1" spec
  local IFS=$' \t\n'
  (( INITCWND == 0 )) && return 0
  has ip || return 0
  spec="$(ip route show default 2>/dev/null | head -n 1)"
  [[ -n "$spec" ]] || return 0
  [[ "$spec" == *" dev $iface"* || "$spec" == *" dev $iface" ]] || return 0
  spec="$(printf '%s\n' "$spec" | sed -E 's/ initcwnd [0-9]+//g; s/ initrwnd [0-9]+//g')"
  # shellcheck disable=SC2086
  if ip route replace $spec initcwnd "$INITCWND" initrwnd "$INITCWND" 2>/dev/null; then
    write_route_hook
    return 0
  fi
  warn "无法设置 initcwnd（部分虚拟化平台不支持），已跳过；其余调优不受影响"
  return 0
}

# DHCP renew or a link flap rewrites the default route and drops the option.
write_route_hook() {
  [[ -d /etc/networkd-dispatcher/routable.d ]] || return 0
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' '# Generated by NetShape Manager - reapplies initcwnd after route changes.'
    printf '%s\n' 'SPEC=$(ip route show default 2>/dev/null | head -n 1)'
    printf '%s\n' '[ -n "$SPEC" ] || exit 0'
    printf '%s\n' 'SPEC=$(printf "%s\\n" "$SPEC" | sed -E "s/ initcwnd [0-9]+//g; s/ initrwnd [0-9]+//g")'
    printf 'ip route replace $SPEC initcwnd %s initrwnd %s 2>/dev/null\n' "$INITCWND" "$INITCWND"
    printf '%s\n' 'exit 0'
  } > "$ROUTE_HOOK" 2>/dev/null || return 0
  chmod 0755 "$ROUTE_HOOK" 2>/dev/null || true
}

apply_shape() {
  need_root "$@"
  has tc || die "缺少 tc；请先安装 iproute2"
  take_lock
  load_config
  local iface burst_kb requested_mode selected_mode='' error_file detail mem
  iface="$(resolve_iface)"
  mem="$(mem_total_mb)"; (( mem > 0 )) || mem=1024
  burst_kb="$(calculate_htb_burst_kb "$RATE_MBPS" "$BURST_MODE")"
  requested_mode="$SHAPER_MODE"
  record_baseline_qdisc "$iface"
  qdisc_guard "$iface" || die "已取消，未改动队列"
  has modprobe && {
    modprobe sch_cake >/dev/null 2>&1 || true
    modprobe sch_htb >/dev/null 2>&1 || true
    modprobe sch_tbf >/dev/null 2>&1 || true
    modprobe sch_fq >/dev/null 2>&1 || true
  }

  if [[ "$SHAPING" == off ]]; then
    restore_default_qdisc "$iface"
    log "已取消人为限速，并恢复连接公平排队：$iface"
    return 0
  fi

  (( RATE_MBPS >= 10 && RATE_MBPS <= 100000 )) || die "无效限速：${RATE_MBPS}Mbps"

  if [[ "$LIMIT_MODE" == adaptive ]]; then
    restore_default_qdisc "$iface"
    SHAPER_MODE=fq
    save_config
    log "已启用不限速自适应：无整机总上限，每条 TCP 连接独立适应自己的网络"
    return 0
  fi

  error_file="$(mktemp)"

  if [[ "$LIMIT_MODE" == combo ]]; then
    (( TOTAL_MBPS == 0 || (TOTAL_MBPS >= 10 && TOTAL_MBPS <= 100000) )) || die "无效整机总出口：${TOTAL_MBPS}Mbps（0 表示不限制）"
    if (( TOTAL_MBPS == 0 )); then
      info "正在设置单条 TCP 连接上限 ${RATE_MBPS} Mbps（整机总出口不限）"
      if try_fq_maxrate "$iface" "$RATE_MBPS" "$error_file" "$mem"; then
        SHAPER_MODE=fq
        save_config
        rm -f "$error_file"
        verify_shaper "$iface" fq "$RATE_MBPS" || true
        log "已启用 fq maxrate：每条连接 ≤ ${RATE_MBPS} Mbps，多设备各自跑满自己的家宽"
        return 0
      fi
      detail="$(tail -n 1 "$error_file" 2>/dev/null || true)"
      rm -f "$error_file"
      restore_default_qdisc "$iface"
      die "当前 VPS 不支持单连接限速，已恢复不限速 fq。${detail:+ 内核返回：$detail}"
    fi
    burst_kb="$(calculate_htb_burst_kb "$TOTAL_MBPS" "$BURST_MODE")"
    info "正在设置：单条连接 ≤ ${RATE_MBPS} Mbps ＋ 整机总出口 ≤ ${TOTAL_MBPS} Mbps（网卡 ${iface}）"
    if [[ "$requested_mode" == auto || "$requested_mode" == cake || "$requested_mode" == htb ]] \
      && try_htb_fq "$iface" "$TOTAL_MBPS" "$burst_kb" "$error_file" "$RATE_MBPS" "$mem"; then
      selected_mode=htb
    elif [[ "$requested_mode" != fq ]] \
      && try_tbf_fq "$iface" "$TOTAL_MBPS" "$burst_kb" "$error_file" "$RATE_MBPS" "$mem"; then
      selected_mode=tbf
    elif try_fq_maxrate "$iface" "$RATE_MBPS" "$error_file" "$mem"; then
      selected_mode=fq
      warn "本机不支持总出口限速，已只保留单连接上限"
    else
      detail="$(tail -n 1 "$error_file" 2>/dev/null || true)"
      rm -f "$error_file"
      restore_default_qdisc "$iface"
      die "当前 VPS 不支持限速队列，已恢复不限速 fq。${detail:+ 内核返回：$detail}"
    fi
    SHAPER_MODE="$selected_mode"
    save_config
    rm -f "$error_file"
    case "$selected_mode" in
      htb)
        verify_shaper "$iface" htb "$TOTAL_MBPS" || true
        log "已启用 HTB + fq maxrate：单条连接 ≤ ${RATE_MBPS} Mbps，整机合计 ≤ ${TOTAL_MBPS} Mbps"
        ;;
      tbf)
        verify_shaper "$iface" tbf "$TOTAL_MBPS" || true
        log "已启用 TBF + fq maxrate（兼容）：单条连接 ≤ ${RATE_MBPS} Mbps，整机合计 ≤ ${TOTAL_MBPS} Mbps"
        ;;
      fq)
        verify_shaper "$iface" fq "$RATE_MBPS" || true
        log "已启用 fq maxrate：每条连接 ≤ ${RATE_MBPS} Mbps（无总上限）"
        ;;
    esac
    burst_note "$TOTAL_MBPS"
    return 0
  fi

  if [[ "$LIMIT_MODE" == perflow ]]; then
    info "正在设置单条 TCP 连接上限：${RATE_MBPS} Mbps（不会限制所有设备合计速度）"
    if try_fq_maxrate "$iface" "$RATE_MBPS" "$error_file" "$mem"; then
      SHAPER_MODE=fq
      save_config
      rm -f "$error_file"
      verify_shaper "$iface" fq "$RATE_MBPS" || true
      log "已启用 fq maxrate：每条 TCP 连接最多 ${RATE_MBPS} Mbps，多设备可同时使用"
      return 0
    fi
    detail="$(tail -n 1 "$error_file" 2>/dev/null || true)"
    rm -f "$error_file"
    restore_default_qdisc "$iface"
    die "当前 VPS 不支持单连接限速，已恢复不限速 fq。${detail:+ 内核返回：$detail}"
  fi

  info "正在设置整机总出口上限 ${RATE_MBPS} Mbps（CAKE/HTB/TBF，网卡 ${iface}）"

  if [[ "$requested_mode" == auto || "$requested_mode" == cake ]]; then
    if try_cake "$iface" "$RATE_MBPS" "$error_file"; then
      selected_mode=cake
    fi
  fi

  if [[ -z "$selected_mode" && ( "$requested_mode" == auto || "$requested_mode" == cake || "$requested_mode" == htb ) ]]; then
    if try_htb_fq "$iface" "$RATE_MBPS" "$burst_kb" "$error_file" "" "$mem"; then
      selected_mode=htb
    fi
  fi

  if [[ -z "$selected_mode" && "$requested_mode" != fq ]]; then
    if try_tbf_fq "$iface" "$RATE_MBPS" "$burst_kb" "$error_file" "" "$mem"; then
      selected_mode=tbf
    fi
  fi

  if [[ -z "$selected_mode" ]]; then
    detail="$(tail -n 1 "$error_file" 2>/dev/null || true)"
    rm -f "$error_file"
    restore_default_qdisc "$iface"
    die "当前 VPS 不支持整机合计限速，已恢复不限速 fq。${detail:+ 内核返回：$detail}"
  fi
  rm -f "$error_file"

  if [[ "$selected_mode" != "$requested_mode" ]]; then
    SHAPER_MODE="$selected_mode"
    save_config
  fi

  verify_shaper "$iface" "$selected_mode" "$RATE_MBPS" || true
  case "$selected_mode" in
    cake) log "已启用 CAKE：总出口 ${RATE_MBPS} Mbps，各设备先均分带宽，单设备多连接不会挤占其他设备" ;;
    htb) log "已启用 HTB + fq：整台机器所有连接合计不超过 ${RATE_MBPS} Mbps（按连接公平）" ;;
    tbf)
      warn "本机不支持 CAKE 和 HTB，已自动切换到兼容模式 TBF + fq"
      log "整台机器所有连接合计不超过 ${RATE_MBPS} Mbps"
      ;;
  esac
  burst_note "$RATE_MBPS"
}

apply_all() {
  write_sysctl_profile
  apply_shape
  apply_initcwnd "$(resolve_iface)"
}

set_profile() {
  local profile="${1:-}"
  [[ "$profile" =~ ^(speed|balanced|stable)$ ]] || die "档位必须是 speed、balanced 或 stable"
  need_root "$@"
  take_lock
  load_config
  PROFILE="$profile"
  RATE_MBPS="$(recommended_rate "$LINE_MBPS" "$PROFILE")"
  LIMIT_MODE="combo"
  SHAPER_MODE="auto"
  SHAPING="on"
  save_config
  apply_all
}

set_rate() {
  local rate="${1:-}"
  is_uint "$rate" || die "速率必须是整数 Mbps，例如 430 或 850"
  (( rate >= 10 && rate <= 100000 )) || die "速率范围为 10-100000 Mbps"
  need_root "$@"
  take_lock
  load_config
  RATE_MBPS="$rate"
  PROFILE="custom"
  LIMIT_MODE="combo"
  SHAPER_MODE="auto"
  SHAPING="on"
  save_config
  apply_all
}

set_adaptive() {
  need_root "$@"
  take_lock
  load_config
  LIMIT_MODE="adaptive"
  PROFILE="custom"
  # Keep the buffer basis conservative even without a shaper: oversized
  # buffers are what let BBR overrun policed cross-border links.
  RATE_MBPS=450
  SHAPING="on"
  SHAPER_MODE="fq"
  save_config
  apply_all
  warn "不限速模式只适合干净直连线路；跨境/共享线路请优先使用整机总出口档位"
}

set_total_rate() {
  local rate="${1:-}"
  is_uint "$rate" || die "整机总出口必须是整数 Mbps，例如 2300；0 表示不限制"
  (( rate == 0 || (rate >= 10 && rate <= 100000) )) || die "范围为 0 或 10-100000 Mbps"
  need_root "$@"
  take_lock
  load_config
  TOTAL_MBPS="$rate"
  LIMIT_MODE="combo"
  SHAPING="on"
  SHAPER_MODE="auto"
  save_config
  # The sysctl profile depends only on RATE_MBPS and RTT_MS, so reshaping the
  # queue is enough here; skipping sysctl -p keeps the panel responsive.
  apply_shape
}

set_rtt() {
  local rtt="${1:-}"
  is_uint "$rtt" || die "RTT 必须是整数毫秒，例如 160"
  (( rtt >= 1 && rtt <= 3000 )) || die "RTT 范围为 1-3000ms"
  need_root "$@"
  take_lock
  load_config
  RTT_MS="$rtt"
  if [[ "$PROFILE" != custom ]]; then
    PROFILE="$(default_profile_for_rtt "$RTT_MS")"
    RATE_MBPS="$(recommended_rate "$LINE_MBPS" "$PROFILE")"
  fi
  save_config
  apply_all
}

set_line() {
  local line="${1:-}"
  is_uint "$line" || die "计算参考速度必须是整数 Mbps，例如 500 或 1000"
  (( line >= 10 && line <= 100000 )) || die "计算参考速度范围为 10-100000 Mbps"
  need_root "$@"
  take_lock
  load_config
  LINE_MBPS="$line"
  [[ "$PROFILE" == custom ]] && PROFILE="$(default_profile_for_rtt "$RTT_MS")"
  RATE_MBPS="$(recommended_rate "$LINE_MBPS" "$PROFILE")"
  SHAPING="on"
  save_config
  apply_all
}

set_off() {
  need_root "$@"
  take_lock
  load_config
  SHAPING="off"
  save_config
  apply_shape
}

# Landing box: the per-flow cap exists to keep a single stream from
# overrunning someone's home broadband across a policed border. Neither
# condition holds here, so the cap is dropped and the aggregate one becomes
# purely optional port protection.
set_landing() {
  local total="${1:-}"
  need_root "$@"
  take_lock
  load_config
  is_uint "$total" || total=0
  ROLE="landing"
  PROFILE="custom"
  SHAPING="on"
  RATE_MBPS=0
  TOTAL_MBPS="$total"
  # No policer between two boxes in the same region, so a large token bucket
  # is free throughput rather than a way to get punched through.
  BURST_MODE="throughput"
  if (( total > 0 )); then
    LIMIT_MODE="total"
    RATE_MBPS="$total"
    SHAPER_MODE="auto"
  else
    LIMIT_MODE="adaptive"
    RATE_MBPS=1000
    SHAPER_MODE="fq"
  fi
  save_config
  apply_all
  log "已按落地鸡模式配置：不限制单连接，$( (( total > 0 )) && printf '整机总出口 ≤ %s Mbps' "$total" || printf '不限制整机总出口' )"
  info "接收缓冲按回源 ${ORIGIN_RTT_MS}ms 计算，连接表/端口范围已按出口节点放大。"
}

set_relay_role() {
  need_root "$@"
  take_lock
  load_config
  ROLE="relay"
  BURST_MODE="policer"
  LIMIT_MODE="combo"
  SHAPER_MODE="auto"
  SHAPING="on"
  (( RATE_MBPS < 10 )) && RATE_MBPS=430
  save_config
  apply_all
  log "已切回中转/观看模式：单连接 ≤ ${RATE_MBPS} Mbps"
}

set_origin_rtt() {
  local rtt="${1:-}"
  is_uint "$rtt" || die "回源延迟参考必须是整数毫秒，例如 150"
  (( rtt >= 1 && rtt <= 3000 )) || die "回源延迟参考范围为 1-3000ms"
  need_root "$@"
  take_lock
  load_config
  ORIGIN_RTT_MS="$rtt"
  save_config
  write_sysctl_profile
}

set_burst() {
  local mode="${1:-}"
  [[ "$mode" =~ ^(policer|throughput)$ ]] || die "整形突发只能是 policer 或 throughput"
  need_root "$@"
  take_lock
  load_config
  BURST_MODE="$mode"
  save_config
  apply_shape
  info "整形突发已切换为：$(burst_mode_label "$mode")"
  info "两种模式请在真机上对比重传率（netshape status）后再定，没有普适答案。"
}

set_initcwnd() {
  local value="${1:-}"
  is_uint "$value" || die "初始窗口必须是整数，0 表示不修改路由"
  (( value == 0 || (value >= 2 && value <= 64) )) || die "初始窗口范围为 0 或 2-64"
  need_root "$@"
  take_lock
  load_config
  INITCWND="$value"
  save_config
  if (( value == 0 )); then
    rm -f "$ROUTE_HOOK"
    local spec IFS=$' \t\n'
    spec="$(ip route show default 2>/dev/null | head -n 1)"
    if [[ "$spec" == *initcwnd* ]] && has ip; then
      # shellcheck disable=SC2086
      ip route replace $(printf '%s\n' "$spec" | sed -E 's/ initcwnd [0-9]+//g; s/ initrwnd [0-9]+//g') 2>/dev/null || true
    fi
    log "已停用 initcwnd 调整，默认路由恢复内核默认初始窗口"
    return 0
  fi
  apply_initcwnd "$(resolve_iface)"
  log "初始窗口已设为 initcwnd/initrwnd ${value}"
}

set_resume() {
  need_root "$@"
  take_lock
  load_config
  SHAPING="on"
  save_config
  apply_all
}

write_nginx_snippet() {
  if ! has nginx; then
    info "本机未安装 Nginx，已跳过 Emby 反代片段。"
    info "只做中转、观看别人的 Emby 时不需要此功能；TCP 调优已覆盖中转流量。"
    return 0
  fi
  need_root "$@"
  mkdir -p "$(dirname "$NGINX_SNIPPET")"
  if [[ -e "$NGINX_SNIPPET" && ! -e "${NGINX_SNIPPET}.netshape-backup" ]]; then
    cp -a "$NGINX_SNIPPET" "${NGINX_SNIPPET}.netshape-backup"
  fi
  {
    printf '%s\n' '# NetShape Manager: include this file inside the Emby location block.'
    printf '%s\n' 'proxy_http_version 1.1;'
    printf '%s\n' 'proxy_set_header Host $host;'
    printf '%s\n' 'proxy_set_header X-Real-IP $remote_addr;'
    printf '%s\n' 'proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;'
    printf '%s\n' 'proxy_set_header X-Forwarded-Proto $scheme;'
    printf '%s\n' 'proxy_set_header Upgrade $http_upgrade;'
    printf '%s\n' 'proxy_set_header Connection $http_connection;'
    printf '%s\n' 'proxy_buffering off;'
    printf '%s\n' 'proxy_request_buffering off;'
    printf '%s\n' 'proxy_max_temp_file_size 0;'
    printf '%s\n' 'proxy_read_timeout 3600s;'
    printf '%s\n' 'proxy_send_timeout 3600s;'
    printf '%s\n' 'send_timeout 3600s;'
    printf '%s\n' 'proxy_limit_rate 0;'
    printf '%s\n' 'limit_rate 0;'
    printf '%s\n' 'proxy_ignore_headers X-Accel-Limit-Rate;'
    printf '%s\n' 'proxy_socket_keepalive on;'
  } > "$NGINX_SNIPPET"
  chmod 0644 "$NGINX_SNIPPET"
  log "已生成 Nginx 片段：$NGINX_SNIPPET"
  info "请在 Emby 的 location 块中加入：include $NGINX_SNIPPET;"
  info "该片段取消 Nginx 单请求限速；TCP 调度由 NetShape 处理。"
}

nginx_audit() {
  if ! has nginx; then
    warn "未检测到 Nginx"
    return 0
  fi
  local output
  output="$(mktemp)"
  if ! nginx -T > "$output" 2>&1; then
    sed -n '1,80p' "$output"
    rm -f "$output"
    die "nginx -T 失败，请先修复 Nginx 配置"
  fi
  printf '%b▸ 可能影响 Emby 的限速/超时指令%b\n' "$BOLD" "$RESET"
  if ! grep -En '^[[:space:]]*(limit_rate|proxy_limit_rate|limit_conn|limit_req|proxy_(read|send)_timeout)[[:space:]]' "$output"; then
    printf '%s\n' '未发现显式限速指令。'
  fi
  printf '\n%b▸ Emby 不限流片段是否已生效%b\n' "$BOLD" "$RESET"
  if [[ ! -e "$NGINX_SNIPPET" ]]; then
    warn "尚未生成片段；请先运行 netshape nginx-snippet"
  elif grep -q 'netshape-emby-proxy\.conf' "$output"; then
    log "片段已被 include，不限流与关闭缓冲配置生效"
  else
    warn "片段已生成，但没有任何站点 include 它，等于没有生效！"
    info "请在本机 Nginx 反代 Emby 的 location 块中加入："
    info "  include ${NGINX_SNIPPET};"
    info "定位站点文件可用：grep -rn proxy_pass /etc/nginx/"
    info "加入后执行：nginx -t && systemctl reload nginx"
  fi
  printf '\n%b▸ 代理缓冲检查（反代掉速的常见根源）%b\n' "$BOLD" "$RESET"
  if grep -Eq '^[[:space:]]*proxy_buffering[[:space:]]+off' "$output"; then
    printf '%s\n' '已找到 proxy_buffering off。'
  else
    warn "未发现 proxy_buffering off：Nginx 默认把视频流缓冲到磁盘临时文件再转发，"
    warn "典型症状是速度大幅波动、长时间只有几十兆。include 上述片段即可关闭缓冲。"
  fi
  rm -f "$output"
  info "审计仅报告，不会改动现有站点配置。"
}

show_status() {
  load_config
  local iface mem swap tcp_max cc qdisc
  iface="$(detect_iface)"
  [[ "$IFACE" != auto ]] && iface="$IFACE"
  mem="$(mem_total_mb)"; swap="$(swap_total_mb)"
  tcp_max="$(calculate_tcp_max "$RATE_MBPS" "$(recv_buffer_rtt "$ROLE" "$RTT_MS" "$ORIGIN_RTT_MS")" "${mem:-1024}")"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'unknown')"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || printf 'unknown')"

  panel_title 'NetShape 状态'
  printf '  系统:      %s\n' "$(uname -srmo 2>/dev/null || uname -a)"
  printf '  CPU/RAM:   %s vCPU / %s MB RAM / %s MB Swap\n' "$(cpu_count)" "$mem" "$swap"
  printf '  网卡:      %s\n' "${iface:-未检测到}"
  printf '  机器角色:  %s\n' "$(role_label "$ROLE")"
  if [[ "$ROLE" == landing ]]; then
    printf '  延迟参考:  到中转机 %s ms / 回源 %s ms（接收缓冲按后者算）\n' "$RTT_MS" "$ORIGIN_RTT_MS"
  else
    printf '  延迟参考:  %s ms\n' "$RTT_MS"
  fi
  printf '  网络策略:  %s\n' "$(limit_mode_label "$LIMIT_MODE")"
  if [[ "$SHAPING" == off ]]; then
    printf '  限速状态:  已暂停人为限速（保留 fq 公平排队）\n'
  else
    case "$LIMIT_MODE" in
      adaptive) printf '  限速状态:  不限制整机总速度\n' ;;
      perflow) printf '  限速状态:  每条 TCP 连接最多 %s Mbps\n' "$RATE_MBPS" ;;
      total) printf '  限速状态:  整台机器所有连接合计 %s Mbps\n' "$RATE_MBPS" ;;
      combo)
        if (( TOTAL_MBPS > 0 )); then
          printf '  限速状态:  单条连接 ≤ %s Mbps，整机合计 ≤ %s Mbps\n' "$RATE_MBPS" "$TOTAL_MBPS"
        else
          printf '  限速状态:  单条连接 ≤ %s Mbps，整机总出口不限\n' "$RATE_MBPS"
        fi
        ;;
    esac
  fi
  printf '  队列模式:  %s\n' "$(queue_label "$SHAPING" "$LIMIT_MODE" "$SHAPER_MODE")"
  printf '  整形突发:  %s\n' "$(burst_mode_label "$BURST_MODE")"
  if (( INITCWND > 0 )); then
    printf '  初始窗口:  initcwnd/initrwnd %s%s\n' "$INITCWND" \
      "$( [[ "$(ip route show default 2>/dev/null | head -n 1)" == *initcwnd* ]] && printf '（已生效）' || printf '（未生效）' )"
  else
    printf '  初始窗口:  未启用\n'
  fi
  printf '  TCP:       %s + %s / 缓冲建议 %s\n' "$cc" "$qdisc" "$(format_bytes "$tcp_max")"
  if [[ -n "$iface" ]] && has ip; then
    printf '  MTU:       %s\n' "$(ip -o link show dev "$iface" 2>/dev/null | sed -n 's/.* mtu \([0-9]*\).*/\1/p')"
  fi
  if [[ -n "$iface" ]] && has tc; then
    printf '\n%b▸ qdisc 队列统计%b\n' "$BOLD" "$RESET"
    tc -s qdisc show dev "$iface" 2>/dev/null || true
    printf '\n%b▸ 限速类别统计%b\n' "$BOLD" "$RESET"
    tc -s class show dev "$iface" 2>/dev/null || true
  fi
  if has nstat; then
    local pct live
    printf '\n%b▸ TCP 重传%b\n' "$BOLD" "$RESET"
    pct="$(retrans_rate)"
    [[ -n "$pct" ]] && printf '  自开机累计  %s%%%b（机器跑得越久越被稀释，仅供参考）%b\n' "$pct" "$DIM" "$RESET"
    printf '  正在采样 %s 秒…\r' "$RETRANS_SAMPLE_SECS"
    live="$(retrans_sample "$RETRANS_SAMPLE_SECS")"
    if [[ -n "$live" ]]; then
      printf '  实时 %ss     %s%%  —— %s\n' "$RETRANS_SAMPLE_SECS" "$live" "$(retrans_verdict "$live")"
      printf '  %b参考：<0.1%% 干净｜0.1-1%% 偏高｜>1%% 基本是撞上了限速器%b\n' "$DIM" "$RESET"
    else
      printf '  实时 %ss     采样窗口内流量太少，无法判定（有人在看片时再测一次）\n' "$RETRANS_SAMPLE_SECS"
    fi
    nstat -asz 2>/dev/null | awk '$1 ~ /TcpOutSegs|TcpRetransSegs|TcpExtTCPLostRetransmit|TcpExtTCPFastRetrans/ {printf "  %s %s\n", $1, $2}' || true
  fi
}

diagnose() {
  show_status
  printf '\n%b▸ 冲突检查%b\n' "$BOLD" "$RESET"
  local found=0 file
  for file in /etc/sysctl.conf /etc/sysctl.d/*.conf; do
    [[ -r "$file" && "$file" != "$SYSCTL_FILE" ]] || continue
    if grep -Eq '^[[:space:]]*(net\.core\.default_qdisc|net\.ipv4\.tcp_congestion_control|net\.core\.[rw]mem_max|net\.ipv4\.tcp_[rw]mem)[[:space:]]*=' "$file"; then
      printf '  可能覆盖关键参数：%s\n' "$file"
      found=1
    fi
  done
  (( found == 0 )) && printf '  未发现明显的重复 TCP 配置。\n'
  if has systemctl; then
    for file in netshape.service tc-fq-maxrate.service netpace.service; do
      systemctl is-enabled "$file" >/dev/null 2>&1 && printf '  可能冲突的服务：%s\n' "$file"
    done
  fi
  if has nginx; then
    printf '\n'
    nginx_audit
  fi
  printf '\n提示：播放器断流还应同时检查源站负载、丢包、MTU、反代日志和客户端缓冲。\n'
}

confirm_adaptive() {
  local reply
  [[ -t 0 ]] || return 0
  read -r -p '不限速模式在跨境/共享线路上会大量重传甚至断流，确定使用？[y/N]: ' reply || return 1
  [[ "$reply" =~ ^[Yy]$ ]]
}

# Returns 1 when the user cancels with q or Ctrl-D so callers can go back to
# the menu instead of being forced to enter a value.
prompt_uint() {
  local prompt="$1" default="$2" min="$3" max="$4" value
  while true; do
    if ! read -r -p "$prompt [$default]: " value; then
      printf '\n' >&2
      return 1
    fi
    value="${value:-$default}"
    [[ "$value" == q || "$value" == Q ]] && return 1
    if is_uint "$value" && (( value >= min && value <= max )); then
      printf '%s\n' "$value"
      return 0
    fi
    warn "请输入 $min-$max 之间的整数（q 返回）"
  done
}

# Shared by the wizard and the panel so both offer the same port presets.
# Prompts go to stderr because the caller reads stdout in $(...).
prompt_total_mbps() {
  local answer
  printf '%s\n' \
    '' \
    '  这台 VPS 的端口/线路有多大？（整机总出口保护，防止打满端口）' \
    '    1) 2.5G 口：总出口 2300 Mbps' \
    '    2) 1G 口：总出口 900 Mbps' \
    '    3) 500M 口：总出口 450 Mbps' \
    '    4) 不知道/不限制总出口' \
    '    5) 自定义' >&2
  read -r -p '  请选择 [1]（q 返回）: ' answer || { printf '\n' >&2; return 1; }
  case "${answer:-1}" in
    1) printf '2300\n' ;;
    2) printf '900\n' ;;
    3) printf '450\n' ;;
    4) printf '0\n' ;;
    5) prompt_uint '  整机总出口上限（Mbps，0 表示不限）' "${TOTAL_MBPS:-2300}" 0 100000 ;;
    q|Q) return 1 ;;
    *) warn "无效选项"; return 1 ;;
  esac
}

# The one-liner lands here instead of dropping straight into a questionnaire:
# a landing box and a relay want opposite settings, and asking someone about
# home-broadband tiers when they are installing on an exit node is confusing.
install_menu() {
  need_root "$@"
  [[ -t 0 ]] || die "交互安装需要终端；自动安装请使用 install --non-interactive --rate 430 --total 2300 --rtt 160"
  local answer total
  while true; do
    panel_title 'NetShape 安装'
    printf '  检测到：%s vCPU｜%s MB 内存｜%s MB Swap｜网卡 %s\n' \
      "$(cpu_count)" "$(mem_total_mb)" "$(swap_total_mb)" "$(detect_iface)"
    rule_light
    printf '  %b这台机器是做什么的？%b\n' "$BOLD" "$RESET"
    printf '    %b1)%b %b中转/观看机%b —— 客户端在家宽另一端，跨境线路\n' "$BOLD" "$RESET" "$BOLD" "$RESET"
    printf '       %b逐项询问延迟、VPS 端口、家宽档位，套双层限速%b\n' "$DIM" "$RESET"
    printf '    %b2)%b %b落地鸡%b —— 与中转机同区域，延迟个位数，无跨境限速器\n' "$BOLD" "$RESET" "$BOLD" "$RESET"
    printf '       %b直接套用：不限单连接、按出口节点放大连接表、缓冲按回源计算%b\n' "$DIM" "$RESET"
    printf '    %b3)%b 只做基础 TCP 调优%b（BBR + fq，完全不限速）%b\n' "$BOLD" "$RESET" "$DIM" "$RESET"
    printf '    %b0)%b 退出\n' "$BOLD" "$RESET"
    rule_light
    read -r -p '  请选择 [1]: ' answer || { printf '\n'; return 0; }
    case "${answer:-1}" in
      1) wizard "$@"; return 0 ;;
      2)
        printf '\n  %b落地鸡模式将套用：%b\n' "$BOLD" "$RESET"
        printf '    · 不限制单条连接（家宽上限那套在这里没有意义）\n'
        printf '    · 接收缓冲按回源 %s ms 计算，而不是到中转机的个位数延迟\n' "$ORIGIN_RTT_MS"
        printf '    · 端口范围、TIME_WAIT 桶、conntrack、文件句柄按出口节点放大\n'
        printf '    · HTB 大突发（同区域无限速器，不需要压突发）\n\n'
        if total="$(prompt_total_mbps)"; then
          default_config
          ROLE=landing
          RTT_MS=5
          save_config
          install_files "$@"
          set_landing "$total"
          write_nginx_snippet
          printf '\n'
          log "安装完成。以后运行 netshape 可再次进入面板。"
          return 0
        fi
        info "已取消"
        ;;
      3)
        default_config
        ROLE=relay
        LIMIT_MODE=adaptive
        SHAPER_MODE=fq
        SHAPING=on
        save_config
        install_files "$@"
        apply_all
        printf '\n'
        log "已只做基础 TCP 调优（BBR + fq，无任何限速）。"
        info "以后运行 netshape 进面板，可随时改成限速档位。"
        return 0
        ;;
      0|q|Q) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

wizard() {
  need_root "$@"
  [[ -t 0 ]] || die "交互向导需要终端；自动安装请使用 install --line 500 --rtt 160"
  local mem swap answer custom
  mem="$(mem_total_mb)"; swap="$(swap_total_mb)"
  panel_title 'NetShape 安装向导'
  printf '  检测到：%s vCPU｜%s MB 内存｜%s MB Swap｜网卡 %s\n\n' "$(cpu_count)" "$mem" "$swap" "$(detect_iface)"
  RTT_MS="$(prompt_uint '你本地连接这台 VPS 大约多少毫秒（不知道直接回车）' 160 1 3000)" || die "已取消安装"
  TOTAL_MBPS="$(prompt_total_mbps)" || die "已取消安装"
  printf '%s\n' \
    '' \
    '观看设备的家宽档位？（单条 TCP 连接上限，防止单条流打爆到家的路径）' \
    '  1) 500M 家宽：单连接 430 Mbps（Emby 稳定，推荐）' \
    '  2) 500M 家宽：单连接 450 Mbps（速度优先）' \
    '  3) 1G 家宽：单连接 850 Mbps（稳定）' \
    '  4) 1G 家宽：单连接 900 Mbps（速度优先）' \
    '  5) 自定义单连接上限' \
    '  6) 不限速自适应（仅干净直连线路，跨境线路易大量重传）'
  read -r -p '请选择 [1]: ' answer || die "已取消安装"
  case "${answer:-1}" in
    1)
      LIMIT_MODE=combo
      RATE_MBPS=430
      LINE_MBPS=500
      SHAPER_MODE=auto
      ;;
    2)
      LIMIT_MODE=combo
      RATE_MBPS=450
      LINE_MBPS=500
      SHAPER_MODE=auto
      ;;
    3)
      LIMIT_MODE=combo
      RATE_MBPS=850
      LINE_MBPS=1000
      SHAPER_MODE=auto
      ;;
    4)
      LIMIT_MODE=combo
      RATE_MBPS=900
      LINE_MBPS=1000
      SHAPER_MODE=auto
      ;;
    5)
      custom="$(prompt_uint '单条 TCP 连接上限（Mbps）' 430 10 100000)" || die "已取消安装"
      LIMIT_MODE=combo
      RATE_MBPS="$custom"
      LINE_MBPS="$custom"
      SHAPER_MODE=auto
      ;;
    6)
      if confirm_adaptive; then
        LIMIT_MODE=adaptive
        RATE_MBPS=450
        LINE_MBPS=500
        SHAPER_MODE=fq
      else
        info "已改用默认单连接 430 Mbps 稳定档"
        LIMIT_MODE=combo
        RATE_MBPS=430
        LINE_MBPS=500
        SHAPER_MODE=auto
      fi
      ;;
    *) die "无效选项" ;;
  esac
  PROFILE="custom"; SHAPING="on"; IFACE="auto"
  save_config
  install_files
  apply_all
  write_nginx_snippet
  printf '\n'
  log "安装完成。以后运行 netshape 可再次进入面板。"
}

disable_known_conflicts() {
  local unit found=0
  : > "$STATE_DIR/disabled-services"
  for unit in netshape.service tc-fq-maxrate.service netpace.service; do
    if systemctl is-enabled "$unit" >/dev/null 2>&1 || systemctl is-active "$unit" >/dev/null 2>&1; then
      systemctl disable --now "$unit" >/dev/null 2>&1 || true
      printf '%s\n' "$unit" >> "$STATE_DIR/disabled-services"
      warn "已停用会覆盖 root qdisc 的旧服务：$unit"
      found=1
    fi
  done
  if (( found == 0 )); then
    rm -f "$STATE_DIR/disabled-services"
  fi
}

write_service() {
  {
    printf '%s\n' '[Unit]'
    printf '%s\n' 'Description=NetShape adaptive TCP and egress shaping'
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
  need_root "$@"
  take_lock
  [[ "$(uname -s)" == Linux ]] || die "仅支持 Linux"
  has ip || die "缺少 ip；请安装 iproute2"
  has tc || die "缺少 tc；请安装 iproute2"
  has sysctl || die "缺少 sysctl；请安装 procps"
  has systemctl || die "当前版本需要 systemd"
  mkdir -p "$STATE_DIR"
  if [[ -e "$INSTALL_FILE" && ! "$0" -ef "$INSTALL_FILE" ]]; then
    cp -a "$INSTALL_FILE" "$STATE_DIR/netshape-manager.previous"
  fi
  if [[ ! -e "$INSTALL_FILE" || ! "$0" -ef "$INSTALL_FILE" ]]; then
    install -m 0755 "$0" "$INSTALL_FILE"
  fi
  ln -sfn "$INSTALL_FILE" "$CLI_FILE"
  disable_known_conflicts
  write_service
  systemctl daemon-reload
  systemctl enable netshape-manager.service >/dev/null
  log "已安装命令与开机服务"
}

parse_install_args() {
  default_config
  local interactive=1 rtt_given=0
  shift
  while (( $# )); do
    case "$1" in
      --line) [[ $# -ge 2 ]] || die "--line 缺少值"; LINE_MBPS="$2"; shift 2 ;;
      --rtt) [[ $# -ge 2 ]] || die "--rtt 缺少值"; RTT_MS="$2"; rtt_given=1; shift 2 ;;
      --profile) [[ $# -ge 2 ]] || die "--profile 缺少值"; PROFILE="$2"; shift 2 ;;
      --rate) [[ $# -ge 2 ]] || die "--rate 缺少值"; RATE_MBPS="$2"; PROFILE=custom; shift 2 ;;
      --total) [[ $# -ge 2 ]] || die "--total 缺少值"; TOTAL_MBPS="$2"; shift 2 ;;
      --mode) [[ $# -ge 2 ]] || die "--mode 缺少值"; LIMIT_MODE="$2"; shift 2 ;;
      --iface) [[ $# -ge 2 ]] || die "--iface 缺少值"; IFACE="$2"; shift 2 ;;
      --role) [[ $# -ge 2 ]] || die "--role 缺少值"; ROLE="$2"; shift 2 ;;
      --origin-rtt) [[ $# -ge 2 ]] || die "--origin-rtt 缺少值"; ORIGIN_RTT_MS="$2"; shift 2 ;;
      --non-interactive) interactive=0; shift ;;
      *) die "未知安装参数：$1" ;;
    esac
  done
  if (( interactive == 1 )) && [[ -t 0 ]]; then install_menu; return; fi
  [[ "$ROLE" =~ ^(relay|landing)$ ]] || die "无效 --role（relay 或 landing）"
  is_uint "$ORIGIN_RTT_MS" && (( ORIGIN_RTT_MS >= 1 && ORIGIN_RTT_MS <= 3000 )) || die "无效 --origin-rtt"
  if [[ "$ROLE" == landing ]]; then
    is_uint "$TOTAL_MBPS" && (( TOTAL_MBPS == 0 || (TOTAL_MBPS >= 10 && TOTAL_MBPS <= 100000) )) \
      || die "无效 --total（0 表示不限制）"
    # A landing box sits next to its relay; 160ms is a cross-border default
    # that would badly misreport this machine.
    (( rtt_given == 0 )) && RTT_MS=5
    is_uint "$RTT_MS" && (( RTT_MS >= 1 && RTT_MS <= 3000 )) || die "无效 --rtt"
    need_root "$@"
    save_config
    install_files "$@"
    set_landing "$TOTAL_MBPS"
    write_nginx_snippet
    return
  fi
  is_uint "$LINE_MBPS" && (( LINE_MBPS >= 10 && LINE_MBPS <= 100000 )) || die "无效 --line"
  is_uint "$RTT_MS" && (( RTT_MS >= 1 && RTT_MS <= 3000 )) || die "无效 --rtt"
  [[ "$PROFILE" =~ ^(speed|balanced|stable|custom)$ ]] || die "无效 --profile"
  [[ "$LIMIT_MODE" =~ ^(adaptive|perflow|total|combo)$ ]] || die "无效 --mode"
  [[ "$IFACE" == auto || "$IFACE" =~ ^[a-zA-Z0-9_.:-]+$ ]] || die "无效 --iface"
  is_uint "$TOTAL_MBPS" && (( TOTAL_MBPS == 0 || (TOTAL_MBPS >= 10 && TOTAL_MBPS <= 100000) )) || die "无效 --total（0 表示不限制）"
  if [[ "$PROFILE" != custom ]]; then
    RATE_MBPS="$(recommended_rate "$LINE_MBPS" "$PROFILE")"
    LIMIT_MODE=combo
    SHAPER_MODE=auto
  fi
  is_uint "$RATE_MBPS" || die "无效 --rate"
  SHAPING=on
  need_root "$@"
  save_config
  install_files
  apply_all
  write_nginx_snippet
}

uninstall_all() {
  need_root "$@"
  take_lock
  load_config
  local iface
  iface="$(detect_iface)"; [[ "$IFACE" != auto ]] && iface="$IFACE"
  [[ -n "$iface" ]] && has tc && restore_baseline_qdisc "$iface"
  systemctl disable --now netshape-manager.service >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$SYSCTL_FILE" "$CONFIG_FILE" "$ROUTE_HOOK"
  [[ -L "$CLI_FILE" && "$(readlink "$CLI_FILE")" == "$INSTALL_FILE" ]] && rm -f "$CLI_FILE"
  rm -f "$INSTALL_FILE"
  systemctl daemon-reload 2>/dev/null || true
  # Load whatever other files remain first, then write the snapshot back on
  # top: sysctl --system alone leaves every tuned key live until reboot.
  has sysctl && sysctl --system >/dev/null 2>&1 || true
  has sysctl && restore_snapshot
  if [[ -n "$iface" ]] && has ip; then
    local spec
    spec="$(ip route show default 2>/dev/null | head -n 1)"
    if [[ "$spec" == *initcwnd* ]]; then
      local IFS=$' \t\n'
      # shellcheck disable=SC2086
      ip route replace $(printf '%s\n' "$spec" | sed -E 's/ initcwnd [0-9]+//g; s/ initrwnd [0-9]+//g') 2>/dev/null || true
    fi
  fi
  rm -f "$SNAPSHOT_FILE" "$STATE_DIR/baseline-qdisc"
  log "已卸载 NetShape；Nginx 片段和备份保留，避免破坏现有反代"
}

panel_iface() {
  local iface="${IFACE:-auto}"
  [[ "$iface" == auto ]] && iface="$(detect_iface)"
  printf '%s\n' "$iface"
}

render_landing_menu() {
  local total_text drift pct snippet
  if (( TOTAL_MBPS > 0 )); then
    total_text="整机 ≤ ${TOTAL_MBPS} Mbps"
  else
    total_text='不限（纯 fq 公平排队）'
  fi
  panel_title 'NetShape 落地鸡模式'
  if [[ "$SHAPING" == off ]]; then
    printf '  %b当前策略%b  %b已暂停人为限速%b\n' "$DIM" "$RESET" "$YELLOW" "$RESET"
  else
    printf '  %b当前策略%b  %b不限制单连接｜%s%b\n' "$DIM" "$RESET" "$GREEN" "$total_text" "$RESET"
  fi
  printf '  %b到中转机%b  %s ms\n' "$DIM" "$RESET" "$RTT_MS"
  printf '  %b回源参考%b  %s ms%b（决定接收缓冲，别按到中转机的延迟算）%b\n' "$DIM" "$RESET" "$ORIGIN_RTT_MS" "$DIM" "$RESET"
  printf '  %b队列模式%b  %s\n' "$DIM" "$RESET" "$(queue_label "$SHAPING" "$LIMIT_MODE" "$SHAPER_MODE")"
  pct="$(retrans_rate)"
  if [[ -n "$pct" ]]; then
    printf '  %b重传率%b    %s%%%b（自开机累计，实时判定按 8）%b\n' "$DIM" "$RESET" "$pct" "$DIM" "$RESET"
  fi
  drift="$(qdisc_drift "$(panel_iface)" "$SHAPING" "$LIMIT_MODE" "${SHAPER_MODE:-auto}" "$TOTAL_MBPS")"
  if [[ -n "$drift" ]]; then
    printf '  %b[!] 实际生效的队列是 %s，与上面的策略不一致%b\n' "$YELLOW" "$drift" "$RESET"
    printf '      %b可能被其他服务覆盖或重启后未应用，按 a 重新应用%b\n' "$DIM" "$RESET"
  fi
  snippet="$(nginx_snippet_state)"
  [[ "$snippet" == unlinked ]] && printf '  %b[!] Nginx 反代片段没有被任何站点 include，等于没生效%b\n' "$YELLOW" "$RESET"
  rule_light
  printf '  %b落地鸡调优%b  %b（同区域低延迟，无跨境限速器）%b\n' "$BOLD" "$RESET" "$DIM" "$RESET"
  printf '    %b1)%b 整机总出口上限%b（保护端口，当前：%s）%b\n' "$BOLD" "$RESET" "$DIM" "$total_text" "$RESET"
  printf '    %b2)%b 修改到中转机的延迟%b（当前：%s ms）%b\n' "$BOLD" "$RESET" "$DIM" "$RTT_MS" "$RESET"
  printf '    %b3)%b 修改回源延迟参考%b（当前：%s ms）%b\n' "$BOLD" "$RESET" "$DIM" "$ORIGIN_RTT_MS" "$RESET"
  printf '    %b4)%b 切回中转/观看模式%b（客户端在家宽另一端时用）%b\n' "$BOLD" "$RESET" "$DIM" "$RESET"
  printf '  %b查看与工具%b\n' "$BOLD" "$RESET"
  printf '    %b8)%b 状态与诊断（重传、冲突、Nginx 审计）\n' "$BOLD" "$RESET"
  printf '    %ba)%b 重新应用当前配置\n' "$BOLD" "$RESET"
  if [[ "$SHAPING" == off ]]; then
    printf '    %bp)%b %b恢复人为限速%b\n' "$BOLD" "$RESET" "$GREEN" "$RESET"
  else
    printf '    %bp)%b 暂停人为限速（保留 fq 公平排队）\n' "$BOLD" "$RESET"
  fi
  printf '    %b0)%b 退出\n' "$BOLD" "$RESET"
  rule_light
}

render_menu() {
  local current_text queue_text total_text drift pct snippet
  local m1=' ' m2=' ' m3=' ' m4=' ' m5=' ' m7=' '
  if (( TOTAL_MBPS > 0 )); then
    total_text="整机 ≤ ${TOTAL_MBPS} Mbps"
  else
    total_text='整机总出口不限'
  fi
  if [[ "$SHAPING" == off ]]; then
    current_text="${YELLOW}已暂停人为限速${RESET}（netshape apply 可恢复）"
  else
    case "$LIMIT_MODE" in
      adaptive) current_text='不限速自适应（无任何上限）' ;;
      perflow) current_text="单条连接 ≤ ${RATE_MBPS} Mbps" ;;
      total) current_text="整机总出口 ≤ ${RATE_MBPS} Mbps（旧模式）" ;;
      combo) current_text="单条连接 ≤ ${RATE_MBPS} Mbps｜${total_text}" ;;
    esac
    case "$LIMIT_MODE" in
      adaptive) m7='▸' ;;
      combo|perflow)
        case "$RATE_MBPS" in
          430) m1='▸' ;;
          450) m2='▸' ;;
          850) m3='▸' ;;
          900) m4='▸' ;;
          *) m5='▸' ;;
        esac
        ;;
    esac
  fi
  queue_text="$(queue_label "$SHAPING" "$LIMIT_MODE" "$SHAPER_MODE")"
  panel_title 'NetShape 网络调优面板'
  printf '  %b当前策略%b  %b%b%b\n' "$DIM" "$RESET" "$GREEN" "$current_text" "$RESET"
  printf '  %b延迟参考%b  %s ms\n' "$DIM" "$RESET" "$RTT_MS"
  printf '  %b队列模式%b  %s\n' "$DIM" "$RESET" "$queue_text"
  printf '  %b机器角色%b  %s%b（落地鸡请按 l 切换）%b\n' "$DIM" "$RESET" "$(role_short "${ROLE:-relay}")" "$DIM" "$RESET"
  pct="$(retrans_rate)"
  if [[ -n "$pct" ]]; then
    printf '  %b重传率%b    %s%%%b（自开机累计，实时判定按 8）%b\n' "$DIM" "$RESET" "$pct" "$DIM" "$RESET"
  fi
  drift="$(qdisc_drift "$(panel_iface)" "$SHAPING" "$LIMIT_MODE" "${SHAPER_MODE:-auto}" "$TOTAL_MBPS")"
  if [[ -n "$drift" ]]; then
    printf '  %b[!] 实际生效的队列是 %s，与上面的策略不一致%b\n' "$YELLOW" "$drift" "$RESET"
    printf '      %b可能被其他服务覆盖或重启后未应用，按 a 重新应用%b\n' "$DIM" "$RESET"
  fi
  snippet="$(nginx_snippet_state)"
  case "$snippet" in
    unlinked)
      printf '  %b[!] Nginx 反代片段没有被任何站点 include，等于没生效%b\n' "$YELLOW" "$RESET"
      printf '      %b这是反代掉速最常见的原因，按 8 查看修复方法%b\n' "$DIM" "$RESET"
      ;;
    missing)
      printf '  %b[!] 本机装了 Nginx 但未生成 Emby 片段：netshape nginx-snippet%b\n' "$YELLOW" "$RESET"
      ;;
  esac
  rule_light
  printf '  %b家宽档位（单条连接上限，多设备各自跑满）%b  %b▸ 当前%b\n' "$BOLD" "$RESET" "$DIM" "$RESET"
  printf '  %b%s%b %b1)%b 430 Mbps —— 500M 家宽·Emby 稳定（推荐）\n' "$GREEN" "$m1" "$RESET" "$BOLD" "$RESET"
  printf '  %b%s%b %b2)%b 450 Mbps —— 500M 家宽·速度优先\n' "$GREEN" "$m2" "$RESET" "$BOLD" "$RESET"
  printf '  %b%s%b %b3)%b 850 Mbps —— 1G 家宽·稳定\n' "$GREEN" "$m3" "$RESET" "$BOLD" "$RESET"
  printf '  %b%s%b %b4)%b 900 Mbps —— 1G 家宽·速度优先\n' "$GREEN" "$m4" "$RESET" "$BOLD" "$RESET"
  printf '  %b%s%b %b5)%b 自定义单条连接上限%b（当前：%s Mbps）%b\n' "$GREEN" "$m5" "$RESET" "$BOLD" "$RESET" "$DIM" "$RATE_MBPS" "$RESET"
  printf '    %b6)%b 修改整机总出口%b（按 VPS 端口，当前：%s）%b\n' "$BOLD" "$RESET" "$DIM" "$total_text" "$RESET"
  printf '  %b%s%b %b7)%b 不限速自适应%b（仅干净直连线路）%b\n' "$GREEN" "$m7" "$RESET" "$BOLD" "$RESET" "$DIM" "$RESET"
  printf '  %b查看与工具%b\n' "$BOLD" "$RESET"
  printf '    %b8)%b 状态与诊断（重传、冲突、Nginx 审计）\n' "$BOLD" "$RESET"
  printf '    %b9)%b 修改到本地的大致延迟\n' "$BOLD" "$RESET"
  printf '    %ba)%b 重新应用当前配置（队列被覆盖或重启后用）\n' "$BOLD" "$RESET"
  printf '    %bb)%b 切换整形突发模式%b（当前：%s，限速线路建议小突发）%b\n' "$BOLD" "$RESET" "$DIM" "$(burst_mode_short "${BURST_MODE:-policer}")" "$RESET"
  printf '    %bl)%b 切换为落地鸡模式%b（与中转机同区域、个位数延迟）%b\n' "$BOLD" "$RESET" "$DIM" "$RESET"
  if [[ "$SHAPING" == off ]]; then
    printf '    %bp)%b %b恢复人为限速%b\n' "$BOLD" "$RESET" "$GREEN" "$RESET"
  else
    printf '    %bp)%b 暂停人为限速（保留 fq 公平排队）\n' "$BOLD" "$RESET"
  fi
  printf '    %b0)%b 退出\n' "$BOLD" "$RESET"
  rule_light
}

pause_for_menu() {
  local discard
  [[ -t 0 ]] || return 0
  printf '\n'
  read -r -p "  $(printf '%b按回车返回菜单…%b' "$DIM" "$RESET")" discard || printf '\n'
}

# Panel actions run in a subshell so a failing action (which calls die) drops
# back to the menu instead of closing the whole panel. Every action persists
# through save_config, and the loop reloads it, so nothing is lost.
run_action() {
  ( "$@" ) || warn "操作未完成，已返回菜单"
}

menu() {
  [[ -t 0 ]] || { usage; return; }
  local answer value
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    warn "当前不是 root，面板为只读模式；要修改请运行：sudo netshape"
  fi
  while true; do
    load_config
    if [[ "$ROLE" == landing ]]; then
      render_landing_menu
      if ! read -r -p '  请选择 [0-4 / 8 / a / p]: ' answer; then
        printf '\n'
        return 0
      fi
      case "$answer" in
        1)
          if value="$(prompt_total_mbps)"; then
            run_action set_landing "$value"
          else
            info "已取消，保持当前策略"; continue
          fi
          ;;
        2)
          if value="$(prompt_uint '  到中转机的延迟（ms，同机房通常个位数，q 返回）' "$RTT_MS" 1 3000)"; then
            run_action set_rtt "$value"
          else
            info "已取消，保持当前策略"; continue
          fi
          ;;
        3)
          if value="$(prompt_uint '  回源延迟参考（ms，决定接收缓冲，q 返回）' "$ORIGIN_RTT_MS" 1 3000)"; then
            run_action set_origin_rtt "$value"
          else
            info "已取消，保持当前策略"; continue
          fi
          ;;
        4) run_action set_relay_role ;;
        8) run_action diagnose ;;
        a|A) run_action apply_all ;;
        p|P)
          if [[ "$SHAPING" == off ]]; then run_action set_resume; else run_action set_off; fi
          ;;
        0|q|Q) return 0 ;;
        *) warn "无效选项"; continue ;;
      esac
      pause_for_menu
      continue
    fi
    render_menu
    if ! read -r -p '  请选择 [0-9 / a / b / l / p]: ' answer; then
      printf '\n'
      return 0
    fi
    case "$answer" in
      1) run_action set_rate 430 ;;
      2) run_action set_rate 450 ;;
      3) run_action set_rate 850 ;;
      4) run_action set_rate 900 ;;
      5)
        if value="$(prompt_uint '  单条 TCP 连接上限（Mbps，q 返回）' "$RATE_MBPS" 10 100000)"; then
          run_action set_rate "$value"
        else
          info "已取消，保持当前策略"; continue
        fi
        ;;
      6)
        if value="$(prompt_total_mbps)"; then
          run_action set_total_rate "$value"
        else
          info "已取消，保持当前策略"; continue
        fi
        ;;
      7)
        if confirm_adaptive; then
          run_action set_adaptive
        else
          info "已取消，保持当前策略"; continue
        fi
        ;;
      8) run_action diagnose ;;
      9)
        if value="$(prompt_uint '  你本地连接这台 VPS 大约多少毫秒（q 返回）' "$RTT_MS" 1 3000)"; then
          run_action set_rtt "$value"
        else
          info "已取消，保持当前策略"; continue
        fi
        ;;
      a|A) run_action apply_all ;;
      l|L)
        if value="$(prompt_total_mbps)"; then
          run_action set_landing "$value"
        else
          info "已取消，保持当前策略"; continue
        fi
        ;;
      b|B)
        if [[ "${BURST_MODE:-policer}" == policer ]]; then
          run_action set_burst throughput
        else
          run_action set_burst policer
        fi
        ;;
      p|P)
        if [[ "$SHAPING" == off ]]; then run_action set_resume; else run_action set_off; fi
        ;;
      0|q|Q) return 0 ;;
      *) warn "无效选项"; continue ;;
    esac
    pause_for_menu
  done
}

usage() {
  cat <<'EOF'
NetShape Manager - 单连接上限 + 整机总出口 双层限速 SSH 面板

首次安装（进入安装面板，先选机器角色）：
  sudo bash netshape-manager.sh install

无人值守：
  中转/观看机  install --non-interactive --rate 430 --total 2300 --rtt 160
  落地鸡       install --non-interactive --role landing --total 0

安装后：
  netshape                 打开 SSH 交互面板
  netshape 430             单条连接 ≤430M（500M 家宽·Emby 稳定，推荐）
  netshape 450             单条连接 ≤450M（500M 家宽·速度优先）
  netshape 850             单条连接 ≤850M（1G 家宽·稳定）
  netshape 900             单条连接 ≤900M（1G 家宽·速度优先）
  netshape per-flow 600    同上，单条连接上限（rate 是它的别名）
  netshape total 2300      整机总出口（按 VPS 端口，0 = 不限制）
  netshape adaptive        不限速自适应（仅干净直连线路）
  netshape rtt 160         更新 RTT 并重算 TCP 缓冲
  netshape off             暂停限速，保留 fq
  netshape on              恢复限速（resume 同义）
  netshape apply           重新应用持久化配置
  netshape burst policer   小突发整形（默认，贴合限速线路）
  netshape burst throughput 大突发整形（10ms 令牌，仅干净直连线路）
  netshape initcwnd 32     初始拥塞窗口（0 = 不修改默认路由）
  netshape landing 0       切换为落地鸡模式（参数 = 整机总出口，0 = 不限）
  netshape relay           切回中转/观看模式
  netshape origin-rtt 150  落地鸡回源延迟参考（决定接收缓冲）
  netshape status          查看机器、TCP、qdisc、class 和重传
  netshape diagnose        检查重复 sysctl/旧服务并审计 Nginx
  netshape nginx-snippet   生成 Emby 不限流片段（本机自建反代时用）
  netshape nginx-audit     只读审计 Nginx 限速项
  netshape uninstall       卸载自身

机器角色：
  中转/观看机  客户端在家宽另一端、跨境线路：双层限速 + 小突发，压住重传。
  落地鸡       与中转机同区域、延迟个位数、没有跨境限速器：不限单连接，
               接收缓冲按「回源延迟」而不是到中转机的个位数延迟计算，
               端口范围/TIME_WAIT/conntrack/文件句柄按出口节点放大。

说明：两层限速各管一件事——
单连接上限压在观看设备家宽以下（500M→430/450，1G→850/900），
防止 BBR 单条流打爆"VPS 到家"的跨境路径（重传暴涨、断流的根源）；
整机总出口按 VPS 端口设置（2.5G→2300，1G→900），防止打满端口。
多设备同时使用时各自跑满自己的家宽，互不挤占。
EOF
}

main() {
  local command="${1:-menu}"
  case "$command" in
    install) parse_install_args "$@" ;;
    menu) menu ;;
    adaptive) set_adaptive ;;
    per-flow|rate) set_rate "${2:-}" ;;
    total) set_total_rate "${2:-}" ;;
    profile) set_profile "${2:-}" ;;
    line) set_line "${2:-}" ;;
    rtt) set_rtt "${2:-}" ;;
    off) set_off ;;
    on|resume) set_resume ;;
    burst) set_burst "${2:-}" ;;
    landing) set_landing "${2:-0}" ;;
    relay) set_relay_role ;;
    origin-rtt) set_origin_rtt "${2:-}" ;;
    initcwnd) set_initcwnd "${2:-}" ;;
    apply) apply_all ;;
    status) show_status ;;
    diagnose) diagnose ;;
    nginx-snippet) write_nginx_snippet ;;
    nginx-audit) nginx_audit ;;
    uninstall) uninstall_all ;;
    help|-h|--help) usage ;;
    version|--version) printf '%s %s\n' "$PROGRAM" "$VERSION" ;;
    *)
      # A bare number is the per-flow cap, matching `netshape 430` in the help.
      if is_uint "$command"; then set_rate "$command"; else die "未知命令：${command}（用 --help 查看帮助）"; fi
      ;;
  esac
}

if [[ "${NETSHAPE_LIB_ONLY:-0}" != 1 ]]; then
  main "$@"
fi
