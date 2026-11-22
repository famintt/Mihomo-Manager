#!/usr/bin/env bash
set -eEuo pipefail

umask 077

go_gc_requested() {
  [ "$(manager_env_or_setting "go_gc")" = "off" ] && return 0
  return 1
}

net_tune_requested() {
  case "$(manager_env_or_setting "net_tune")" in
  0 | off | no) return 1 ;;
  *) return 0 ;;
  esac
}

get_tcp_buffer_cap_mb() {
  local mem_kb
  mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)"
  if ! [[ "${mem_kb}" =~ ^[0-9]+$ ]]; then
    printf '%s' 64
  elif ((mem_kb < 524288)); then
    printf '%s' 16
  elif ((mem_kb < 1048576)); then
    printf '%s' 32
  else
    printf '%s' 64
  fi
}

calculate_net_tune_buffer_mb() {
  local bandwidth="$1" region="$2" cap_mb
  cap_mb="$(get_tcp_buffer_cap_mb)" || return 1
  [[ "${cap_mb}" =~ ^[1-9][0-9]{0,2}$ ]] && ((cap_mb <= 64)) || return 1
  local buffer_mb=16
  bandwidth="${bandwidth%.*}"
  if [[ "${bandwidth}" =~ ^[0-9]{1,8}$ ]]; then
    bandwidth="$((10#${bandwidth}))"
  else
    bandwidth=1000
  fi
  ((bandwidth > 0)) || bandwidth=1000
  if [ "${region}" = "overseas" ]; then
    if ((bandwidth < 500)); then
      buffer_mb=16
    elif ((bandwidth < 1000)); then
      buffer_mb=48
    else buffer_mb=64; fi
  else
    if ((bandwidth < 500)); then
      buffer_mb=8
    elif ((bandwidth < 1000)); then
      buffer_mb=12
    elif ((bandwidth < 2000)); then
      buffer_mb=16
    elif ((bandwidth < 5000)); then
      buffer_mb=24
    elif ((bandwidth < 10000)); then
      buffer_mb=28
    else buffer_mb=32; fi
  fi
  ((buffer_mb > cap_mb)) && buffer_mb="${cap_mb}"
  printf '%s' "${buffer_mb}"
}

# Only these two manager files are ours. A name alone is not ownership proof;
# retain symlinks, non-regular files and same-named files without our header.
net_tune_owned_file() {
  local file="$1" first
  [ -f "${file}" ] && [ ! -L "${file}" ] || return 1
  IFS= read -r first <"${file}" || return 1
  case "${first}" in '# mihomo-manager net_tune'* ) return 0 ;; *) return 1 ;; esac
}

net_tune_write_config() (
  local name="$1" dir="${SYSCTL_D_DIR:-/etc/sysctl.d}" target tmp
  case "${name}" in 99-mihomo-manager-net-tune.conf | 98-mihomo-manager-net-tune-extra.conf) ;; *) return 1 ;; esac
  [ -d "${dir}" ] && [ ! -L "${dir}" ] && [ -w "${dir}" ] || return 1
  target="${dir}/${name}"
  if [ -e "${target}" ] || [ -L "${target}" ]; then net_tune_owned_file "${target}" || return 1; fi
  tmp="$(mktemp "${dir}/.${name}.XXXXXX" 2>/dev/null)" || return 1
  trap 'rm -f -- "${tmp}"' EXIT
  cat >"${tmp}" && chmod 0644 "${tmp}" && mv -f -- "${tmp}" "${target}"
)

remove_net_tune() {
  local dir="${SYSCTL_D_DIR:-/etc/sysctl.d}" name file status=0
  [ -e "${dir}" ] || [ -L "${dir}" ] || return 0
  [ -d "${dir}" ] && [ ! -L "${dir}" ] || return 1
  for name in 99-mihomo-manager-net-tune.conf 98-mihomo-manager-net-tune-extra.conf; do
    file="${dir}/${name}"
    if [ -e "${file}" ] || [ -L "${file}" ]; then
      if net_tune_owned_file "${file}"; then
        rm -f -- "${file}" || status=1
      else
        print_warn "保留未经确认归本项目所有的调优文件：${file}"
        status=1
      fi
    fi
  done
  return "${status}"
}

