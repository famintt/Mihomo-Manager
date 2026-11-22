#!/usr/bin/env bash
set -eEuo pipefail

umask 077

save_node_bundle() {
  local tag="$1"
  local node_json="$2"
  local secret_json="$3"
  validate_storage_tables || return 1
  json_set_record "${NODES_FILE}" "$tag" "$node_json" || return 1
  json_set_record "${SECRETS_FILE}" "$tag" "$secret_json" || return 1
  invalidate_port_caches
}

# JSON 双引号标量是合法 YAML。额外转义 JSON 可裸写而 YAML 会折叠或拒绝的字符。
# 从 stdin 读取，避免把密码等标量作为 jq 的进程参数传递。
yaml_quote() {
  printf '%s' "$1" | jq -Rrs '
    def hex4:
      . as $n | [4096, 256, 16, 1] | map(
        . as $place | (($n / $place | floor) % 16) as $digit |
        "0123456789abcdef"[$digit:($digit + 1)]
      ) | join("");
    @json | gsub("(?<c>[\u007f-\u009f\u2028\u2029\ufffe\uffff])";
                 "\\u" + (.c | explode[0] | hex4))'
}

yaml_emit() {
  local format="$1" value quoted
  local -a values=()
  shift
  for value in "$@"; do
    quoted="$(yaml_quote "$value")" || return 1
    values+=("$quoted")
  done
  # shellcheck disable=SC2059  # 格式字符串来自固定的配置模板
  printf "$format" "${values[@]}"
}

