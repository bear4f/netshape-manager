#!/usr/bin/env bash
# NetShape Manager - adaptive TCP/BBR and HTB+fq tuning for Linux relay hosts.
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="2.0.0"
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
BOLD='\033[1m'
RESET='\033[0m'

if [[ ! -t 1 || "${NO_COLOR:-}" ]]; then
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

log()  { printf '%b[OK]%b %s\n' "$GREEN" "$RESET" "$*"; }
info() { printf '%b[INFO]%b %s\n' "$BLUE" "$RESET" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%b[ERROR]%b %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行：sudo $0 $*"
}

has() { command -v "$1" >/dev/null 2>&1; }

is_uint() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

round_up_power_of_two() {
  local value="$1" result=1
  while (( result < value )); do result=$((result * 2)); done
  printf '%s\n' "$result"
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
  local rate="$1" rtt="$2" mem="$3" bdp target cap rounded
  # Mbps * ms * 125 = bytes in one bandwidth-delay product.
  bdp=$((rate * rtt * 125))
  target=$((bdp * 2))
  (( target < 8388608 )) && target=8388608
  rounded="$(round_up_power_of_two "$target")"
  cap="$(memory_buffer_cap "$mem")"
  (( rounded > cap )) && rounded="$cap"
  printf '%s\n' "$rounded"
}

calculate_htb_burst_kb() {
  local rate="$1" burst
  # Roughly 10ms worth of tokens; fq still paces individual TCP flows.
  burst=$(((rate * 1250 + 1023) / 1024))
  (( burst < 64 )) && burst=64
  (( burst > 2048 )) && burst=2048
  printf '%s\n' "$burst"
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
  PROFILE="balanced"
  RATE_MBPS=430
  SHAPING="on"
  IFACE="auto"
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
      SHAPING) [[ "$value" =~ ^(on|off)$ ]] && SHAPING="$value" ;;
      IFACE) [[ "$value" =~ ^[a-zA-Z0-9_.:-]+$ ]] && IFACE="$value" ;;
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
    printf 'SHAPING=%s\n' "$SHAPING"
    printf 'IFACE=%s\n' "$IFACE"
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
    warn "当前内核不支持 $key，已跳过"
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
  local mem tcp_max backlog notsent cc temp
  mem="$(mem_total_mb)"
  (( mem > 0 )) || mem=1024
  tcp_max="$(calculate_tcp_max "$RATE_MBPS" "$RTT_MS" "$mem")"
  if (( mem < 1024 )); then backlog=4096; else backlog=16384; fi
  if (( RTT_MS >= 120 )); then notsent=16384; else notsent=32768; fi
  has modprobe && modprobe sch_fq >/dev/null 2>&1 || true
  cc="$(choose_congestion_control)"

  mkdir -p "$(dirname "$SYSCTL_FILE")" "$STATE_DIR"
  temp="$(mktemp "${SYSCTL_FILE}.XXXXXX")"
  {
    printf '# Generated by NetShape Manager %s - do not hand edit.\n' "$VERSION"
    printf '# Inputs: line=%sMbps rate=%sMbps RTT=%sms RAM=%sMB\n\n' "$LINE_MBPS" "$RATE_MBPS" "$RTT_MS" "$mem"
  } > "$temp"

  append_sysctl "$temp" vm.swappiness 10
  append_sysctl "$temp" net.core.default_qdisc fq
  append_sysctl "$temp" net.ipv4.tcp_congestion_control "$cc"
  append_sysctl "$temp" net.core.somaxconn 4096
  append_sysctl "$temp" net.core.netdev_max_backlog "$backlog"
  append_sysctl "$temp" net.ipv4.tcp_max_syn_backlog 4096
  append_sysctl "$temp" net.ipv4.tcp_syncookies 1
  append_sysctl "$temp" net.ipv4.tcp_window_scaling 1
  append_sysctl "$temp" net.ipv4.tcp_sack 1
  append_sysctl "$temp" net.ipv4.tcp_dsack 1
  append_sysctl "$temp" net.ipv4.tcp_timestamps 1
  append_sysctl "$temp" net.ipv4.tcp_moderate_rcvbuf 1
  append_sysctl "$temp" net.core.rmem_default 262144
  append_sysctl "$temp" net.core.wmem_default 262144
  append_sysctl "$temp" net.core.rmem_max "$tcp_max"
  append_sysctl "$temp" net.core.wmem_max "$tcp_max"
  append_sysctl "$temp" net.core.optmem_max 4194304
  append_sysctl "$temp" net.ipv4.tcp_rmem "4096 262144 $tcp_max"
  append_sysctl "$temp" net.ipv4.tcp_wmem "4096 65536 $tcp_max"
  append_sysctl "$temp" net.ipv4.tcp_notsent_lowat "$notsent"
  append_sysctl "$temp" net.ipv4.tcp_mtu_probing 1
  append_sysctl "$temp" net.ipv4.tcp_slow_start_after_idle 0
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
  log "TCP 配置已更新：$cc，缓冲上限 $(format_bytes "$tcp_max")，notsent ${notsent}B"
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

