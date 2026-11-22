#!/usr/bin/env bash
set -eEuo pipefail

umask 077

# 环境变量驱动的自动安装规格层：从环境变量解析节点参数（auto_collect_specs 等），
# 供 node-auto.sh 的 auto_install 编排使用。
# 先用字符串约束长度，再去掉前导 0，避免八进制和 Bash 算术溢出。
_normalize_unsigned_decimal() {
  local value="$1"
  [[ "$value" =~ ^[0-9]{1,20}$ ]] || return 1
  value="${value#"${value%%[!0]*}"}"
  printf '%s' "${value:-0}"
}

normalize_node_port() {
  local port
  port="$(_normalize_unsigned_decimal "$1")" || return 1
  [ "${#port}" -le 5 ] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
  printf '%s' "$port"
}

# 给 jq 和内核同一个规范的十进制数值。留空保持旧默认，0 明确表示不限速。
normalize_hy2_mbps() {
  local rate
  rate="$(_normalize_unsigned_decimal "${1:-200}")" || return 1
  # 限制有效数字，避免 jq/内核速率单位换算的整数精度和范围问题。
  [ "${#rate}" -le 9 ] || return 1
  printf '%s' "$rate"
}

env_port() {
  local __env_key="$1" __env_value
  __env_value="$(env_var "$__env_key")" || return 1
  normalize_node_port "$__env_value"
}

auto_has_node_env() {
  local v
  for v in vlrt vxpt wspt tupt anypt hypt socks5pt argo; do
    if [ -n "$(env_var "$v")" ]; then
      return 0
    fi
  done
  return 1
}
auto_collect_specs() {
  local entry var proto raw port
  for entry in vlrt:vless-reality vxpt:vless-xudp wspt:vless-ws-tls tupt:tuic-v5 anypt:anytls hypt:hy2 socks5pt:socks5; do
    var="${entry%%:*}"
    proto="${entry##*:}"
    raw="$(env_var "$var")"
    [ -n "${raw}" ] || continue
    if ! port="$(env_port "$var")"; then
      print_err "环境变量 ${var}=${raw} 不是有效端口。"
      return 1
    fi
    printf '%s %s\n' "${proto}" "${port}"
  done
  if auto_argo_requested; then
    raw="$(env_var "argo_pt")"
    if [ -z "${raw}" ]; then
      port=8001
    elif ! port="$(env_port "argo_pt")"; then
      print_err "环境变量 argo_pt=${raw} 不是有效端口。"
      return 1
    fi
    printf '%s %s\n' "vless-argo" "${port}"
  fi
  return 0
}
auto_save_node() {
  local tag="$1"
  local node_json="$2"
  local secret_json="$3"
  save_node_bundle "$tag" "$node_json" "$secret_json"
}
auto_argo_requested() {
  local v
  v="$(env_var "argo")"
  case "${v,,}" in
  vlpt | vless | true | 1 | yes) return 0 ;;
  *) return 1 ;;
  esac
}
auto_positive_or_default() {
  local __env_key="$1"
  local __env_default="$2"
  local __env_value
  __env_value="$(env_var "$__env_key")"
  if [[ "$__env_value" =~ ^[0-9]+$ ]] && [ "$__env_value" -gt 0 ]; then
    printf '%s' "$__env_value"
  else
    printf '%s' "$__env_default"
  fi
}
auto_try_port() {
  local port="$1"
  local label="$2"
  if ! port_available "$port"; then
    print_warn "端口 ${port} 已被占用，跳过 ${label} 节点。"
    return 1
  fi
  return 0
}