# DNS 默认开启。返回 1 表示显式关闭，返回 2 表示非法输入，失败时不输出半个配置块。
render_dns_object() {
  local __dns_servers="${dns_servers:-}" __ds __strategy __bootstrap __host
  local prefer_h3=0
  local -a __sources=() __quoted=()

  # 仅允许单行逗号分隔，首尾允许空格，不做 shell 分词或路径名展开。
  [[ "$__dns_servers" != *[$'\r\n']* ]] || return 2
  while [[ "$__dns_servers" == [[:blank:]]* ]]; do __dns_servers="${__dns_servers#?}"; done
  while [[ "$__dns_servers" == *[[:blank:]] ]]; do __dns_servers="${__dns_servers%?}"; done
  case "${__dns_servers,,}" in
    off | none | 0 | false | disabled) return 1 ;;
  esac

  case "$(manager_env_or_setting ip_version 4)" in
    6 | v6)
      __strategy=prefer_ipv6
      __bootstrap='[2606:4700:4700::1111]'
      __dns_servers="${__dns_servers:-https://[2606:4700:4700::1111]/dns-query,https://dns.google/dns-query}"
      ;;
    *)
      __strategy=prefer_ipv4
      __bootstrap=8.8.8.8
      __dns_servers="${__dns_servers:-https://1.1.1.1/dns-query,https://dns.google/resolve}"
      ;;
  esac

  # 最后的空项由 read 省去，单独拒绝。其余空项会在循环内被拒绝。
  [[ "$__dns_servers" != *, ]] || return 2
  IFS=, read -r -a __sources <<<"$__dns_servers" || return 2
  for __ds in "${__sources[@]}"; do
    while [[ "$__ds" == [[:blank:]]* ]]; do __ds="${__ds#?}"; done
    while [[ "$__ds" == *[[:blank:]] ]]; do __ds="${__ds%?}"; done
    [[ "$__ds" != *[[:space:][:cntrl:]]* ]] || return 2
    case "$__ds" in
      https://?* | tls://?* | udp://?* | quic://?* | tcp://?*) ;;
      h3://?*)
        prefer_h3=1
        __host="${__ds#h3://}"
        case "$__host" in
          */*) __ds="https://$__host" ;;
          *) __ds="https://$__host/dns-query" ;;
        esac
        ;;
      *) return 2 ;;
    esac
    __ds="$(yaml_quote "$__ds")" || return 2
    __quoted+=("$__ds")
  done
  __bootstrap="$(yaml_quote "$__bootstrap")" || return 2

  printf 'dns:\n  enable: true\n  ipv6: true\n  nameserver:\n' || return 2
  printf '    - %s\n' "${__quoted[@]}" || return 2
  printf '  default-nameserver:\n    - %s\n  proxy-server-nameserver:\n    - %s\n' "$__bootstrap" "$__bootstrap" || return 2
  if [ "$prefer_h3" = 1 ]; then
    printf '  prefer-h3: true\n' || return 2
  fi
  printf '  strategy: %s\n' "$__strategy" || return 2
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
  local secret
  secret="$(get_setting clash_api_secret)" || return 1
  if [ -z "$secret" ]; then
    secret="$(generate_hex 16)" || return 1
    [[ "$secret" =~ ^[0-9a-fA-F]{32}$ ]] || return 1
    set_setting clash_api_secret "$secret" || return 1
  fi
  [[ "$secret" != *[[:cntrl:]]* ]] && [ -n "$secret" ] || return 1
  printf '%s' "$secret"
}

# 查询接口只读取既有凭据，curl 从 stdin 读取鉴权头，避免进程参数暴露令牌。
clash_api_fetch() {
  local path="$1" out secret port
  command_exists curl || return 1
  secret="$(get_setting clash_api_secret)" || return 1
  [ -n "$secret" ] && [[ "$secret" != *[[:cntrl:]]* ]] || return 1
  port="$(clash_api_port)" || return 1
  out="$(printf 'Authorization: Bearer %s\n' "$secret" |
    curl -fsS --max-time 4 --header @- "http://127.0.0.1:$port$path" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
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
  rotate_log_file "${RUNTIME_DIR}/clash-api-dump.log" >/dev/null 2>&1 || true
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
  local tmp tags tag listeners_block="" dns_block item rc log_level api_port="" api_secret=""
  validate_storage_tables || return 1
  migrate_custom_certificates || return 1
  if ! tags="$(iter_node_tags)"; then
    print_err "读取节点列表失败。"
    return 1
  fi
  if clash_api_enabled; then
    api_port="$(clash_api_port)" || return 1
    if metadata_has_port "$api_port"; then
      print_err "Clash API 端口与已配置节点冲突：$api_port"
      return 1
    fi
  fi
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    if ! item="$(render_inbound_for_tag "$tag")"; then
      print_err "生成 mihomo 入站配置失败：$tag"
      return 1
    fi
    listeners_block="$listeners_block$item"$'\n'
  done <<<"$tags"

  if dns_block="$(render_dns_object)"; then
    :
  else
    rc=$?
    if [ "$rc" -ne 1 ]; then
      print_err 'DNS 配置无效，已拒绝覆盖现有配置。'
      return 1
    fi
  fi

  log_level="$(manager_env_or_setting log_level '')" || return 1
  if [ "$(manager_env_or_setting debug_flag 0)" = 1 ]; then
    log_level=debug
  fi
  case "$log_level" in
    info | debug) ;;
    *) log_level=warning ;;
  esac
  if [ -n "$api_port" ]; then
    api_secret="$(ensure_clash_api_secret)" || return 1
    api_secret="$(yaml_quote "$api_secret")" || return 1
    api_port="$(yaml_quote "127.0.0.1:$api_port")" || return 1
  fi

  tmp="$(mktemp "${BASE_DIR}/.config.XXXXXX")" || return 1
  if ! (
    printf '# Generated by %s v%s\n' "${PROJECT_NAME}" "${SCRIPT_VERSION}" &&
    printf 'mode: direct\nlog-level: %s\nipv6: true\nunified-delay: true\n' "$log_level" &&
    printf 'tcp-keep-alive-idle: 120\nkeep-alive-interval: 30\nprofile:\n  store-selected: false\n' &&
    { [ -z "$api_port" ] || printf 'external-controller: %s\nsecret: %s\n' "$api_port" "$api_secret"; } &&
    { [ -z "$dns_block" ] || printf '%s\n' "$dns_block"; } &&
    { [ -z "$listeners_block" ] || printf 'listeners:\n%s' "$listeners_block"; }
  ) >"$tmp"; then
    rm -f -- "$tmp"
    print_err '写入 mihomo 配置失败。'
    return 1
  fi
  # 使用与服务相同的工作目录和 SAFE_PATHS 验证，再原子替换主配置。
  if ! mihomo_validate "$tmp" >/dev/null 2>&1; then
    rm -f -- "$tmp"
    print_err 'mihomo 配置校验失败，已拒绝覆盖现有配置。'
    return 1
  fi
  if ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "${CONFIG_FILE}"; then
    rm -f -- "$tmp"
    print_err '保存 mihomo 配置失败。'
    return 1
  fi
  print_info "已生成并校验 ${CONFIG_FILE}（mihomo -t 通过）。"
}

# 25 个固定索引字段。NUL 作为分隔符，空字符串、换行、CR 和反斜杠都原样传递。
node_meta() {
  local tag="$1"
  jq -n -j --arg tag "$tag" \
    --rawfile nodes "${NODES_FILE}" \
    --rawfile secrets "${SECRETS_FILE}" '
    def record($table):
      ($table | fromjson) as $rows |
      if ($rows | type) == "object" and ($rows[$tag] | type) == "object"
      then $rows[$tag] else error("missing or invalid node record") end;
    def field:
      if . == null then ""
      elif type == "string" or type == "number" then tostring
      else error("unsupported node metadata field type") end |
      if (explode | index(0)) == null then .
      else error("NUL in node metadata field") end;
    record($nodes) as $n | record($secrets) as $s |
    [
      ($n.protocol),
      ($n.name),
      ($n.port),
      ($s.uuid),
      ($s.password),
      ($s.private_key),
      ($n.public_key),
      ($n.short_id),
      ($n.reality_server),
      ($n.tls_server),
      ($n.preferred_domain),
      ($n.host_domain),
      ($n.ws_path),
      ($n.ws_mode),
      ($n.cdn_port),
      ($n.cdn_sni),
      ($n.certificate_mode),
      ($n.certificate_path),
      ($n.key_path),
      ($n.endpoint_domain),
      ($n.argo_mode),
      ($s.argo_token),
      ($n.up_mbps),
      ($n.down_mbps),
      ($n.username)
    ] | map(field) | .[] + "\u0000"
  '
}

node_meta_array() {
  local tag="$1" i=0 field
  local -a fields=()
  NODE_META=()
  while IFS= read -r -d '' field; do
    fields[i++]="$field"
  done < <(node_meta "$tag" && printf 'complete\0')
  # 完成标记只在生产者成功时发送，兼容 Bash 4 无法等待进程替换 PID 的版本。
  [ "$i" -eq 26 ] && [ "${fields[25]}" = complete ] || return 1
  unset 'fields[25]'
  NODE_META=("${fields[@]}")
}

_render_certificate_path() {
  local file="$1"
  # 兼容旧版托管文件名。路径必须是 CERT_DIR 下的普通文件，且不能嵌套。
  case "$file" in
    "${CERT_DIR%/}"/*)
      [[ "${file#"${CERT_DIR%/}"/}" != */* ]] && [ -f "$file" ] && [ ! -L "$file" ]
      ;;
    *) return 1 ;;
  esac
}