apply_shape() {
  need_root "$@"
  has tc || die "缺少 tc；请先安装 iproute2"
  load_config
  local iface burst_kb
  iface="$(resolve_iface)"
  burst_kb="$(calculate_htb_burst_kb "$RATE_MBPS")"
  has modprobe && { modprobe sch_htb >/dev/null 2>&1 || true; modprobe sch_fq >/dev/null 2>&1 || true; }

  if [[ "$SHAPING" == off ]]; then
    restore_fq "$iface"
    log "已关闭总出口限速，并恢复 fq/fq_codel：$iface"
    return 0
  fi

  (( RATE_MBPS >= 10 && RATE_MBPS <= 100000 )) || die "无效限速：${RATE_MBPS}Mbps"
  info "正在应用 ${RATE_MBPS}Mbit 总出口保护：$iface"
  if ! tc qdisc replace dev "$iface" root handle 1: htb default 10 r2q 1000; then
    restore_fq "$iface"
    die "HTB 创建失败，已尝试恢复 fq"
  fi
  if ! tc class replace dev "$iface" parent 1: classid 1:10 htb rate "${RATE_MBPS}mbit" ceil "${RATE_MBPS}mbit" burst "${burst_kb}kb" cburst "${burst_kb}kb" quantum 15140; then
    restore_fq "$iface"
    die "HTB class 创建失败，已尝试恢复 fq"
  fi
  if ! tc qdisc replace dev "$iface" parent 1:10 handle 10: fq; then
    restore_fq "$iface"
    die "fq 子队列创建失败，已尝试恢复 fq"
  fi
  log "已应用 HTB + fq：${RATE_MBPS}Mbit（所有连接共享总上限，连接之间公平排队）"
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
  SHAPING="on"
  save_config
  apply_all
}

