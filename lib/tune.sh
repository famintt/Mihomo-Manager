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
  if [[ "${NET_TUNE_MEM_KB:-}" =~ ^[0-9]+$ ]] && [ "${NET_TUNE_MEM_KB}" -gt 0 ]; then
    mem_kb="${NET_TUNE_MEM_KB}"
  else
    mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)"
  fi
  if ! [[ "${mem_kb}" =~ ^[0-9]+$ ]]; then
    printf '%s' 32
  elif ((mem_kb < 262144)); then
    printf '%s' 16
  else
    printf '%s' 32
  fi
}

# 兼容旧调用签名：统一标准不再按带宽/地区分档，只看内存。
calculate_net_tune_buffer_mb() {
  printf '%s' "$(get_tcp_buffer_cap_mb)"
}

manager_tcp_mem_pages() {
  local mem_kb page_size pages max_pages cap_pages floor_pages low pressure
  if [[ "${NET_TUNE_MEM_KB:-}" =~ ^[0-9]+$ ]] && [ "${NET_TUNE_MEM_KB}" -gt 0 ]; then
    mem_kb="${NET_TUNE_MEM_KB}"
  else
    mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)"
  fi
  [[ "${mem_kb}" =~ ^[0-9]+$ ]] && [ "${mem_kb}" -gt 0 ] || mem_kb=262144
  page_size="$(getconf PAGESIZE 2>/dev/null || printf '4096')"
  [[ "${page_size}" =~ ^[0-9]+$ ]] && [ "${page_size}" -gt 0 ] || page_size=4096
  pages=$((mem_kb * 1024 / page_size))
  [ "${pages}" -gt 0 ] || pages=262144
  max_pages=$((pages / 4))
  cap_pages=$((134217728 / page_size))
  floor_pages=$((16 * 1024 * 1024 / page_size))
  [ "${max_pages}" -gt "${cap_pages}" ] && max_pages="${cap_pages}"
  [ "${max_pages}" -lt "${floor_pages}" ] && max_pages="${floor_pages}"
  low=$((max_pages / 4))
  pressure=$((max_pages / 2))
  [ "${low}" -lt 1 ] && low=1
  [ "${pressure}" -le "${low}" ] && pressure=$((low + 1))
  printf '%s %s %s' "${low}" "${pressure}" "${max_pages}"
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
  local buffer_bytes="$1" k v ok=true err="" tcp_mem
  [[ "${buffer_bytes}" =~ ^[1-9][0-9]{0,7}$ ]] && ((buffer_bytes <= 67108864)) || return 1
  tcp_mem="$(manager_tcp_mem_pages)"
  local -a pairs=(
    net.core.rmem_max "${buffer_bytes}"
    net.core.wmem_max "${buffer_bytes}"
    net.core.rmem_default 262144
    net.core.wmem_default 262144
    net.ipv4.tcp_congestion_control bbr
    net.ipv4.tcp_rmem "4096 262144 ${buffer_bytes}"
    net.ipv4.tcp_wmem "4096 262144 ${buffer_bytes}"
    net.ipv4.tcp_mem "${tcp_mem}"
    net.ipv4.tcp_limit_output_bytes 4194304
    net.ipv4.tcp_slow_start_after_idle 0
    net.core.netdev_max_backlog 8192
    net.core.somaxconn 4096
    net.ipv4.tcp_max_syn_backlog 8192
    net.ipv4.tcp_fastopen 3
    net.ipv4.tcp_mtu_probing 1
    net.ipv4.tcp_tw_reuse 1
    net.ipv4.ip_local_port_range "10000 65535"
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

  # default_qdisc 在部分容器/精简内核中不存在，存在时才写入并校验。
  if [ -e /proc/sys/net/core/default_qdisc ]; then
    if ! sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then
      ok=false
      err="${err}default_qdisc "
    fi
  fi

  # 核心项写后回读校验（这些键所有常规内核均存在）
  [ "$(sysctl -n net.core.rmem_max 2>/dev/null)" = "${buffer_bytes}" ] || {
    ok=false
    err="${err}rmem_max "
  }
  [ "$(sysctl -n net.core.wmem_max 2>/dev/null)" = "${buffer_bytes}" ] || {
    ok=false
    err="${err}wmem_max "
  }
  if [ -e /proc/sys/net/core/default_qdisc ]; then
    [ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" = "fq" ] || {
      ok=false
      err="${err}default_qdisc "
    }
  fi
  [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ] || {
    ok=false
    err="${err}tcp_congestion_control "
  }
  [ "$(sysctl -n net.ipv4.tcp_limit_output_bytes 2>/dev/null)" = "4194304" ] || {
    ok=false
    err="${err}tcp_limit_output_bytes "
  }
  [ "$(sysctl -n net.ipv4.tcp_mem 2>/dev/null)" = "${tcp_mem}" ] || {
    ok=false
    err="${err}tcp_mem "
  }

  local persisted=false
  if [ "${ok}" = true ] && net_tune_write_config 99-mihomo-manager-net-tune.conf <<EOF
# mihomo-manager net_tune：统一标准（内存档位 + tcp_mem + 连接参数），重启后自动加载
net.core.rmem_max=${buffer_bytes}
net.core.wmem_max=${buffer_bytes}
net.core.rmem_default=262144
net.core.wmem_default=262144
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_rmem=4096 262144 ${buffer_bytes}
net.ipv4.tcp_wmem=4096 262144 ${buffer_bytes}
net.ipv4.tcp_mem=${tcp_mem}
net.ipv4.tcp_limit_output_bytes=4194304
net.ipv4.tcp_slow_start_after_idle=0
net.core.netdev_max_backlog=8192
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=10000 65535
EOF
  then
    persisted=true
  fi

  if [ "${ok}" = "true" ]; then
    print_ok "已应用统一网络调优：BBR + fq + TCP 缓冲 $((buffer_bytes / 1024 / 1024))MB（tcp_mem=${tcp_mem}、limit_output=4MB、slow_start_after_idle=0）。"
    if [ "${persisted}" = true ]; then print_ok "已持久化网络调优。"; else print_warn "持久化目录不可写/不存在或文件归属未确认；仅对当前运行生效。"; fi
  else
    print_warn "net_tune：sysctl 写入/回读校验失败（${err}），可能容器或精简内核限制不可调。"
  fi
}

