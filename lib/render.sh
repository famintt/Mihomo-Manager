#!/usr/bin/env bash
set -eEuo pipefail

umask 077

rollback_new_node() {
  local tag="$1"
  local cert_file="${2:-}"
  local key_file="${3:-}"
  delete_node_records "$tag" || true
  remove_node_certificates "$tag" "$cert_file" "$key_file"
  render_config || true
  start_service || true
}

save_node_bundle() {
  local tag="$1"
  local node_json="$2"
  local secret_json="$3"
  json_set_record "${NODES_FILE}" "$tag" "$node_json"
  json_set_record "${SECRETS_FILE}" "$tag" "$secret_json"
  invalidate_port_caches
}

# mihomo 配置为 YAML：标量统一单引号包裹（规避特殊字符），内嵌单引号按 YAML 规则双写。
yaml_quote() {
  printf "'%s'" "${1//\'/\'\'}"
}

# B4/4.2：DNS 块默认开启（空 dns_servers 走一组加密 DNS，降低解析延迟并抗污染）；
#   dns_servers=off|none 可整体关闭；非法格式不渲染（无输出）。逗号分隔多源。
#   strategy 跟随全局 ip_version（auto→prefer_ipv4，6→prefer_ipv6）。
#   mihomo 不识别 h3:// scheme（报 "DNS NameServer unsupport scheme: h3"），
#   h3://host 等价归一为 https://host/dns-query 并打开 dns.prefer-h3。
#   local 名用 __ 前缀：dns_servers 是环境变量键名，同名局部变量会在
#   env_var 的间接引用（${!key}）中命中空值（bash 动态作用域）
render_dns_object() {
  local __dns_servers __ds __strategy __hit
  local prefer_h3=0
  __dns_servers="$(env_var "dns_servers")"
  case "${__dns_servers,,}" in
  off | none | 0 | false | disabled)
    return 1
    ;;
  esac
  # 4.2：未显式配置时默认提供一组加密 DNS（1.1.1.1 + dns.google 双源）
  [ -n "${__dns_servers}" ] || __dns_servers="https://1.1.1.1/dns-query,https://dns.google/resolve"
  case "$(manager_env_or_setting "ip_version" "4")" in
  6 | v6) __strategy="prefer_ipv6" ;;
  *) __strategy="prefer_ipv4" ;;
  esac
  __hit=0
  printf 'dns:\n'
  printf '  enable: true\n'
  printf '  ipv6: true\n'
  printf '  nameserver:\n'
  for __ds in ${__dns_servers//,/ }; do
    [ -n "${__ds}" ] || continue
    case "${__ds}" in
    https://* | tls://* | udp://* | quic://* | tcp://*) __hit=1 ;;
    h3://*)
      __hit=1
      prefer_h3=1
      __ds="https://$(printf '%s' "${__ds#h3://}" | sed 's#/.*##')/dns-query"
      ;;
    *)
      return 1
      ;;
    esac
    printf '    - %s\n' "$(yaml_quote "${__ds}")"
  done
  [ "${__hit}" = 1 ] || return 1
  printf '  default-nameserver:\n'
  printf '    - %s\n' "$(yaml_quote "8.8.8.8")"
  printf '  proxy-server-nameserver:\n'
  printf '    - %s\n' "$(yaml_quote "8.8.8.8")"
  if [ "${prefer_h3}" = 1 ]; then
    printf '  prefer-h3: true\n'
  fi
  printf '  strategy: %s\n' "${__strategy}"
}

# 1.2：可观测面开关。clash_api 仅监听 127.0.0.1（无暴露风险），secret 随机生成持久化。
clash_api_enabled() {
  case "$(manager_env_or_setting "clash_api" "")" in
  0 | off | no | false) return 1 ;;
  *) return 0 ;;
  esac
}

clash_api_port() {
  local p
  p="$(manager_env_or_setting "clash_api_port" "19990")"
  [[ "${p}" =~ ^[0-9]+$ ]] && [ "${p}" -ge 1 ] && [ "${p}" -le 65535 ] || p="19990"
  printf '%s' "${p}"
}