set_rate() {
  local rate="${1:-}"
  is_uint "$rate" || die "速率必须是整数 Mbps，例如 450 或 950"
  (( rate >= 10 && rate <= 100000 )) || die "速率范围为 10-100000 Mbps"
  need_root "$@"
  load_config
  RATE_MBPS="$rate"
  PROFILE="custom"
  SHAPING="on"
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
  is_uint "$line" || die "线路带宽必须是整数 Mbps，例如 500 或 1000"
  (( line >= 10 && line <= 100000 )) || die "线路带宽范围为 10-100000 Mbps"
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
    printf '%s\n' 'proxy_set_header Connection "upgrade";'
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
  info "该片段取消 Nginx 单请求限速；线路总出口仍由 NetShape 保护。"
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
  printf '%s\n' '=== 可能影响 Emby 的限速/超时指令 ==='
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

  printf '%bNetShape Manager %s%b\n' "$BOLD" "$VERSION" "$RESET"
  printf '  系统:      %s\n' "$(uname -srmo 2>/dev/null || uname -a)"
  printf '  CPU/RAM:   %s vCPU / %s MB RAM / %s MB Swap\n' "$(cpu_count)" "$mem" "$swap"
  printf '  网卡:      %s\n' "${iface:-未检测到}"
  printf '  线路/RTT:  %s Mbps / %s ms\n' "$LINE_MBPS" "$RTT_MS"
  printf '  档位:      %s\n' "$PROFILE"
  printf '  整形:      %s / %s Mbps\n' "$SHAPING" "$RATE_MBPS"
  printf '  TCP:       %s + %s / 缓冲建议 %s\n' "$cc" "$qdisc" "$(format_bytes "$tcp_max")"
  if [[ -n "$iface" ]] && has ip; then
    printf '  MTU:       %s\n' "$(ip -o link show dev "$iface" 2>/dev/null | sed -n 's/.* mtu \([0-9]*\).*/\1/p')"
  fi
  if [[ -n "$iface" ]] && has tc; then
    printf '\n=== qdisc ===\n'
    tc -s qdisc show dev "$iface" 2>/dev/null || true
    printf '\n=== class ===\n'
    tc -s class show dev "$iface" 2>/dev/null || true
  fi
  if has nstat; then
    printf '\n=== TCP 重传计数（累计）===\n'
    nstat -az 2>/dev/null | awk '$1 ~ /TcpRetransSegs|TcpExtTCPLostRetransmit|TcpExtTCPFastRetrans/ {print}' || true
  fi
}

diagnose() {
  show_status
  printf '\n=== 冲突检查 ===\n'
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
    for file in tc-fq-maxrate.service netpace.service; do
      systemctl is-enabled "$file" >/dev/null 2>&1 && printf '  可能冲突的服务：%s\n' "$file"
    done
  fi
  printf '\n提示：播放器断流还应同时检查源站负载、丢包、MTU、反代日志和客户端缓冲。\n'
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
  local mem swap suggested answer custom
  mem="$(mem_total_mb)"; swap="$(swap_total_mb)"
  printf '%bNetShape 自适应安装向导%b\n' "$BOLD" "$RESET"
  printf '检测到：%s vCPU，%s MB RAM，%s MB Swap，网卡 %s\n\n' "$(cpu_count)" "$mem" "$swap" "$(detect_iface)"
  LINE_MBPS="$(prompt_uint '线路标称带宽（Mbps）' 500 10 100000)"
  RTT_MS="$(prompt_uint '线路机到本地的往返延迟 RTT（ms）' 160 1 3000)"
  PROFILE="$(default_profile_for_rtt "$RTT_MS")"
  suggested="$(recommended_rate "$LINE_MBPS" "$PROFILE")"
  printf '按 RTT 推荐 %s 档，整机总出口 %s Mbps。\n' "$PROFILE" "$suggested"
  read -r -p "选择 [Enter=接受/s=速度/b=均衡/t=稳定/c=自定义]: " answer
  case "${answer:-accept}" in
    s|S|speed)
      PROFILE="speed"
      RATE_MBPS="$(recommended_rate "$LINE_MBPS" "$PROFILE")"
      ;;
    b|B|balanced)
      PROFILE="balanced"
      RATE_MBPS="$(recommended_rate "$LINE_MBPS" "$PROFILE")"
      ;;
    t|T|stable)
      PROFILE="stable"
      RATE_MBPS="$(recommended_rate "$LINE_MBPS" "$PROFILE")"
      ;;
    c|C)
      custom="$(prompt_uint '自定义总出口上限（Mbps）' "$suggested" 10 100000)"
      PROFILE="custom"
      RATE_MBPS="$custom"
      ;;
    *) RATE_MBPS="$suggested" ;;
  esac
  SHAPING="on"; IFACE="auto"
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
  for unit in tc-fq-maxrate.service netpace.service; do
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
      --iface) [[ $# -ge 2 ]] || die "--iface 缺少值"; IFACE="$2"; shift 2 ;;
      --non-interactive) interactive=0; shift ;;
      *) die "未知安装参数：$1" ;;
    esac
  done
  if (( interactive == 1 )) && [[ -t 0 ]]; then wizard; return; fi
  is_uint "$LINE_MBPS" && (( LINE_MBPS >= 10 && LINE_MBPS <= 100000 )) || die "无效 --line"
  is_uint "$RTT_MS" && (( RTT_MS >= 1 && RTT_MS <= 3000 )) || die "无效 --rtt"
  [[ "$PROFILE" =~ ^(speed|balanced|stable|custom)$ ]] || die "无效 --profile"
  [[ "$IFACE" == auto || "$IFACE" =~ ^[a-zA-Z0-9_.:-]+$ ]] || die "无效 --iface"
  if [[ "$PROFILE" != custom ]]; then RATE_MBPS="$(recommended_rate "$LINE_MBPS" "$PROFILE")"; fi
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