apply_sysctls() {
  local buffer_bytes="$1" k v ok=true err=""
  [[ "${buffer_bytes}" =~ ^[1-9][0-9]{0,7}$ ]] && ((buffer_bytes <= 67108864)) || return 1
  local -a pairs=(
    net.core.rmem_max "${buffer_bytes}"
    net.core.wmem_max "${buffer_bytes}"
    net.core.default_qdisc fq
    net.ipv4.tcp_congestion_control bbr
    net.ipv4.tcp_rmem "4096 87380 ${buffer_bytes}"
    net.ipv4.tcp_wmem "4096 65536 ${buffer_bytes}"
    net.ipv4.tcp_limit_output_bytes 4194304
    net.ipv4.tcp_slow_start_after_idle 0
  )
  local i
  for ((i = 0; i < ${#pairs[@]}; i += 2)); do
    k="${pairs[i]}"
    v="${pairs[i + 1]}"
    if ! sysctl -w "${k}=${v}" >/dev/null 2>&1; then
      # 键不存在（精简内核）：无害，跳过；键存在但写入被拒：记失败
      if [ -n "$(sysctl -n "${k}" 2>/dev/null)" ]; then
        ok=false
        err="${err}${k} "
      fi
    fi
  done

  # 核心项写后回读校验（这些键所有常规内核均存在）
  [ "$(sysctl -n net.core.rmem_max 2>/dev/null)" = "${buffer_bytes}" ] || {
    ok=false
    err="${err}rmem_max "
  }
  [ "$(sysctl -n net.core.wmem_max 2>/dev/null)" = "${buffer_bytes}" ] || {
    ok=false
    err="${err}wmem_max "
  }
  [ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" = "fq" ] || {
    ok=false
    err="${err}default_qdisc "
  }
  [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ] || {
    ok=false
    err="${err}tcp_congestion_control "
  }
  [ "$(sysctl -n net.ipv4.tcp_limit_output_bytes 2>/dev/null)" = "4194304" ] || {
    ok=false
    err="${err}tcp_limit_output_bytes "
  }

  local persisted=false
  if [ "${ok}" = true ] && net_tune_write_config 99-mihomo-manager-net-tune.conf <<EOF
# mihomo-manager net_tune（重启后自动加载）
net.core.rmem_max=${buffer_bytes}
net.core.wmem_max=${buffer_bytes}
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_rmem=4096 87380 ${buffer_bytes}
net.ipv4.tcp_wmem=4096 65536 ${buffer_bytes}
net.ipv4.tcp_limit_output_bytes=4194304
net.ipv4.tcp_slow_start_after_idle=0
EOF
  then
    persisted=true
  fi

  if [ "${ok}" = "true" ]; then
    print_ok "已应用网络调优：BBR + fq + $((buffer_bytes / 1024 / 1024))MB 缓冲（tcp_limit_output_bytes=4MB、slow_start_after_idle=0）。"
    if [ "${persisted}" = true ]; then print_ok "已持久化网络调优。"; else print_warn "持久化目录不可写/不存在或文件归属未确认；仅对当前运行生效。"; fi
  else
    print_warn "net_tune：sysctl 写入/回读校验失败（${err}），可能容器或精简内核限制不可调。"
  fi
}

# 2.2/2.3/2.4/2.5：连接生命周期/并发/路径调优（默认值即最适，可整组由 net_tune=off 关闭）。
# 与核心缓冲项同套容错语义：键不存在（精简内核）跳过，存在但写失败才报 warn。
apply_sysctls_extra() {
  local k v ok=true err=""
  local -a pairs=(
    net.core.rmem_default 262144
    net.core.wmem_default 262144
    net.core.netdev_max_backlog 5000
    net.core.somaxconn 4096
    net.ipv4.tcp_notsent_lowat 16384
    net.ipv4.tcp_tw_reuse 1
    net.ipv4.ip_local_port_range "10000 65535"
    net.ipv4.tcp_max_syn_backlog 8192
    net.ipv4.tcp_mtu_probing 1
  )
  local i
  for ((i = 0; i < ${#pairs[@]}; i += 2)); do
    k="${pairs[i]}"
    v="${pairs[i + 1]}"
    if ! sysctl -w "${k}=${v}" >/dev/null 2>&1; then
      # 键不存在（精简内核）：无害，跳过；键存在但写入被拒：记失败
      if [ -n "$(sysctl -n "${k}" 2>/dev/null)" ]; then
        ok=false
        err="${err}${k} "
      fi
    fi
  done

  # 2.5：conntrack 上限仅在该子系统可用（存在且可写）时按内存档位抬升，防 NAT 表满丢新连接。
  local ct_max
  if [ -w /proc/sys/net/netfilter/nf_conntrack_max ]; then
    case "$(get_tcp_buffer_cap_mb)" in
    16) ct_max=131072 ;;
    32) ct_max=196608 ;;
    *) ct_max=262144 ;;
    esac
    if ! sysctl -w "net.netfilter.nf_conntrack_max=${ct_max}" >/dev/null 2>&1; then
      ok=false
      err="${err}nf_conntrack_max "
    fi
  fi

  local persisted=false
  if [ "${ok}" = true ] && {
    printf '%s\n' '# mihomo-manager net_tune：连接生命周期/并发/路径（重启后自动加载）'
    for ((i = 0; i < ${#pairs[@]}; i += 2)); do printf '%s=%s\n' "${pairs[i]}" "${pairs[i + 1]}"; done
    if [ -n "${ct_max:-}" ]; then printf '%s=%s\n' net.netfilter.nf_conntrack_max "${ct_max}"; fi
  } | net_tune_write_config 98-mihomo-manager-net-tune-extra.conf; then
    persisted=true
  fi

  if [ "${ok}" = "true" ]; then
    print_ok "已应用连接调优：背压/监听队列/端口区/发送低水位/MTU 探测${ct_max:+（conntrack=${ct_max}）}。"
    if [ "${persisted}" = true ]; then print_ok "已持久化连接调优。"; else print_warn "连接调优未持久化；目录不可写/不存在或文件归属未确认。"; fi
  else
    print_warn "连接调优部分项写入失败（${err}），已跳过受限项。"
  fi
}

apply_network_tune() {
  net_tune_requested || return 0
  [ "$(id -u 2>/dev/null || echo 1)" = 0 ] || return 0
  command_exists sysctl || return 0
  [ "${MM_TEST_MODE:-0}" != 1 ] || return 0
  local region bandwidth buffer_mb buffer_bytes cap_mb
  # Applying settings never performs a network probe or reads interactive input.
  # probe_net_tune is a separate explicit operation performed outside the lock.
  region="$(manager_env_or_setting net_tune_region '')" || return 1
  case "${region}" in asia | overseas) ;; *) region=asia ;; esac
  buffer_mb="$(get_setting net_tune_buffer_mb)" || return 1
  if ! [[ "${buffer_mb}" =~ ^[1-9][0-9]{0,2}$ ]] || ((buffer_mb > 64)); then
    bandwidth="$(manager_env_or_setting net_tune_bandwidth_mbps '')" || return 1
    if ! [[ "${bandwidth}" =~ ^[0-9]{1,8}(\.[0-9]+)?$ ]]; then
      bandwidth=1000
      print_info 'net_tune：未提供测量值，采用 1000Mbps 默认档位；可显式测速或手动指定。'
    fi
    buffer_mb="$(calculate_net_tune_buffer_mb "${bandwidth}" "${region}")" || return 1
    set_setting net_tune_bandwidth_mbps "${bandwidth}" || return 1
    set_setting net_tune_region "${region}" || return 1
    set_setting net_tune_buffer_mb "${buffer_mb}" || return 1
  fi
  cap_mb="$(get_tcp_buffer_cap_mb)" || return 1
  [[ "${buffer_mb}" =~ ^[1-9][0-9]{0,2}$ ]] && [[ "${cap_mb}" =~ ^[1-9][0-9]{0,2}$ ]] || return 1
  ((buffer_mb <= cap_mb)) || buffer_mb="${cap_mb}"
  buffer_bytes=$((buffer_mb * 1024 * 1024))
  apply_sysctls "${buffer_bytes}" || return 1
  apply_sysctls_extra
}