ensure_clash_api_secret() {
  local s
  s="$(get_setting "clash_api_secret")"
  if [ -z "${s}" ]; then
    s="$(generate_hex 16)"
    set_setting "clash_api_secret" "${s}"
  fi
  printf '%s' "${s}"
}

# clash_api 基础 curl。controller 或 secret 缺失/curl 不可用时返回失败。
clash_api_fetch() {
  local _p="$1" _out
  command_exists curl || return 1
  _out="$(curl -fsS --max-time 4 -H "Authorization: Bearer $(ensure_clash_api_secret)" \
    "http://127.0.0.1:$(clash_api_port)${_p}" 2>/dev/null || true)"
  [ -n "${_out}" ] || return 1
  printf '%s' "${_out}"
}

# 1.2：活跃连接汇总行（数量 + 上下行速率），供 mm status 展示。
clash_api_conn_summary() {
  local _out _active _down _up _start _elapsed
  clash_api_enabled || return 1
  _out="$(clash_api_fetch "/connections" 2>/dev/null || true)"
  [ -n "${_out}" ] || {
    print_warn "clash_api 不可达（mihomo 可能未运行或未启用可观测面）。"
    return 1
  }
  _active="$(printf '%s' "${_out}" | jq -r '.connections | length // 0' 2>/dev/null || printf 0)"
  _down="$(printf '%s' "${_out}" | jq -r '.downloadTotal // empty' 2>/dev/null || true)"
  _up="$(printf '%s' "${_out}" | jq -r '.uploadTotal // empty' 2>/dev/null || true)"
  _start="$(printf '%s' "${_out}" | jq -r '.startTime // empty' 2>/dev/null || true)"
  # 速率 = 累计字节 ×8 / 运行秒数（downloadTotal/uploadTotal 为字节）
  if [[ "${_down}" =~ ^[0-9]+$ ]] && [[ "${_up}" =~ ^[0-9]+$ ]] && [[ "${_start}" =~ ^[0-9.]+$ ]]; then
    _elapsed="$(awk -v s="${_start}" 'BEGIN { e = systime() - s; printf "%d", e < 0 ? 0 : e }' 2>/dev/null || printf 0)"
    printf '%s 连接 | 下行 %s | 上行 %s' \
      "${_active}" \
      "$(_fmt_mbps "${_down}" "${_elapsed}")" \
      "$(_fmt_mbps "${_up}" "${_elapsed}")"
  else
    printf '%s 连接' "${_active}"
  fi
}

# 1.2：watchdog 探活失败时把当前 connections dump 到运行时日志辅助根因定位。
clash_api_dump_connections() {
  [ -f "${NODES_FILE}" ] || return 0
  clash_api_enabled || return 0
  command_exists curl || return 0
  local _out
  _out="$(clash_api_fetch "/connections" 2>/dev/null || true)"
  [ -n "${_out}" ] || return 0
  {
    printf '\n[%s] clash_api connections dump（探活失败快照）：\n' "$(date -Is 2>/dev/null || date +%s)"
    printf '%s\n' "${_out}" | jq '{downloadTotal, uploadTotal, connections: [(.connections|length)]}' 2>/dev/null || printf '%s\n' "${_out}"
  } >>"${RUNTIME_DIR}/clash-api-dump.log" 2>/dev/null || true
}

# 字节→Mbps：bytes ×8 / 秒 / 1e6 = bytes / 秒 / 125000
_fmt_mbps() {
  local _b="$1" _s="$2" _mbps=0
  [ "${_s}" -gt 0 ] 2>/dev/null && _mbps=$((_b / _s / 125000))
  printf '%s Mbps' "${_mbps}"
}

