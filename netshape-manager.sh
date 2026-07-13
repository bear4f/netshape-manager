#!/usr/bin/env bash
# NetShape Manager - adaptive TCP/BBR and HTB+fq tuning for Linux relay hosts.
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="5.1.0"
PROGRAM="netshape"
INSTALL_FILE="/usr/local/sbin/netshape-manager"
CLI_FILE="/usr/local/bin/netshape"
CONFIG_FILE="/etc/netshape-manager.conf"
SYSCTL_FILE="/etc/sysctl.d/99-zz-netshape-manager.conf"
SERVICE_FILE="/etc/systemd/system/netshape-manager.service"
STATE_DIR="/var/lib/netshape-manager"
NGINX_SNIPPET="/etc/nginx/snippets/netshape-emby-proxy.conf"

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

memory_buffer_cap() {
  local mem="$1"
  if (( mem < 512 )); then
    printf '%s\n' $((8 * 1024 * 1024))
  elif (( mem < 1024 )); then
    printf '%s\n' $((16 * 1024 * 1024))
  elif (( mem < 2048 )); then
    printf '%s\n' $((32 * 1024 * 1024))
  elif (( mem < 4096 )); then
    printf '%s\n' $((64 * 1024 * 1024))
  else
    printf '%s\n' $((128 * 1024 * 1024))
  fi
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

calculate_htb_burst_kb() {
  local rate="$1" burst
  # Roughly 10ms worth of tokens; fq still paces individual TCP flows.
  burst=$(((rate * 1250 + 1023) / 1024))
  (( burst < 64 )) && burst=64
  (( burst > 2048 )) && burst=2048
  printf '%s\n' "$burst"
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
    esac
  done < "$CONFIG_FILE"
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
  load_config
  local mem tcp_max backlog notsent cc temp min_free tcpmem
  mem="$(mem_total_mb)"
  (( mem > 0 )) || mem=1024
  tcp_max="$(calculate_tcp_max "$RATE_MBPS" "$RTT_MS" "$mem")"
  if (( mem < 1024 )); then backlog=4096; else backlog=16384; fi
  if (( mem < 1024 )); then min_free=32768; else min_free=65536; fi
  if (( RTT_MS >= 120 )); then notsent=16384; else notsent=32768; fi
  tcpmem="$(tcp_mem_values "$mem")"
  has modprobe && modprobe sch_fq >/dev/null 2>&1 || true
  cc="$(choose_congestion_control)"

  mkdir -p "$(dirname "$SYSCTL_FILE")" "$STATE_DIR"
  temp="$(mktemp "${SYSCTL_FILE}.XXXXXX")"
  {
    printf '# Generated by NetShape Manager %s - do not hand edit.\n' "$VERSION"
    printf '# Inputs: line=%sMbps rate=%sMbps RTT=%sms RAM=%sMB\n\n' "$LINE_MBPS" "$RATE_MBPS" "$RTT_MS" "$mem"
  } > "$temp"

  append_sysctl "$temp" vm.swappiness 10
  append_sysctl "$temp" vm.min_free_kbytes "$min_free"
  append_sysctl "$temp" kernel.panic 10
  append_sysctl "$temp" net.core.default_qdisc fq
  append_sysctl "$temp" net.ipv4.tcp_congestion_control "$cc"
  append_sysctl "$temp" net.core.somaxconn 2048
  append_sysctl "$temp" net.core.netdev_max_backlog "$backlog"
  append_sysctl "$temp" net.ipv4.tcp_max_syn_backlog 2048
  append_sysctl "$temp" net.ipv4.tcp_syncookies 1
  append_sysctl "$temp" net.ipv4.tcp_window_scaling 1
  append_sysctl "$temp" net.ipv4.tcp_sack 1
  append_sysctl "$temp" net.ipv4.tcp_dsack 1
  append_sysctl "$temp" net.ipv4.tcp_timestamps 1
  append_sysctl "$temp" net.ipv4.tcp_no_metrics_save 1
  append_sysctl "$temp" net.ipv4.tcp_moderate_rcvbuf 1
  append_sysctl "$temp" net.core.rmem_default 262144
  append_sysctl "$temp" net.core.wmem_default 262144
  append_sysctl "$temp" net.core.rmem_max "$tcp_max"
  append_sysctl "$temp" net.core.wmem_max "$tcp_max"
  append_sysctl "$temp" net.core.optmem_max 4194304
  # Modest defaults so video seeks do not burst; max grows via autotuning.
  append_sysctl "$temp" net.ipv4.tcp_rmem "4096 87380 $tcp_max"
  append_sysctl "$temp" net.ipv4.tcp_wmem "4096 65536 $tcp_max"
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

  chmod 0644 "$temp"
  mv -f "$temp" "$SYSCTL_FILE"

  if has sysctl; then
    sysctl -p "$SYSCTL_FILE" >/dev/null || die "sysctl 加载失败；配置文件保留在 $SYSCTL_FILE 供检查"
  fi
  log "TCP 配置已更新：${cc}，缓冲上限 $(format_bytes "$tcp_max")，notsent ${notsent}B"
  if (( tcp_max < RATE_MBPS * RTT_MS * 125 )); then
    warn "内存较小，TCP 缓冲上限低于单流 BDP；高 RTT 下单连接可能无法跑满线路"
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

restore_fq() {
  local iface="$1"
  tc qdisc del dev "$iface" root 2>/dev/null || true
  tc qdisc replace dev "$iface" root fq 2>/dev/null || \
    tc qdisc replace dev "$iface" root fq_codel 2>/dev/null || true
}

try_cake() {
  # dual-dsthost: fair share per destination device first, then per flow,
  # so one device's multi-connection download cannot starve another's stream.
  local iface="$1" rate="$2" error_file="$3"
  tc qdisc del dev "$iface" root 2>/dev/null || true
  tc qdisc add dev "$iface" root cake bandwidth "${rate}mbit" besteffort dual-dsthost 2> "$error_file" || return 1
}

try_htb_fq() {
  local iface="$1" rate="$2" burst_kb="$3" error_file="$4" maxrate="${5:-}"
  tc qdisc del dev "$iface" root 2>/dev/null || true
  tc qdisc add dev "$iface" root handle 1: htb default 10 r2q 1000 2> "$error_file" || return 1
  tc class add dev "$iface" parent 1: classid 1:10 htb rate "${rate}mbit" ceil "${rate}mbit" burst "${burst_kb}kb" cburst "${burst_kb}kb" quantum 15140 2>> "$error_file" || return 1
  if [[ -n "$maxrate" ]]; then
    tc qdisc add dev "$iface" parent 1:10 handle 10: fq maxrate "${maxrate}mbit" 2>> "$error_file" || return 1
  else
    tc qdisc add dev "$iface" parent 1:10 handle 10: fq 2>> "$error_file" || return 1
  fi
}

try_tbf_fq() {
  local iface="$1" rate="$2" burst_kb="$3" error_file="$4" maxrate="${5:-}"
  tc qdisc del dev "$iface" root 2>/dev/null || true
  tc qdisc add dev "$iface" root handle 1: tbf rate "${rate}mbit" burst "${burst_kb}kb" latency 50ms 2> "$error_file" || return 1
  if [[ -n "$maxrate" ]]; then
    tc qdisc add dev "$iface" parent 1:1 handle 10: fq maxrate "${maxrate}mbit" 2>> "$error_file" || return 1
  else
    tc qdisc add dev "$iface" parent 1:1 handle 10: fq 2>> "$error_file" || return 1
  fi
}

try_fq_maxrate() {
  local iface="$1" rate="$2" error_file="$3"
  tc qdisc del dev "$iface" root 2>/dev/null || true
  tc qdisc add dev "$iface" root fq maxrate "${rate}mbit" 2> "$error_file" || return 1
}

apply_shape() {
  need_root "$@"
  has tc || die "缺少 tc；请先安装 iproute2"
  load_config
  local iface burst_kb requested_mode selected_mode='' error_file detail
  iface="$(resolve_iface)"
  burst_kb="$(calculate_htb_burst_kb "$RATE_MBPS")"
  requested_mode="$SHAPER_MODE"
  has modprobe && {
    modprobe sch_cake >/dev/null 2>&1 || true
    modprobe sch_htb >/dev/null 2>&1 || true
    modprobe sch_tbf >/dev/null 2>&1 || true
    modprobe sch_fq >/dev/null 2>&1 || true
  }

  if [[ "$SHAPING" == off ]]; then
    restore_fq "$iface"
    log "已取消人为限速，并恢复连接公平排队：$iface"
    return 0
  fi

  (( RATE_MBPS >= 10 && RATE_MBPS <= 100000 )) || die "无效限速：${RATE_MBPS}Mbps"

  if [[ "$LIMIT_MODE" == adaptive ]]; then
    restore_fq "$iface"
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
      if try_fq_maxrate "$iface" "$RATE_MBPS" "$error_file"; then
        SHAPER_MODE=fq
        save_config
        rm -f "$error_file"
        log "已启用 fq maxrate：每条连接 ≤ ${RATE_MBPS} Mbps，多设备各自跑满自己的家宽"
        return 0
      fi
      detail="$(tail -n 1 "$error_file" 2>/dev/null || true)"
      rm -f "$error_file"
      restore_fq "$iface"
      die "当前 VPS 不支持单连接限速，已恢复不限速 fq。${detail:+ 内核返回：$detail}"
    fi
    burst_kb="$(calculate_htb_burst_kb "$TOTAL_MBPS")"
    info "正在设置：单条连接 ≤ ${RATE_MBPS} Mbps ＋ 整机总出口 ≤ ${TOTAL_MBPS} Mbps（网卡 ${iface}）"
    if [[ "$requested_mode" == auto || "$requested_mode" == cake || "$requested_mode" == htb ]] \
      && try_htb_fq "$iface" "$TOTAL_MBPS" "$burst_kb" "$error_file" "$RATE_MBPS"; then
      selected_mode=htb
    elif [[ "$requested_mode" != fq ]] \
      && try_tbf_fq "$iface" "$TOTAL_MBPS" "$burst_kb" "$error_file" "$RATE_MBPS"; then
      selected_mode=tbf
    elif try_fq_maxrate "$iface" "$RATE_MBPS" "$error_file"; then
      selected_mode=fq
      warn "本机不支持总出口限速，已只保留单连接上限"
    else
      detail="$(tail -n 1 "$error_file" 2>/dev/null || true)"
      rm -f "$error_file"
      restore_fq "$iface"
      die "当前 VPS 不支持限速队列，已恢复不限速 fq。${detail:+ 内核返回：$detail}"
    fi
    SHAPER_MODE="$selected_mode"
    save_config
    rm -f "$error_file"
    case "$selected_mode" in
      htb) log "已启用 HTB + fq maxrate：单条连接 ≤ ${RATE_MBPS} Mbps，整机合计 ≤ ${TOTAL_MBPS} Mbps" ;;
      tbf) log "已启用 TBF + fq maxrate（兼容）：单条连接 ≤ ${RATE_MBPS} Mbps，整机合计 ≤ ${TOTAL_MBPS} Mbps" ;;
      fq) log "已启用 fq maxrate：每条连接 ≤ ${RATE_MBPS} Mbps（无总上限）" ;;
    esac
    return 0
  fi

  if [[ "$LIMIT_MODE" == perflow ]]; then
    info "正在设置单条 TCP 连接上限：${RATE_MBPS} Mbps（不会限制所有设备合计速度）"
    if try_fq_maxrate "$iface" "$RATE_MBPS" "$error_file"; then
      SHAPER_MODE=fq
      save_config
      rm -f "$error_file"
      log "已启用 fq maxrate：每条 TCP 连接最多 ${RATE_MBPS} Mbps，多设备可同时使用"
      return 0
    fi
    detail="$(tail -n 1 "$error_file" 2>/dev/null || true)"
    rm -f "$error_file"
    restore_fq "$iface"
    die "当前 VPS 不支持单连接限速，已恢复不限速 fq。${detail:+ 内核返回：$detail}"
  fi

  info "正在设置整机总出口上限 ${RATE_MBPS} Mbps（CAKE/HTB/TBF，网卡 ${iface}）"

  if [[ "$requested_mode" == auto || "$requested_mode" == cake ]]; then
    if try_cake "$iface" "$RATE_MBPS" "$error_file"; then
      selected_mode=cake
    fi
  fi

  if [[ -z "$selected_mode" && ( "$requested_mode" == auto || "$requested_mode" == cake || "$requested_mode" == htb ) ]]; then
    if try_htb_fq "$iface" "$RATE_MBPS" "$burst_kb" "$error_file"; then
      selected_mode=htb
    fi
  fi

  if [[ -z "$selected_mode" && "$requested_mode" != fq ]]; then
    if try_tbf_fq "$iface" "$RATE_MBPS" "$burst_kb" "$error_file"; then
      selected_mode=tbf
    fi
  fi

  if [[ -z "$selected_mode" ]]; then
    detail="$(tail -n 1 "$error_file" 2>/dev/null || true)"
    rm -f "$error_file"
    restore_fq "$iface"
    die "当前 VPS 不支持整机合计限速，已恢复不限速 fq。${detail:+ 内核返回：$detail}"
  fi
  rm -f "$error_file"

  if [[ "$selected_mode" != "$requested_mode" ]]; then
    SHAPER_MODE="$selected_mode"
    save_config
  fi

  case "$selected_mode" in
    cake) log "已启用 CAKE：总出口 ${RATE_MBPS} Mbps，各设备先均分带宽，单设备多连接不会挤占其他设备" ;;
    htb) log "已启用 HTB + fq：整台机器所有连接合计不超过 ${RATE_MBPS} Mbps（按连接公平）" ;;
    tbf)
      warn "本机不支持 CAKE 和 HTB，已自动切换到兼容模式 TBF + fq"
      log "整台机器所有连接合计不超过 ${RATE_MBPS} Mbps"
      ;;
  esac
}

