#!/usr/bin/env bash
set -eEuo pipefail

umask 077

# 节点显示名：机器名按用户配置原样保留，协议名使用固定大小写。
node_display_name() {
  local suffix="$1"
  if [ -n "${ENV_NAME:-}" ]; then
    printf '%s-%s' "${ENV_NAME}" "$suffix"
  else
    printf '%s' "$suffix"
  fi
}

# 3.1：Reality multi short_id——短 ID 以逗号分隔配置（ENV short_ids），
# 过滤掉非法的十六进制/奇数长度/超长 token；无合法项时返回失败由调用方生成默认单 ID。
resolve_short_ids() {
  local raw="$1" tok out=""
  local -a tokens
  [ -n "${raw}" ] || return 1
  raw="$(printf '%s' "${raw}" | tr -d ' \r\n')" || return 1
  IFS=',' read -r -a tokens <<<"${raw}"
  for tok in "${tokens[@]}"; do
    if [[ "${tok}" =~ ^[0-9a-fA-F]+$ ]] && [ $((${#tok} % 2)) -eq 0 ] &&
      [ "${#tok}" -ge 2 ] && [ "${#tok}" -le 32 ]; then
      if [ -n "${out}" ]; then
        out="${out},"
      fi
      out="${out}${tok,,}"
    fi
  done
  [ -n "${out}" ] || return 1
  printf '%s' "${out}"
}

tls_sni_auto() {
  local key="$1" fallback="$2" raw mode
  raw="$(env_var "${key}")" || return 1
  mode="$(env_var "cert")" || return 1
  mode="${mode:-self}"
  case "${raw,,}" in
  "")
    env_domain_or_default "${key}" "${fallback}"
    ;;
  auto)
    if [ "${mode}" = "custom" ]; then
      print_warn "${key}=auto 不能用于自定义证书，回退 ${fallback}；请填写证书域名。"
      printf '%s' "${fallback}"
      return 0
    fi
    if [ -n "${TLS_SNI_AUTO_CACHE:-}" ]; then
      printf '%s' "${TLS_SNI_AUTO_CACHE}"
      return 0
    fi
    print_info "正在检测 TLS SNI（TLS 1.3 + HTTP/2，自签证书）..." >&2
    TLS_SNI_AUTO_CACHE="$(detect_sni_best 2>/dev/null || printf '%s' "${fallback}")" || return 1
    printf '%s' "${TLS_SNI_AUTO_CACHE}"
    ;;
  *)
    env_domain_or_default "${key}" "${fallback}"
    ;;
  esac
}

auto_cert_bundle() {
  local tag="$1" domain="$2"
  # Do not shadow environment keys through bash dynamic scope.
  local __mode __cert_path __key_path __cert_b64 __key_b64 __pair
  __mode="$(env_var "cert")" || return 1
  __mode="${__mode:-self}"
  case "$__mode" in
  custom)
    __cert_b64="$(env_var "cert_b64")" || return 1
    __key_b64="$(env_var "key_b64")" || return 1
    if [ -n "$__cert_b64" ] || [ -n "$__key_b64" ]; then
      if [ -z "$__cert_b64" ] || [ -z "$__key_b64" ] ||
        ! __pair="$(import_custom_certificate_content "$tag" "$__cert_b64" "$__key_b64")"; then
        print_err "自定义证书内容无效或证书与私钥不匹配：$tag"
        return 1
      fi
    else
      __cert_path="$(env_var "cert_path")" || return 1
      __key_path="$(env_var "key_path")" || return 1
      if [ -z "$__cert_path" ] || [ -z "$__key_path" ] ||
        ! __pair="$(import_custom_certificate_bundle "$tag" "$__cert_path" "$__key_path")"; then
        print_err "自定义证书文件无效或证书与私钥不匹配：$tag"
        return 1
      fi
    fi
    printf 'custom|%s|%s' "${__pair%|*}" "${__pair#*|}"
    ;;
  self | self-signed)
    __pair="$(ensure_tls_material "$tag" "$domain")" || return 1
    printf 'self-signed|%s|%s' "${__pair%|*}" "${__pair#*|}"
    ;;
  *) print_err "未知证书模式 cert=$__mode"; return 1 ;;
  esac
}
auto_add_vless_reality() {
  local port="$1"
  local tag name uuid reality_server key_output private_key public_key short_id node_json secret_json
  tag="$(generate_tag "vless-reality")" || return 1
  name="$(node_display_name "Reality")" || return 1
  uuid="${ENV_UUID:-$(generate_uuid)}" || return 1
  reality_server="${ENV_VL_SNI:-${DEFAULT_REALITY_SERVER}}"

  private_key="$(manager_env_or_setting "reality_private" "")" || return 1
  public_key="$(manager_env_or_setting "reality_public" "")" || return 1
  if [ -z "${private_key}" ] || [ -z "${public_key}" ]; then
    if [ -n "${private_key}" ] || [ -n "${public_key}" ]; then
      print_warn "reality_private/reality_public 必须成对提供，缺少一项，将重新生成 Reality 密钥对。"
    fi
    if ! key_output="$("${MIHOMO_BIN}" generate reality-keypair)"; then
      print_err "生成 Reality 密钥对失败，跳过 vlrt 节点。"
      return 1
    fi
    private_key="$(printf '%s\n' "$key_output" | sed -n 's/^PrivateKey:[[:space:]]*//p' | head -n 1)" || return 1
    public_key="$(printf '%s\n' "$key_output" | sed -n 's/^PublicKey:[[:space:]]*//p' | head -n 1)" || return 1
  fi
  if [ -z "$private_key" ] || [ -z "$public_key" ]; then
    print_err "无法解析 Reality 密钥对，跳过 vlrt 节点。"
    return 1
  fi
  # 3.1：ENV short_ids 逗号分隔多 short_id（集群客户端用不同短 ID 做入口区分），
  # 无合法项时回退生成单个默认短 ID
  if ! short_id="$(resolve_short_ids "$(env_var "short_ids")")"; then
    short_id="$(generate_hex 4)" || return 1
  fi

  node_json="$(jq -n \
    --arg protocol "vless-reality" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg reality_server "$reality_server" \
    --arg public_key "$public_key" \
    --arg short_id "$short_id" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      reality_server: $reality_server,
      public_key: $public_key,
      short_id: $short_id
    }')" || return 1

  secret_json="$(jq -n \
    --arg uuid "$uuid" \
    --arg private_key "$private_key" '{ uuid: $uuid, private_key: $private_key }')" || return 1

  auto_save_node "$tag" "$node_json" "$secret_json" || return 1
  print_ok "已写入节点：${name} | 端口: ${port}"
}
auto_add_vless_xudp() {
  local port="$1"
  local tag name uuid reality_server key_output private_key public_key short_id node_json secret_json
  tag="$(generate_tag "vless-xudp")" || return 1
  name="$(node_display_name "XUDP")" || return 1
  uuid="${ENV_UUID:-$(generate_uuid)}" || return 1
  reality_server="${ENV_VX_SNI:-${DEFAULT_REALITY_SERVER}}"

  private_key="$(manager_env_or_setting "reality_private" "")" || return 1
  public_key="$(manager_env_or_setting "reality_public" "")" || return 1
  if [ -z "${private_key}" ] || [ -z "${public_key}" ]; then
    if [ -n "${private_key}" ] || [ -n "${public_key}" ]; then
      print_warn "reality_private/reality_public 必须成对提供，缺少一项，将重新生成 Reality 密钥对。"
    fi
    if ! key_output="$("${MIHOMO_BIN}" generate reality-keypair)"; then
      print_err "生成 Reality 密钥对失败，跳过 vxpt 节点。"
      return 1
    fi
    private_key="$(printf '%s\n' "$key_output" | sed -n 's/^PrivateKey:[[:space:]]*//p' | head -n 1)" || return 1
    public_key="$(printf '%s\n' "$key_output" | sed -n 's/^PublicKey:[[:space:]]*//p' | head -n 1)" || return 1
  fi
  if [ -z "$private_key" ] || [ -z "$public_key" ]; then
    print_err "无法解析 Reality 密钥对，跳过 vxpt 节点。"
    return 1
  fi
  if ! short_id="$(resolve_short_ids "$(env_var "short_ids")")"; then
    short_id="$(generate_hex 4)" || return 1
  fi

  node_json="$(jq -n \
    --arg protocol "vless-xudp" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg reality_server "$reality_server" \
    --arg public_key "$public_key" \
    --arg short_id "$short_id" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      reality_server: $reality_server,
      public_key: $public_key,
      short_id: $short_id
    }')" || return 1

  secret_json="$(jq -n \
    --arg uuid "$uuid" \
    --arg private_key "$private_key" '{ uuid: $uuid, private_key: $private_key }')" || return 1

  auto_save_node "$tag" "$node_json" "$secret_json" || return 1
  print_ok "已写入节点：${name} | 端口: ${port} | XUDP Reality"
}
auto_add_vless_ws_tls() {
  local port="$1"
  local tag name uuid preferred_domain host_domain ws_path cert_bundle cert_mode cert_file key_file node_json secret_json ws_mode cdn_port cdn_sni
  tag="$(generate_tag "vless-ws-tls")" || return 1
  name="$(node_display_name "WS-TLS")" || return 1
  uuid="${ENV_UUID:-$(generate_uuid)}" || return 1
  # CDN 连接地址（ws_cdn 设计：脚本专用 > 共享 > 兼容旧名 cdn_host > 内置默认）
  preferred_domain="${ENV_WS_CDN_VLESS_CF_HOST:-${ENV_WS_CDN_CF_HOST:-${ENV_CDN_HOST:-${DEFAULT_CDN_DOMAIN}}}}"
  host_domain="${ENV_WS_HOST:-${DEFAULT_TLS_SERVER}}"
  ws_path="${ENV_WS_PATH:-$(random_ws_path)}" || return 1
  ws_mode="${ENV_WS_MODE:-direct}"
  # CDN 端口：脚本专用 > 共享 > 兼容旧名 cdn_port > 443
  cdn_port="${ENV_WS_CDN_VLESS_CF_PT:-${ENV_WS_CDN_CF_PT:-${ENV_CDN_PORT:-443}}}"
  # CDN 回源域名/SNI（仅 cdn 模式使用）：脚本专用 > 共享 > 内置默认（= 连接地址，与 jyucoeng 语义一致）
  cdn_sni="${ENV_WS_CDN_VLESS_SNI:-${ENV_WS_CDN_SNI:-${preferred_domain}}}"
  case "${ws_mode}" in
  direct | cdn) ;;
  *)
    print_warn "ws_mode=${ws_mode} 非法，回退 direct（可选值：direct|cdn）。"
    ws_mode="direct"
    ;;
  esac
  if [ "${ws_mode}" = "cdn" ]; then
    name="$(node_display_name "CDN")" || return 1
  else
    name="$(node_display_name "WS-TLS")" || return 1
  fi
  if [[ ! "${cdn_port}" =~ ^[0-9]+$ ]] || [ "${cdn_port}" -lt 1 ] || [ "${cdn_port}" -gt 65535 ]; then
    print_warn "cdn_port=${cdn_port} 非法，回退 443。"
    cdn_port=443
  fi
  cert_bundle="$(auto_cert_bundle "$tag" "$host_domain")" || return 1
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "vless-ws-tls" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg preferred_domain "$preferred_domain" \
    --arg host_domain "$host_domain" \
    --arg ws_path "$ws_path" \
    --arg ws_mode "$ws_mode" \
    --argjson cdn_port "$cdn_port" \
    --arg cdn_sni "$cdn_sni" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      preferred_domain: $preferred_domain,
      host_domain: $host_domain,
      ws_path: $ws_path,
      ws_mode: $ws_mode,
      cdn_port: $cdn_port,
      cdn_sni: $cdn_sni,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')" || return 1

  secret_json="$(jq -n --arg uuid "$uuid" '{ uuid: $uuid }')" || return 1

  auto_save_node "$tag" "$node_json" "$secret_json" || return 1
  print_ok "已写入节点：${name} | 端口: ${port}"
}
auto_add_anytls() {
  local port="$1"
  local tag name password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json
  tag="$(generate_tag "anytls")" || return 1
  name="$(node_display_name "AnyTLS")" || return 1
  password="${ENV_PASSWD:-$(generate_hex 8)}" || return 1
  tls_server="${ENV_ANY_SNI:-${DEFAULT_TLS_SERVER}}"
  cert_bundle="$(auto_cert_bundle "$tag" "$tls_server")" || return 1
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "anytls" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg tls_server "$tls_server" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      tls_server: $tls_server,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')" || return 1

  secret_json="$(jq -n --arg password "$password" '{ password: $password }')" || return 1

  auto_save_node "$tag" "$node_json" "$secret_json" || return 1
  print_ok "已写入节点：${name} | 端口: ${port}"
}
auto_add_vless_argo() {
  local port="$1"
  local tag name uuid preferred_domain cdn_port ws_path argo_mode argo_token endpoint_domain node_json secret_json
  tag="$(generate_tag "vless-argo")" || return 1
  name="$(node_display_name "Argo")" || return 1
  uuid="${ENV_UUID:-$(generate_uuid)}" || return 1
  # Argo 专属优选域名/端口（v0.3.3）：独立于 WS-CDN，缺省回退 cdn_host/443
  preferred_domain="${ENV_ARGO_CDN_HOST:-${ENV_CDN_HOST:-${DEFAULT_CDN_DOMAIN}}}"
  cdn_port="${ENV_ARGO_CDN_PORT:-443}"
  if [[ ! "${cdn_port}" =~ ^[0-9]+$ ]] || [ "${cdn_port}" -lt 1 ] || [ "${cdn_port}" -gt 65535 ]; then
    print_warn "argo_cdn_port=${cdn_port} 非法，回退 443。"
    cdn_port=443
  fi
  ws_path="${ENV_WS_PATH:-$(random_ws_path)}" || return 1
  argo_token="$(env_var "agk")" || return 1
  endpoint_domain="$(env_var "agn")" || return 1
  if [ -n "$argo_token" ] && [ -n "$endpoint_domain" ] && is_safe_domain "${endpoint_domain}"; then
    argo_mode="token"
  else
    if [ -n "$argo_token" ] || [ -n "$endpoint_domain" ]; then
      # 与交互路径一致：agn 必须通过域名白名单，防止异常值入库后被 watchdog 消费
      if [ -n "$endpoint_domain" ] && ! is_safe_domain "${endpoint_domain}"; then
        print_warn "Argo 固定隧道 agn=${endpoint_domain} 域名格式无效，已回退临时隧道。"
      else
        print_warn "Argo 固定隧道需要同时提供 agn（域名）和 agk（Token），已回退临时隧道。"
      fi
    fi
    argo_mode="temp"
    argo_token=""
    endpoint_domain=""
  fi

  node_json="$(jq -n \
    --arg protocol "vless-argo" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg preferred_domain "$preferred_domain" \
    --argjson cdn_port "$cdn_port" \
    --arg ws_path "$ws_path" \
    --arg argo_mode "$argo_mode" \
    --arg endpoint_domain "$endpoint_domain" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      preferred_domain: $preferred_domain,
      cdn_port: $cdn_port,
      ws_path: $ws_path,
      argo_mode: $argo_mode,
      endpoint_domain: $endpoint_domain
    }')" || return 1

  secret_json="$(jq -n \
    --arg uuid "$uuid" \
    --arg argo_token "$argo_token" '{ uuid: $uuid, argo_token: $argo_token }')" || return 1

  auto_save_node "$tag" "$node_json" "$secret_json" || return 1
  print_ok "已写入节点：${name} | 本地端口: ${port} | 模式: ${argo_mode}"
}
auto_add_tuic_v5() {
  local port="$1"
  local tag name uuid password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json
  tag="$(generate_tag "tuic-v5")" || return 1
  name="$(node_display_name "TUIC")" || return 1
  uuid="${ENV_UUID:-$(generate_uuid)}" || return 1
  password="${ENV_PASSWD:-$uuid}"
  tls_server="${ENV_TU_SNI:-${DEFAULT_TLS_SERVER}}"
  cert_bundle="$(auto_cert_bundle "$tag" "$tls_server")" || return 1
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "tuic-v5" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg tls_server "$tls_server" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      tls_server: $tls_server,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')" || return 1

  secret_json="$(jq -n --arg uuid "$uuid" --arg password "$password" '{ uuid: $uuid, password: $password }')" || return 1

  auto_save_node "$tag" "$node_json" "$secret_json" || return 1
  print_ok "已写入节点：${name} | 端口: ${port}"
}
auto_add_hy2() {
  local port="$1"
  local tag name password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json
  local __hy_up __hy_down
  tag="$(generate_tag "hy2")" || return 1
  name="$(node_display_name "HY2")" || return 1
  password="${ENV_PASSWD:-$(generate_hex 8)}" || return 1
  tls_server="${ENV_HY_SNI:-${DEFAULT_TLS_SERVER}}"
  # 局部名不用 up_mbps/down_mbps，避免遮蔽同名用户环境变量导致读取为空
  # 默认 200 Mbps（未显式设置时）；只填其一则另一个独立成单方向限速
  __hy_up="$(env_var "up_mbps")" || return 1
  __hy_down="$(env_var "down_mbps")" || return 1
  __hy_up="$(normalize_hy2_mbps "$__hy_up")" || return 1
  __hy_down="$(normalize_hy2_mbps "$__hy_down")" || return 1
  cert_bundle="$(auto_cert_bundle "$tag" "$tls_server")" || return 1
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "hy2" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg tls_server "$tls_server" \
    --argjson up_mbps "$__hy_up" \
    --argjson down_mbps "$__hy_down" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      tls_server: $tls_server,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path,
      up_mbps: $up_mbps,
      down_mbps: $down_mbps
    }')" || return 1

  secret_json="$(jq -n --arg password "$password" '{ password: $password }')" || return 1

  auto_save_node "$tag" "$node_json" "$secret_json" || return 1
  print_ok "已写入节点：${name} | 端口: ${port}"
}
auto_add_socks5() {
  local port="$1"
  local tag name username password node_json secret_json
  tag="$(generate_tag "socks5")" || return 1
  name="$(node_display_name "SOCKS5")" || return 1
  username="${ENV_SOCKS5_USER:-user}"
  password="${ENV_SOCKS5_PASS:-$(generate_hex 6)}" || return 1

  node_json="$(jq -n \
    --arg protocol "socks5" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg username "$username" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      username: $username
    }')" || return 1

  secret_json="$(jq -n --arg password "$password" '{ password: $password }')" || return 1

  auto_save_node "$tag" "$node_json" "$secret_json" || return 1
  print_ok "已写入节点：${name} | 端口: ${port}"
}
auto_install_abort() {
  rollback_pending_transaction || print_err "自动安装回滚未能完整完成，请保留快照检查。"
  if [ "${AUTO_INSTALL_OWNS_LOCK:-false}" = true ]; then release_lock; fi
  return 1
}