render_config() {
  local tmp tags listeners_block dns_block item
  migrate_custom_certificates || return 1
  if ! tags="$(iter_node_tags)"; then
    print_err "读取节点列表失败。"
    return 1
  fi
  listeners_block=""
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    if ! item="$(render_inbound_for_tag "${tag}")"; then
      print_err "生成 mihomo 入站配置失败。"
      return 1
    fi
    listeners_block="${listeners_block}${item}"$'\n'
  done <<<"${tags}"

  tmp="$(mktemp "${BASE_DIR}/.config.XXXXXX")"
  # 数据面日志等级可调（info/debug），生产默认 warning 降低高负载磁盘 IO
  local log_level
  log_level="$(manager_env_or_setting "log_level" "")"
  if [ "$(manager_env_or_setting "debug_flag" "0")" = "1" ]; then
    log_level="debug"
  fi
  case "${log_level}" in
  "info" | "debug") : ;;
  *) log_level="warning" ;;
  esac

  {
    printf '# Generated by %s v%s\n' "${PROJECT_NAME}" "${SCRIPT_VERSION}"
    printf 'mode: direct\n'
    printf 'log-level: %s\n' "${log_level}"
    printf 'ipv6: true\n'
    printf 'unified-delay: true\n'
    printf 'tcp-keep-alive-idle: 120\n'
    printf 'keep-alive-interval: 30\n'
    printf 'profile:\n'
    printf '  store-selected: false\n'
    if clash_api_enabled; then
      printf 'external-controller: %s\n' "$(yaml_quote "127.0.0.1:$(clash_api_port)")"
      printf 'secret: %s\n' "$(yaml_quote "$(ensure_clash_api_secret)")"
    fi
    if dns_block="$(render_dns_object 2>/dev/null)"; then
      printf '%s\n' "${dns_block}"
    fi
    if [ -n "${listeners_block}" ]; then
      printf 'listeners:\n'
      printf '%s\n' "${listeners_block}"
    fi
  } >"${tmp}" || {
    rm -f "${tmp}"
    print_err "写入 mihomo 配置失败。"
    return 1
  }
  # S4：落盘前用 mihomo 校验 tmp，失败则删除 tmp、保留旧配置并报错（fail-closed）
  if [ -n "${MIHOMO_BIN:-}" ] && [ -x "${MIHOMO_BIN}" ] && ! "${MIHOMO_BIN}" -t -f "${tmp}" >/dev/null 2>&1; then
    rm -f "${tmp}"
    print_err "mihomo 配置校验失败，已拒绝覆盖现有配置（旧配置保留）。"
    return 1
  fi
  if ! chmod 600 "${tmp}" || ! mv "${tmp}" "${CONFIG_FILE}"; then
    rm -f "${tmp}"
    print_err "保存 mihomo 配置失败。"
    return 1
  fi
  print_info "已生成并校验 ${CONFIG_FILE}（mihomo -t 通过）。"
}