apply_all() {
  write_sysctl_profile
  apply_shape
}

set_profile() {
  local profile="${1:-}"
  [[ "$profile" =~ ^(speed|balanced|stable)$ ]] || die "档位必须是 speed、balanced 或 stable"
  need_root "$@"
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
  load_config
  TOTAL_MBPS="$rate"
  LIMIT_MODE="combo"
  SHAPING="on"
  SHAPER_MODE="auto"
  save_config
  apply_all
}

set_rtt() {
  local rtt="${1:-}"
  is_uint "$rtt" || die "RTT 必须是整数毫秒，例如 160"
  (( rtt >= 1 && rtt <= 3000 )) || die "RTT 范围为 1-3000ms"
  need_root "$@"
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
  load_config
  SHAPING="off"
  save_config
  apply_shape
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
  rm -f "$output"
  info "审计仅报告，不会改动现有站点配置。"
}

show_status() {
  load_config
  local iface mem swap tcp_max cc qdisc
  iface="$(detect_iface)"
  [[ "$IFACE" != auto ]] && iface="$IFACE"
  mem="$(mem_total_mb)"; swap="$(swap_total_mb)"
  tcp_max="$(calculate_tcp_max "$RATE_MBPS" "$RTT_MS" "${mem:-1024}")"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'unknown')"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || printf 'unknown')"

  panel_title 'NetShape 状态'
  printf '  系统:      %s\n' "$(uname -srmo 2>/dev/null || uname -a)"
  printf '  CPU/RAM:   %s vCPU / %s MB RAM / %s MB Swap\n' "$(cpu_count)" "$mem" "$swap"
  printf '  网卡:      %s\n' "${iface:-未检测到}"
  printf '  延迟参考:  %s ms\n' "$RTT_MS"
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
    printf '\n%b▸ TCP 重传计数（累计）%b\n' "$BOLD" "$RESET"
    nstat -az 2>/dev/null | awk '$1 ~ /TcpRetransSegs|TcpExtTCPLostRetransmit|TcpExtTCPFastRetrans/ {print}' || true
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
  read -r -p '不限速模式在跨境/共享线路上会大量重传甚至断流，确定使用？[y/N]: ' reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