auto_install() {
  local action="$1"
  local tag port spec line backup_dir existing_tags requested_sub_mode
  local AUTO_INSTALL_OWNS_LOCK=false
  local ENV_VL_SNI_RAW
  local added=0 failed=0
  local -a specs=()
  local ENV_NAME ENV_UUID ENV_PASSWD
  local ENV_VL_SNI ENV_VX_SNI ENV_TU_SNI ENV_ANY_SNI ENV_HY_SNI ENV_WS_HOST ENV_WS_PATH ENV_CDN_HOST
  local ENV_WS_MODE ENV_CDN_PORT
  local ENV_ARGO_CDN_HOST ENV_ARGO_CDN_PORT
  local ENV_WS_CDN_CF_HOST ENV_WS_CDN_CF_PT ENV_WS_CDN_SNI
  local ENV_WS_CDN_VLESS_CF_HOST ENV_WS_CDN_VLESS_CF_PT ENV_WS_CDN_VLESS_SNI
  local ENV_SOCKS5_USER ENV_SOCKS5_PASS

  if [ -x /usr/local/bin/sbm ] || [ -f /usr/local/etc/singbox-manager/settings.json ]; then
    print_warn "检测到 Singbox Manager。mm 与 sbm 共用 cloudflared，且可能占用相同端口；建议同机只保留一套。"
  fi

  [ -z "${_AUTO_ROLLBACK_DIR:-}" ] || { print_err "已有未提交事务，拒绝嵌套安装。"; return 1; }
  requested_sub_mode="$(env_var "sub_mode")" || return 1
  case "$requested_sub_mode" in
  "" | temp | worker) ;;
  *) print_err "sub_mode 仅支持 temp 或 worker。"; return 2 ;;
  esac

  if ! auto_has_node_env; then
    print_err "未检测到任何节点环境变量（vlrt / vxpt / wspt / tupt / anypt / hypt / socks5pt / argo），放弃安装。"
    print_info "示例：vlrt=2083 hypt=2082 name='HK' mm ${action}"
    return 1
  fi

  # 预校验：端口非法在这里直接失败，任何已有数据都不会被改动
  if ! spec="$(auto_collect_specs)"; then
    print_err "输入校验失败，未更改任何数据。"
    return 1
  fi
  while IFS= read -r line; do
    [ -n "${line}" ] && specs+=("${line}")
  done <<<"${spec}"
  if [ "${#specs[@]}" -eq 0 ]; then
    print_err "未检测到有效的节点端口环境变量，放弃安装。"
    return 1
  fi

  if [ "${LOCK_HELD:-false}" != true ] || [ "${LOCK_OWNER_PID:-}" != "$BASHPID" ]; then
    acquire_lock || return 1
    AUTO_INSTALL_OWNS_LOCK=true
  fi
  init_storage || { auto_install_abort; return 1; }
  local core_prepared=false
  if [ ! -x "${MIHOMO_BIN}" ]; then
    print_info "先准备核心依赖；成功后单独提交，再开始节点事务。"
    ensure_singbox_ready || { auto_install_abort; return 1; }
    core_prepared=true
    print_info "核心准备已完成；后续节点失败将恢复至此状态，已安装的依赖和核心会保留。"
  fi

  # Append and replace share the same exact-snapshot rollback boundary.
  backup_dir="$(backup_state)" || { auto_install_abort; return 1; }
  _AUTO_ROLLBACK_DIR="$backup_dir"
  _AUTO_ROLLBACK_OWNER="$BASHPID"
  if [ "$core_prepared" != true ]; then
    ensure_singbox_ready || { auto_install_abort; return 1; }
  fi
  invalidate_port_caches || { auto_install_abort; return 1; }

  if [ "${action}" = "rep" ]; then
    existing_tags="$(iter_node_tags)" || { auto_install_abort; return 1; }
    while IFS= read -r tag; do
      [ -n "${tag}" ] || continue
      stop_argo_node "${tag}" || { auto_install_abort; return 1; }
    done <<<"$existing_tags"
    stop_service || { auto_install_abort; return 1; }
    wipe_records || { auto_install_abort; return 1; }
    invalidate_port_caches || { auto_install_abort; return 1; }
    print_info "已清空原有节点（备份：${backup_dir}），按环境变量重建。"
  else
    print_info "已备份现有状态：${backup_dir}"
  fi

  ENV_NAME="$(env_var "name")" || { auto_install_abort; return 1; }
  ENV_UUID="$(env_var "uuid")" || { auto_install_abort; return 1; }
  ENV_PASSWD="$(env_var "passwd")" || { auto_install_abort; return 1; }
  # 域名类环境变量经白名单校验，非法值回退内置默认
  ENV_VL_SNI_RAW="$(env_var "vl_sni")" || { auto_install_abort; return 1; }
  if [ -z "${ENV_VL_SNI_RAW}" ] || [ "${ENV_VL_SNI_RAW,,}" = "auto" ]; then
    ENV_VL_SNI="$(detect_sni_best 2>/dev/null || printf '%s' "${DEFAULT_REALITY_SERVER}")" || { auto_install_abort; return 1; }
  else
    ENV_VL_SNI="$(env_domain_or_default "vl_sni" "${DEFAULT_REALITY_SERVER}")" || { auto_install_abort; return 1; }
  fi
  ENV_VX_SNI="$(tls_sni_auto "vx_sni" "${DEFAULT_REALITY_SERVER}")" || { auto_install_abort; return 1; }
  ENV_TU_SNI="$(tls_sni_auto "tu_sni" "${DEFAULT_TLS_SERVER}")" || { auto_install_abort; return 1; }
  ENV_ANY_SNI="$(tls_sni_auto "any_sni" "${DEFAULT_TLS_SERVER}")" || { auto_install_abort; return 1; }
  ENV_HY_SNI="$(tls_sni_auto "hy_sni" "${DEFAULT_TLS_SERVER}")" || { auto_install_abort; return 1; }
  ENV_WS_HOST="$(env_domain_or_default "ws_host" "${DEFAULT_TLS_SERVER}")" || { auto_install_abort; return 1; }
  ENV_WS_PATH="$(env_var "ws_path")" || { auto_install_abort; return 1; }
  ENV_WS_MODE="$(env_var "ws_mode")" || { auto_install_abort; return 1; }
  ENV_CDN_PORT="$(env_var "cdn_port")" || { auto_install_abort; return 1; }
  ENV_CDN_HOST="$(env_domain_or_default "cdn_host" "${DEFAULT_CDN_DOMAIN}")" || { auto_install_abort; return 1; }
  # Argo 专属优选域名/端口（v0.3.3）：与 WS-CDN 独立设置，缺省回退 cdn_host/443
  ENV_ARGO_CDN_HOST="$(env_domain_or_default "argo_cdn_host" "${ENV_CDN_HOST}")" || { auto_install_abort; return 1; }
  ENV_ARGO_CDN_PORT="$(env_var "argo_cdn_port")" || { auto_install_abort; return 1; }
  # ws_cdn 设计（v0.3.0）：脚本专用前缀优先，共享前缀次之，兼容旧名 cdn_host/ws_host/cdn_port 兜底。
  # 域名类变量经白名单校验，空值留给调用方回退链处理。
  ENV_WS_CDN_CF_HOST="$(env_domain_or_default "ws_cdn_cf_host" "")" || { auto_install_abort; return 1; }
  ENV_WS_CDN_CF_PT="$(env_var "ws_cdn_cf_pt")" || { auto_install_abort; return 1; }
  ENV_WS_CDN_SNI="$(env_domain_or_default "ws_cdn_sni" "")" || { auto_install_abort; return 1; }
  ENV_WS_CDN_VLESS_CF_HOST="$(env_domain_or_default "ws_cdn_vless_cf_host" "")" || { auto_install_abort; return 1; }
  ENV_WS_CDN_VLESS_CF_PT="$(env_var "ws_cdn_vless_cf_pt")" || { auto_install_abort; return 1; }
  ENV_WS_CDN_VLESS_SNI="$(env_domain_or_default "ws_cdn_vless_sni" "")" || { auto_install_abort; return 1; }
  # v1.2.4：CDN 采 CF 证书方案（Full/Full-Strict 回源），源站仅一个 TLS WS inbound（wspt），
  # 不再生成明文 HTTP 回源 inbound；ws_cdn_origin_port 已废弃。证书方式支持
  # cert=custom（如 Cloudflare Origin CA 证书）+ cert_path/key_path，自签默认适用于 Full 模式。
  # 默认优选域名仅在 ws_mode=cdn（CDN 中转）时要求本机已接入前置 CDN；直连模式（默认）不依赖 cdn_host
  if [ "${ENV_CDN_HOST}" = "${DEFAULT_CDN_DOMAIN}" ] && [ "${ENV_WS_MODE:-direct}" = "cdn" ] && [ "${confirm_default_cdn:-}" != "1" ]; then
    print_warn "⚠️ 未设置有效 cdn_host：WS-TLS(CDN 中转) 节点将使用内置优选域名 ${DEFAULT_CDN_DOMAIN}（仅该域名已接入本机前置 CDN 时可达）。"
    print_warn "   请改用 cdn_host=你的优选域名或IP 重新执行；确认使用默认值可加 confirm_default_cdn=1 消除本提示。"
  fi
  ENV_SOCKS5_USER="$(env_var "socks5_username")" || { auto_install_abort; return 1; }
  ENV_SOCKS5_PASS="$(env_var "socks5_password")" || { auto_install_abort; return 1; }

  # P5/S3：持久化性能与调优参数（go_gc / net_tune / 内存上限），使 rep、重启、
  # watchdog 等后续流程在无 install 环境变量时也能读取同一套全局配置。
  local _key _val
  for _key in go_gc net_tune mem_high_mb mem_max_mb server_ip direct_host reality_private reality_public debug_flag socks5_wl_flag socks5_ips; do
    _val="$(env_var "$_key")" || { auto_install_abort; return 1; }
    if [ -n "${_val}" ]; then
      set_setting "$_key" "$_val" || { auto_install_abort; return 1; }
    fi
  done

  for line in "${specs[@]}"; do
    port="${line##* }"
    case "${line%% *}" in
    vless-reality)
      if auto_try_port "$port" "VLESS-Reality"; then
        auto_add_vless_reality "$port" && added=$((added + 1)) || failed=$((failed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    vless-xudp)
      if auto_try_port "$port" "VLESS-XUDP-Reality"; then
        auto_add_vless_xudp "$port" && added=$((added + 1)) || failed=$((failed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    vless-ws-tls)
      if auto_try_port "$port" "VLESS-WS-TLS"; then
        auto_add_vless_ws_tls "$port" && added=$((added + 1)) || failed=$((failed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    anytls)
      if auto_try_port "$port" "AnyTLS"; then
        auto_add_anytls "$port" && added=$((added + 1)) || failed=$((failed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    vless-argo)
      if auto_try_port "$port" "VLESS-Argo"; then
        auto_add_vless_argo "$port" && added=$((added + 1)) || failed=$((failed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    tuic-v5)
      if auto_try_port "$port" "TUIC-v5"; then
        auto_add_tuic_v5 "$port" && added=$((added + 1)) || failed=$((failed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    hy2)
      if auto_try_port "$port" "Hysteria2"; then
        auto_add_hy2 "$port" && added=$((added + 1)) || failed=$((failed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    socks5)
      if auto_try_port "$port" "SOCKS5"; then
        auto_add_socks5 "$port" && added=$((added + 1)) || failed=$((failed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    esac
  done

  if [ "$added" -eq 0 ] || [ "$failed" -gt 0 ]; then
    print_err "节点事务失败（added=$added, failed=$failed），恢复本次操作前的完整状态。"
    auto_install_abort
    return 1
  fi

  if [ "${action}" = "rep" ]; then
    cleanup_orphan_certs || { auto_install_abort; return 1; }
  fi
  # An omitted subscription option preserves the installed Worker configuration.
  local _sub_mode _sub_switch
  _sub_mode="$(env_var "sub_mode")" || { auto_install_abort; return 1; }
  [ -z "$_sub_mode" ] || set_setting sub_mode "$_sub_mode" || { auto_install_abort; return 1; }
  for _key in sub_domain sub_read_token sub_report_token sub_machine; do
    _val="$(env_var "$_key")" || { auto_install_abort; return 1; }
    [ -z "$_val" ] || set_setting "$_key" "$_val" || { auto_install_abort; return 1; }
  done
  _sub_switch="$(env_var "sub")" || { auto_install_abort; return 1; }
  case "${_sub_switch,,}" in
  1 | on | yes | true) set_setting sub_enabled 1 || { auto_install_abort; return 1; } ;;
  0 | off | no | false) set_setting sub_enabled 0 || { auto_install_abort; return 1; } ;;
  esac
  render_config || { auto_install_abort; return 1; }
  reload_service || { auto_install_abort; return 1; }
  restart_all_argo_nodes || { auto_install_abort; return 1; }
  sanitize_permissions || { auto_install_abort; return 1; }
  _AUTO_ROLLBACK_DIR=""
  _AUTO_ROLLBACK_OWNER=""
  if sub_enabled; then
    sub_start || print_warn "订阅链接启动失败，可稍后在菜单/命令行重试。"
  elif [ -n "$_sub_switch" ]; then
    sub_stop || print_warn "订阅入口停止失败，请检查本实例进程。"
  fi
  if [ "$AUTO_INSTALL_OWNS_LOCK" = true ]; then release_lock; fi

  echo
  print_ok "一键安装完成：新增 ${added} 个节点，失败 ${failed} 个。"
  echo
  print_node_list
  if [ -s "$(sub_url_file)" ]; then
    echo "订阅链接：$(cat "$(sub_url_file)")"
    echo
  fi
  echo
  return 0
}