menu() {
  [[ -t 0 ]] || { usage; return; }
  while true; do
    load_config
    printf '\n%bNetShape SSH 交互面板%b\n' "$BOLD" "$RESET"
    printf '当前：线路 %sM / RTT %sms / %s / 限速 %sM\n' "$LINE_MBPS" "$RTT_MS" "$PROFILE" "$RATE_MBPS"
    printf '%s\n' \
      '  1) 自动重测参数（询问线路与 RTT）' \
      '  2) 速度档（500M→450M，1G→950M）' \
      '  3) 均衡档（500M→430M，1G→900M）' \
      '  4) 稳定档（500M→400M，1G→850M）' \
      '  5) 自定义整机总出口' \
      '  6) 查看状态与重传' \
      '  7) 诊断冲突' \
      '  8) Nginx/Emby 不限流片段与审计' \
      '  9) 暂停总出口限速' \
      '  0) 退出'
    read -r -p '请选择: ' answer
    case "$answer" in
      1) wizard ;;
      2) set_profile speed ;;
      3) set_profile balanced ;;
      4) set_profile stable ;;
      5) set_rate "$(prompt_uint '整机总出口上限（Mbps）' "$RATE_MBPS" 10 100000)" ;;
      6) show_status ;;
      7) diagnose ;;
      8) write_nginx_snippet; nginx_audit ;;
      9) set_off ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
  done
}

usage() {
  cat <<'EOF'
NetShape Manager - 自适应 TCP/BBR + HTB/fq SSH 面板

首次安装：
  sudo bash netshape-manager.sh install
  sudo bash netshape-manager.sh install --non-interactive --line 500 --rtt 160

安装后：
  netshape                 打开 SSH 交互面板
  netshape profile speed   500M→450M / 1G→950M
  netshape profile balanced
  netshape profile stable
  netshape rate 470        自定义总出口 Mbps，并同步 TCP 参数
  netshape line 1000       更新线路带宽并重算
  netshape rtt 160         更新 RTT 并重算
  netshape 450             rate 450 的简写
  netshape off             暂停 HTB，总出口恢复 fq
  netshape apply           重新应用持久化配置
  netshape status          查看机器、TCP、qdisc、class 和重传
  netshape diagnose        检查重复 sysctl/旧服务
  netshape nginx-snippet   生成 Emby 不限流片段
  netshape nginx-audit     只读审计 Nginx 限速项
  netshape uninstall       卸载自身

说明：Nginx 片段取消的是应用层单请求限速；HTB 仍保护整机总出口。
EOF
}

main() {
  local command="${1:-menu}"
  case "$command" in
    install) parse_install_args "$@" ;;
    menu) menu ;;
    profile) set_profile "${2:-}" ;;
    rate) set_rate "${2:-}" ;;
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
      if is_uint "$command"; then set_rate "$command"; else die "未知命令：$command（用 --help 查看帮助）"; fi
      ;;
  esac
}

if [[ "${NETSHAPE_LIB_ONLY:-0}" != 1 ]]; then
  main "$@"
fi