prompt_uint() {
  local prompt="$1" default="$2" min="$3" max="$4" value
  while true; do
    read -r -p "$prompt [$default]: " value
    value="${value:-$default}"
    if is_uint "$value" && (( value >= min && value <= max )); then
      printf '%s\n' "$value"
      return
    fi
    warn "请输入 $min-$max 之间的整数"
  done
}

wizard() {
  need_root "$@"
  [[ -t 0 ]] || die "交互向导需要终端；自动安装请使用 install --line 500 --rtt 160"
  local mem swap answer custom
  mem="$(mem_total_mb)"; swap="$(swap_total_mb)"
  panel_title 'NetShape 安装向导'
  printf '  检测到：%s vCPU｜%s MB 内存｜%s MB Swap｜网卡 %s\n\n' "$(cpu_count)" "$mem" "$swap" "$(detect_iface)"
  RTT_MS="$(prompt_uint '你本地连接这台 VPS 大约多少毫秒（不知道直接回车）' 160 1 3000)"
  printf '%s\n' \
    '' \
    '这台 VPS 的端口/线路有多大？（决定整机总出口保护，防止打满端口）' \
    '  1) 2.5G 口：总出口 2300 Mbps' \
    '  2) 1G 口：总出口 900 Mbps' \
    '  3) 500M 口：总出口 450 Mbps' \
    '  4) 不知道/不限制总出口' \
    '  5) 自定义'
  read -r -p '请选择 [1]: ' answer
  case "${answer:-1}" in
    1) TOTAL_MBPS=2300 ;;
    2) TOTAL_MBPS=900 ;;
    3) TOTAL_MBPS=450 ;;
    4) TOTAL_MBPS=0 ;;
    5) TOTAL_MBPS="$(prompt_uint '整机总出口上限（Mbps，0 表示不限）' 2300 0 100000)" ;;
    *) die "无效选项" ;;
  esac
  printf '%s\n' \
    '' \
    '观看设备的家宽档位？（单条 TCP 连接上限，防止单条流打爆到家的路径）' \
    '  1) 500M 家宽：单连接 430 Mbps（Emby 稳定，推荐）' \
    '  2) 500M 家宽：单连接 450 Mbps（速度优先）' \
    '  3) 1G 家宽：单连接 850 Mbps（稳定）' \
    '  4) 1G 家宽：单连接 900 Mbps（速度优先）' \
    '  5) 自定义单连接上限' \
    '  6) 不限速自适应（仅干净直连线路，跨境线路易大量重传）'
  read -r -p '请选择 [1]: ' answer
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
      custom="$(prompt_uint '单条 TCP 连接上限（Mbps）' 430 10 100000)"
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
  local interactive=1
  shift
  while (( $# )); do
    case "$1" in
      --line) [[ $# -ge 2 ]] || die "--line 缺少值"; LINE_MBPS="$2"; shift 2 ;;
      --rtt) [[ $# -ge 2 ]] || die "--rtt 缺少值"; RTT_MS="$2"; shift 2 ;;
      --profile) [[ $# -ge 2 ]] || die "--profile 缺少值"; PROFILE="$2"; shift 2 ;;
      --rate) [[ $# -ge 2 ]] || die "--rate 缺少值"; RATE_MBPS="$2"; PROFILE=custom; shift 2 ;;
      --total) [[ $# -ge 2 ]] || die "--total 缺少值"; TOTAL_MBPS="$2"; shift 2 ;;
      --mode) [[ $# -ge 2 ]] || die "--mode 缺少值"; LIMIT_MODE="$2"; shift 2 ;;
      --iface) [[ $# -ge 2 ]] || die "--iface 缺少值"; IFACE="$2"; shift 2 ;;
      --non-interactive) interactive=0; shift ;;
      *) die "未知安装参数：$1" ;;
    esac
  done
  if (( interactive == 1 )) && [[ -t 0 ]]; then wizard; return; fi
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
  load_config
  local iface
  iface="$(detect_iface)"; [[ "$IFACE" != auto ]] && iface="$IFACE"
  [[ -n "$iface" ]] && has tc && restore_fq "$iface"
  systemctl disable --now netshape-manager.service >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$SYSCTL_FILE" "$CONFIG_FILE"
  [[ -L "$CLI_FILE" && "$(readlink "$CLI_FILE")" == "$INSTALL_FILE" ]] && rm -f "$CLI_FILE"
  rm -f "$INSTALL_FILE"
  systemctl daemon-reload 2>/dev/null || true
  has sysctl && sysctl --system >/dev/null 2>&1 || true
  log "已卸载 NetShape；Nginx 片段和备份保留，避免破坏现有反代"
}

render_menu() {
  local current_text queue_text total_text
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
  printf '    %b0)%b 退出\n' "$BOLD" "$RESET"
  rule_light
}

menu() {
  [[ -t 0 ]] || { usage; return; }
  local answer
  while true; do
    load_config
    render_menu
    read -r -p '  请选择 [0-9]: ' answer
    case "$answer" in
      1) set_rate 430 ;;
      2) set_rate 450 ;;
      3) set_rate 850 ;;
      4) set_rate 900 ;;
      5) set_rate "$(prompt_uint '单条 TCP 连接上限（Mbps）' "$RATE_MBPS" 10 100000)" ;;
      6) set_total_rate "$(prompt_uint '整机总出口上限（Mbps，0 表示不限）' "$TOTAL_MBPS" 0 100000)" ;;
      7) if confirm_adaptive; then set_adaptive; else warn "已取消，保持当前策略"; fi ;;
      8) diagnose ;;
      9) set_rtt "$(prompt_uint '你本地连接这台 VPS 大约多少毫秒' "$RTT_MS" 1 3000)" ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
  done
}