render_inbound_for_tag() {
  local tag="$1"
  local protocol name port uuid password cert_file key_file ws_path reality_server
  local up_mbps down_mbps private_key short_id username

  # 单次 jq 批量取出 nodes+secrets 全部字段，替代逐字段 node_value/secret_value（每节点省多次 jq 启动）
  node_meta_array "$tag" || return 1
  protocol="${NODE_META[0]}"
  name="${NODE_META[1]}"
  port="${NODE_META[2]}"
  uuid="${NODE_META[3]}"
  password="${NODE_META[4]}"
  private_key="${NODE_META[5]}"
  short_id="${NODE_META[7]}"
  reality_server="${NODE_META[8]}"
  ws_path="${NODE_META[12]}"
  cert_file="${NODE_META[17]}"
  key_file="${NODE_META[18]}"
  up_mbps="${NODE_META[22]}"
  down_mbps="${NODE_META[23]}"
  username="${NODE_META[24]}"
  if ! port="$(normalize_node_port "$port")"; then
    print_err "节点端口无效：$tag"
    return 1
  fi

  # 自定义证书先迁移到托管目录，拒绝从其他位置渲染路径或加载符号链接。
  case "$protocol" in
    vless-ws-tls | anytls | tuic-v5 | hy2)
      if ! _render_certificate_path "$cert_file" || ! _render_certificate_path "$key_file"; then
        print_err "节点证书或私钥不在托管证书目录：$tag"
        return 1
      fi
      ;;
  esac

  case "$protocol" in
  vless-reality)
    printf '  - type: vless\n' || return 1
    yaml_emit '    name: %s\n' "$tag" || return 1
    yaml_emit '    listen: %s\n' '::' || return 1
    printf '    port: %s\n' "$port" || return 1
    printf '    users:\n' || return 1
    yaml_emit '      - username: %s\n' "$name" || return 1
    yaml_emit '        uuid: %s\n' "$uuid" || return 1
    printf '        flow: xtls-rprx-vision\n' || return 1
    printf '    reality-config:\n' || return 1
    yaml_emit '      dest: %s\n' "${reality_server}:443" || return 1
    yaml_emit '      private-key: %s\n' "$private_key" || return 1
    _emit_short_ids "$short_id" || return 1
    printf '      server-names:\n' || return 1
    yaml_emit '        - %s\n' "$reality_server" || return 1
    ;;
  vless-xudp)
    # VLESS + Reality + XUDP：XUDP 是 VLESS 的 UDP-over-TCP 封装，
    # Mihomo listener 收到 CommandMux 后自动处理，不需要 packet-encoding/mux 配置。
    printf '  - type: vless\n' || return 1
    yaml_emit '    name: %s\n' "$tag" || return 1
    yaml_emit '    listen: %s\n' '::' || return 1
    printf '    port: %s\n' "$port" || return 1
    printf '    users:\n' || return 1
    yaml_emit '      - username: %s\n' "$name" || return 1
    yaml_emit '        uuid: %s\n' "$uuid" || return 1
    printf '    reality-config:\n' || return 1
    yaml_emit '      dest: %s\n' "${reality_server}:443" || return 1
    yaml_emit '      private-key: %s\n' "$private_key" || return 1
    _emit_short_ids "$short_id" || return 1
    printf '      server-names:\n' || return 1
    yaml_emit '        - %s\n' "$reality_server" || return 1
    ;;
  vless-ws-tls)
    # 主 listener：TLS 端口（CDN 模式统一单端口：客户端连 CDN 边缘，CF 按 SSL 模式
    # Full/Full(Strict) 以 HTTPS 回源到本 TLS 端口，无需明文回源 listener）。
    # mihomo 无独立 "vless (ws)" 类型：type 仍为 vless，靠 ws-path 判定 WS 传输。
    printf '  - type: vless\n' || return 1
    yaml_emit '    name: %s\n' "$tag" || return 1
    yaml_emit '    listen: %s\n' '::' || return 1
    printf '    port: %s\n' "$port" || return 1
    printf '    users:\n' || return 1
    yaml_emit '      - username: %s\n' "$name" || return 1
    yaml_emit '        uuid: %s\n' "$uuid" || return 1
    yaml_emit '    ws-path: %s\n' "$ws_path" || return 1
    yaml_emit '    certificate: %s\n' "$cert_file" || return 1
    yaml_emit '    private-key: %s\n' "$key_file" || return 1
    ;;
  anytls)
    printf '  - type: anytls\n' || return 1
    yaml_emit '    name: %s\n' "$tag" || return 1
    yaml_emit '    listen: %s\n' '::' || return 1
    printf '    port: %s\n' "$port" || return 1
    printf '    users:\n' || return 1
    yaml_emit '      %s: %s\n' "$name" "$password" || return 1
    yaml_emit '    certificate: %s\n' "$cert_file" || return 1
    yaml_emit '    private-key: %s\n' "$key_file" || return 1
    ;;
  vless-argo)
    # Argo：cloudflared 隧道回源到本机明文 WS listener，无 TLS；
    # mihomo vless listener 无证书时需 allow-insecure 才允许启动。
    printf '  - type: vless\n' || return 1
    yaml_emit '    name: %s\n' "$tag" || return 1
    yaml_emit '    listen: %s\n' '127.0.0.1' || return 1
    printf '    port: %s\n' "$port" || return 1
    printf '    users:\n' || return 1
    yaml_emit '      - username: %s\n' "$name" || return 1
    yaml_emit '        uuid: %s\n' "$uuid" || return 1
    yaml_emit '    ws-path: %s\n' "$ws_path" || return 1
    printf '    allow-insecure: true\n' || return 1
    ;;
  tuic-v5)
    printf '  - type: tuic\n' || return 1
    yaml_emit '    name: %s\n' "$tag" || return 1
    yaml_emit '    listen: %s\n' '::' || return 1
    printf '    port: %s\n' "$port" || return 1
    printf '    users:\n' || return 1
    yaml_emit '      %s: %s\n' "$uuid" "$password" || return 1
    printf '    congestion-controller: bbr\n' || return 1
    printf '    alpn:\n' || return 1
    printf '      - h3\n' || return 1
    yaml_emit '    certificate: %s\n' "$cert_file" || return 1
    yaml_emit '    private-key: %s\n' "$key_file" || return 1
    ;;
  hy2)
    if ! up_mbps="$(normalize_hy2_mbps "$up_mbps")" || ! down_mbps="$(normalize_hy2_mbps "$down_mbps")"; then
      print_err "HY2 节点带宽无效：$tag"
      return 1
    fi
    printf '  - type: hysteria2\n' || return 1
    yaml_emit '    name: %s\n' "$tag" || return 1
    yaml_emit '    listen: %s\n' '::' || return 1
    printf '    port: %s\n' "$port" || return 1
    printf '    users:\n' || return 1
    yaml_emit '      %s: %s\n' "$name" "$password" || return 1
    [ "$up_mbps" = 0 ] || yaml_emit '    up: %s\n' "$up_mbps Mbps" || return 1
    [ "$down_mbps" = 0 ] || yaml_emit '    down: %s\n' "$down_mbps Mbps" || return 1
    # 两向均不限速时让内核忽略客户端的限速建议，使用 BBR 自适应拥塞控制。
    if [ "$up_mbps" = 0 ] && [ "$down_mbps" = 0 ]; then
      printf '    ignore-client-bandwidth: true\n' || return 1
    fi
    printf '    alpn:\n' || return 1
    printf '      - h3\n' || return 1
    yaml_emit '    certificate: %s\n' "$cert_file" || return 1
    yaml_emit '    private-key: %s\n' "$key_file" || return 1
    ;;
  socks5)
    printf '  - type: socks\n' || return 1
    yaml_emit '    name: %s\n' "$tag" || return 1
    yaml_emit '    listen: %s\n' '::' || return 1
    printf '    port: %s\n' "$port" || return 1
    printf '    users:\n' || return 1
    yaml_emit '      - username: %s\n' "$username" || return 1
    yaml_emit '        password: %s\n' "$password" || return 1
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
  IFS=, read -r -d '' -a __ids < <(printf '%s\0' "${value}") || return 1
  printf '      short-id:\n' || return 1
  for _s in "${__ids[@]}"; do
    [ -n "${_s}" ] || continue
    yaml_emit '        - %s\n' "${_s}" || return 1
  done
}
