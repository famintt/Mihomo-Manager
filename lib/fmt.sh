#!/usr/bin/env bash
set -eEuo pipefail

umask 077

is_safe_domain() {
  local value="$1"
  [ -n "${value}" ] || return 1
  [[ "${value}" =~ ^[A-Za-z0-9._:-]+$ ]] || return 1
  [[ "${value}" =~ ^[A-Za-z0-9] ]] || return 1
  [[ "${value}" =~ [A-Za-z0-9]$ ]] || return 1
  return 0
}

env_domain_or_default() {
  local __ed_key="$1"
  local __ed_default="$2"
  local __ed_value
  __ed_value="$(env_var "$__ed_key")"
  if [ -z "${__ed_value}" ]; then
    printf '%s' "${__ed_default}"
    return 0
  fi
  if is_safe_domain "${__ed_value}"; then
    printf '%s' "${__ed_value}"
  else
    print_warn "环境变量 ${__ed_key}=${__ed_value} 域名格式无效，已回退默认值 ${__ed_default}。"
    printf '%s' "${__ed_default}"
  fi
}

warn_if_bindv6only() {
  if [ -r /proc/sys/net/ipv6/bindv6only ] &&
    [ "$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || printf 0)" = "1" ]; then
    print_warn "检测到 net.ipv6.bindv6only=1：入站监听 :: 不会接受 IPv4 连接，IPv4 分享链接可能不可达。"
  fi
}

_is_ipv4_address() {
  local ip="$1" octet
  local -a octets=()
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<<"${ip}"
  for octet in "${octets[@]}"; do
    # 前导零在不同解析器中有十进制/八进制歧义，统一拒绝。
    [[ "${octet}" = 0 || "${octet}" != 0* ]] || return 1
    [ "$((10#${octet}))" -le 255 ] || return 1
  done
}

_ipv6_groups() {
  local ip="$1" tail left right missing group
  local -a octets=() left_groups=() right_groups=() groups=()
  # 展开为八个十进制 hextet；不调用 DNS，也不依赖 ip/python。
  if [[ "${ip}" == *.* ]]; then
    tail="${ip##*:}"
    _is_ipv4_address "${tail}" || return 1
    IFS=. read -r -a octets <<<"${tail}"
    printf -v tail '%x:%x' "$((octets[0] * 256 + octets[1]))" "$((octets[2] * 256 + octets[3]))"
    ip="${ip%"${ip##*:}"}${tail}"
  fi
  if [[ "${ip}" == *::* ]]; then
    left="${ip%%::*}"; right="${ip#*::}"
    [[ "${left}" != *: && "${right}" != :* && "${right}" != *::* ]] || return 1
    [ -z "${left}" ] || IFS=: read -r -a left_groups <<<"${left}"
    [ -z "${right}" ] || IFS=: read -r -a right_groups <<<"${right}"
    missing=$((8 - ${#left_groups[@]} - ${#right_groups[@]}))
    [ "${missing}" -gt 0 ] || return 1
    groups=("${left_groups[@]}")
    while [ "${missing}" -gt 0 ]; do groups+=(0); missing=$((missing - 1)); done
    groups+=("${right_groups[@]}")
  else
    [[ "${ip}" != :* && "${ip}" != *: ]] || return 1
    IFS=: read -r -a groups <<<"${ip}"
    [ "${#groups[@]}" -eq 8 ] || return 1
  fi
  for group in "${groups[@]}"; do
    [[ "${group}" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
  done
  for group in "${groups[@]}"; do printf '%s ' "$((16#${group}))"; done
}
is_ip_address() {
  if [[ "$1" == *:* ]]; then
    _ipv6_groups "$1" >/dev/null
  else
    _is_ipv4_address "$1"
  fi
}

# 历史函数名：0 表示私网、特殊用途或无效地址，均不能作为探测得到的公网 IP。
is_private_ip() {
  local ip="$1" expanded a b c
  local -a parts=()
  is_ip_address "${ip}" || return 0
  if [[ "${ip}" != *:* ]]; then
    IFS=. read -r a b c _ <<<"${ip}"
    if (( a == 0 || a == 10 || a == 127 || a >= 224 ||
      (a == 100 && b >= 64 && b <= 127) || (a == 169 && b == 254) ||
      (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) ||
      (a == 192 && b == 0 && (c == 0 || c == 2)) ||
      (a == 192 && b == 88 && c == 99) || (a == 198 && (b == 18 || b == 19)) ||
      (a == 198 && b == 51 && c == 100) || (a == 203 && b == 0 && c == 113) )); then
      return 0
    fi
    return 1
  fi
  expanded="$(_ipv6_groups "${ip}")" || return 0
  read -r -a parts <<<"${expanded}"
  a="${parts[0]}"; b="${parts[1]}"; c="${parts[2]}"
  # 仅接收全球单播 2000::/3；同时排除文档、基准测试、ORCHID、6to4 等特殊段。
  # 这也覆盖压缩/展开的 ::/::1、IPv4 映射、ULA、链路/站点本地、组播和 NAT64。
  if (( a < 0x2000 || a > 0x3fff || a == 0x2002 ||
    (a == 0x2001 && (b < 0x0200 || b == 0x0db8)) ||
    (a == 0x3fff && b <= 0x0fff) )); then
    return 0
  fi
  return 1
}

wrap_host() {
  local host="$1"
  if [[ "$host" == *:* ]] && [[ "$host" != \[*\] ]]; then
    printf '[%s]' "$host"
  else
    printf '%s' "$host"
  fi
}

normalize_input() {
  local value="$1"
  printf '%s' "$value" |
    tr -d '\000-\037\177' |
    sed -e 's/\r//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