# 2.2/2.3/2.4/2.5：连接生命周期/并发/路径调优（默认值即最适，可整组由 net_tune=off 关闭）。
# 与核心缓冲项同套容错语义：键不存在（精简内核）跳过，存在但写失败才报 warn。
apply_sysctls_extra() {
  local ct_max
  # 连接/路径参数已并入 apply_sysctls 的统一 99- 文件；这里只处理 conntrack。
  if [ -w /proc/sys/net/netfilter/nf_conntrack_max ]; then
    case "$(get_tcp_buffer_cap_mb)" in
    16) ct_max=131072 ;;
    *) ct_max=196608 ;;
    esac
    if sysctl -w "net.netfilter.nf_conntrack_max=${ct_max}" >/dev/null 2>&1; then
      print_ok "已应用 conntrack 上限：${ct_max}。"
    else
      print_warn "conntrack 上限写入失败，已跳过。"
    fi
  fi
  rm -f /etc/sysctl.d/98-mihomo-manager-net-tune-extra.conf 2>/dev/null || true
}

apply_network_tune() {
  net_tune_requested || return 0
  [ "$(id -u 2>/dev/null || echo 1)" = 0 ] || return 0
  command_exists sysctl || return 0
  [ "${MM_TEST_MODE:-0}" != 1 ] || return 0
  local buffer_mb buffer_bytes cap_mb
  # 统一标准：只按物理内存选 16/32MB，不测速、不按带宽/地区分档。
  cap_mb="$(get_tcp_buffer_cap_mb)" || return 1
  buffer_mb="${cap_mb}"
  set_setting net_tune_buffer_mb "${buffer_mb}" || return 1
  buffer_bytes=$((buffer_mb * 1024 * 1024))
  apply_sysctls "${buffer_bytes}" || return 1
  apply_sysctls_extra
}