usage() {
  cat <<'EOF'
NetShape Manager - 单连接上限 + 整机总出口 双层限速 SSH 面板

首次安装：
  sudo bash netshape-manager.sh install
  sudo bash netshape-manager.sh install --non-interactive --rate 430 --total 2300 --rtt 160

安装后：
  netshape                 打开 SSH 交互面板
  netshape 430             单条连接 ≤430M（500M 家宽·Emby 稳定，推荐）
  netshape 450             单条连接 ≤450M（500M 家宽·速度优先）
  netshape 850             单条连接 ≤850M（1G 家宽·稳定）
  netshape 900             单条连接 ≤900M（1G 家宽·速度优先）
  netshape total 2300      整机总出口（按 VPS 端口，0 = 不限制）
  netshape adaptive        不限速自适应（仅干净直连线路）
  netshape rtt 160         更新 RTT 并重算 TCP 缓冲
  netshape off             暂停限速，保留 fq
  netshape apply           重新应用持久化配置
  netshape status          查看机器、TCP、qdisc、class 和重传
  netshape diagnose        检查重复 sysctl/旧服务并审计 Nginx
  netshape nginx-snippet   生成 Emby 不限流片段（本机自建反代时用）
  netshape nginx-audit     只读审计 Nginx 限速项
  netshape uninstall       卸载自身

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
    per-flow) set_rate "${2:-}" ;;
    total) set_total_rate "${2:-}" ;;
    profile) set_profile "${2:-}" ;;
    rate) set_total_rate "${2:-}" ;;
    line) set_line "${2:-}" ;;
    rtt) set_rtt "${2:-}" ;;
    off) set_off ;;
    apply) apply_all ;;
    status) show_status ;;
    diagnose) diagnose ;;
    nginx-snippet) write_nginx_snippet ;;
    nginx-audit) nginx_audit ;;
    uninstall) uninstall_all ;;
    help|-h|--help) usage ;;
    version|--version) printf '%s %s\n' "$PROGRAM" "$VERSION" ;;
    *)
      if is_uint "$command"; then set_total_rate "$command"; else die "未知命令：${command}（用 --help 查看帮助）"; fi
      ;;
  esac
}

if [[ "${NETSHAPE_LIB_ONLY:-0}" != 1 ]]; then
  main "$@"
fi