node_meta() {
  local tag="$1"
  # 单进程 jq 合并 nodes+secrets 输出 25 个字段（每行一个，空值输出空行），
  # 字段路径与 node_value/secret_value（.[$tag][$field]）完全一致；
  # 渲染/分享链接按节点仅启动 1 次 jq，替代逐字段 node_value/secret_value 的多次启动。
  # 输出用"每行一个字段"而非 tab 分隔：bash 的 read/cut 会合并连续 tab 并吞掉空字段，
  # 空行则能被 while read 完整保留。
  jq -n -r --arg tag "$tag" \
    --rawfile nodes "${NODES_FILE}" \
    --rawfile secrets "${SECRETS_FILE}" '
    ($nodes | fromjson | .[$tag] // {}) as $n |
    ($secrets | fromjson | .[$tag] // {}) as $s |
    [
      ($n.protocol // ""),
      ($n.name // ""),
      (($n.port // "") | tostring),
      ($s.uuid // ""),
      ($s.password // ""),
      ($s.private_key // ""),
      ($n.public_key // ""),
      ($n.short_id // ""),
      ($n.reality_server // ""),
      ($n.tls_server // ""),
      ($n.preferred_domain // ""),
      ($n.host_domain // ""),
      ($n.ws_path // ""),
      ($n.ws_mode // ""),
      (($n.cdn_port // "") | tostring),
      ($n.cdn_sni // ""),
      ($n.certificate_mode // ""),
      ($n.certificate_path // ""),
      ($n.key_path // ""),
      ($n.endpoint_domain // ""),
      ($n.argo_mode // ""),
      ($s.argo_token // ""),
      (($n.up_mbps // "") | tostring),
      (($n.down_mbps // "") | tostring),
      ($n.username // "")
    ] | .[]
  '
}

node_meta_array() {
  local tag="$1" i=0 _f
  NODE_META=()
  while IFS= read -r _f; do
    NODE_META[i++]="${_f%$'\r'}"
    [ "$i" -ge 25 ] && break
  done < <(node_meta "$tag")
  while [ "$i" -lt 25 ]; do NODE_META[i++]=""; done
}

render_inbound_for_tag() {
  local tag="$1"
  local protocol name port uuid password cert_file key_file ws_path reality_server tls_server
  local up_mbps down_mbps private_key short_id username

  # 单次 jq 批量取出 nodes+secrets 全部字段，替代逐字段 node_value/secret_value（每节点省多次 jq 启动）
  node_meta_array "$tag"
  protocol="${NODE_META[0]}"
  name="${NODE_META[1]}"
  port="${NODE_META[2]}"
  uuid="${NODE_META[3]}"
  password="${NODE_META[4]}"
  private_key="${NODE_META[5]}"
  short_id="${NODE_META[7]}"
  reality_server="${NODE_META[8]}"
  tls_server="${NODE_META[9]}"
  ws_path="${NODE_META[12]}"
  cert_file="${NODE_META[17]}"
  key_file="${NODE_META[18]}"
  up_mbps="${NODE_META[22]}"
  down_mbps="${NODE_META[23]}"
  username="${NODE_META[24]}"
  # 全局速率默认 200 Mbps（与旧缺省一致）；mihomo hy2 以字符串 "N Mbps" 表达
  up_mbps="${up_mbps:-200}"
  down_mbps="${down_mbps:-200}"
  [[ "${port}" =~ ^[0-9]+$ ]] || port=0

  case "$protocol" in
  vless-reality)
    printf '  - type: vless\n'
    printf '    name: %s\n' "$(yaml_quote "$tag")"
    printf '    listen: %s\n' "$(yaml_quote '::')"
    printf '    port: %s\n' "$port"
    printf '    users:\n'
    printf '      - username: %s\n' "$(yaml_quote "$name")"
    printf '        uuid: %s\n' "$(yaml_quote "$uuid")"
    printf '        flow: xtls-rprx-vision\n'
    printf '    reality-config:\n'
    printf '      dest: %s\n' "$(yaml_quote "${reality_server}:443")"
    printf '      private-key: %s\n' "$(yaml_quote "$private_key")"
    _emit_short_ids "$short_id"
    printf '      server-names:\n'
    printf '        - %s\n' "$(yaml_quote "$reality_server")"
    ;;
  vless-xudp)
    # VLESS + Reality + XUDP：XUDP 是 VLESS 的 UDP-over-TCP 封装，
    # Mihomo listener 收到 CommandMux 后自动处理，不需要 packet-encoding/mux 配置。
    printf '  - type: vless\n'
    printf '    name: %s\n' "$(yaml_quote "$tag")"
    printf '    listen: %s\n' "$(yaml_quote '::')"
    printf '    port: %s\n' "$port"
    printf '    users:\n'
    printf '      - username: %s\n' "$(yaml_quote "$name")"
    printf '        uuid: %s\n' "$(yaml_quote "$uuid")"
    printf '    reality-config:\n'
    printf '      dest: %s\n' "$(yaml_quote "${reality_server}:443")"
    printf '      private-key: %s\n' "$(yaml_quote "$private_key")"
    _emit_short_ids "$short_id"
    printf '      server-names:\n'
    printf '        - %s\n' "$(yaml_quote "$reality_server")"
    ;;
  vless-ws-tls)
    # 主 listener：TLS 端口（CDN 模式统一单端口：客户端连 CDN 边缘，CF 按 SSL 模式
    # Full/Full(Strict) 以 HTTPS 回源到本 TLS 端口，无需明文回源 listener）。
    # mihomo 无独立 "vless (ws)" 类型：type 仍为 vless，靠 ws-path 判定 WS 传输。
    printf '  - type: vless\n'
    printf '    name: %s\n' "$(yaml_quote "$tag")"
    printf '    listen: %s\n' "$(yaml_quote '::')"
    printf '    port: %s\n' "$port"
    printf '    users:\n'
    printf '      - username: %s\n' "$(yaml_quote "$name")"
    printf '        uuid: %s\n' "$(yaml_quote "$uuid")"
    printf '    ws-path: %s\n' "$(yaml_quote "$ws_path")"
    printf '    certificate: %s\n' "$(yaml_quote "$cert_file")"
    printf '    private-key: %s\n' "$(yaml_quote "$key_file")"
    ;;
  anytls)
    printf '  - type: anytls\n'
    printf '    name: %s\n' "$(yaml_quote "$tag")"
    printf '    listen: %s\n' "$(yaml_quote '::')"
    printf '    port: %s\n' "$port"
    printf '    users:\n'
    printf '      %s: %s\n' "$(yaml_quote "$name")" "$(yaml_quote "$password")"
    printf '    certificate: %s\n' "$(yaml_quote "$cert_file")"
    printf '    private-key: %s\n' "$(yaml_quote "$key_file")"
    ;;
  vless-argo)
    # Argo：cloudflared 隧道回源到本机明文 WS listener，无 TLS；
    # mihomo vless listener 无证书时需 allow-insecure 才允许启动。
    printf '  - type: vless\n'
    printf '    name: %s\n' "$(yaml_quote "$tag")"
    printf '    listen: %s\n' "$(yaml_quote '127.0.0.1')"
    printf '    port: %s\n' "$port"
    printf '    users:\n'
    printf '      - username: %s\n' "$(yaml_quote "$name")"
    printf '        uuid: %s\n' "$(yaml_quote "$uuid")"
    printf '    ws-path: %s\n' "$(yaml_quote "$ws_path")"
    printf '    allow-insecure: true\n'
    ;;
  tuic-v5)
    printf '  - type: tuic\n'
    printf '    name: %s\n' "$(yaml_quote "$tag")"
    printf '    listen: %s\n' "$(yaml_quote '::')"
    printf '    port: %s\n' "$port"
    printf '    users:\n'
    printf '      %s: %s\n' "$(yaml_quote "$uuid")" "$(yaml_quote "$password")"
    printf '    congestion-controller: bbr\n'
    printf '    alpn:\n'
    printf '      - h3\n'
    printf '    certificate: %s\n' "$(yaml_quote "$cert_file")"
    printf '    private-key: %s\n' "$(yaml_quote "$key_file")"
    ;;
  hy2)
    printf '  - type: hysteria2\n'
    printf '    name: %s\n' "$(yaml_quote "$tag")"
    printf '    listen: %s\n' "$(yaml_quote '::')"
    printf '    port: %s\n' "$port"
    printf '    users:\n'
    printf '      %s: %s\n' "$(yaml_quote "$name")" "$(yaml_quote "$password")"
    printf '    up: %s Mbps\n' "$up_mbps"
    printf '    down: %s Mbps\n' "$down_mbps"
    printf '    alpn:\n'
    printf '      - h3\n'
    printf '    certificate: %s\n' "$(yaml_quote "$cert_file")"
    printf '    private-key: %s\n' "$(yaml_quote "$key_file")"
    ;;
  socks5)
    printf '  - type: socks\n'
    printf '    name: %s\n' "$(yaml_quote "$tag")"
    printf '    listen: %s\n' "$(yaml_quote '::')"
    printf '    port: %s\n' "$port"
    printf '    users:\n'
    printf '      - username: %s\n' "$(yaml_quote "$username")"
    printf '        password: %s\n' "$(yaml_quote "$password")"
    ;;
  *)
    print_err "不支持的节点协议：${protocol}"
    return 1
    ;;
  esac
}

# reality short_id 支持逗号分隔多值，逐条展开为 YAML 列表
_emit_short_ids() {
  local value="$1" _s
  local -a __ids
  [ -n "${value}" ] || return 0
  IFS=, read -ra __ids <<<"${value}"
  printf '      short-id:\n'
  for _s in "${__ids[@]}"; do
    [ -n "${_s}" ] || continue
    printf '        - %s\n' "$(yaml_quote "${_s}")"
  done
}
