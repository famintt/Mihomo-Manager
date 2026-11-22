#!/usr/bin/env bash
set -eEuo pipefail

umask 077

# 收集证书选项不写盘，避免用户输入期间持有全局锁。
_collect_add_certificate() {
  while true; do
    cert_mode="$(prompt_choice '证书模式 (self-signed/custom)' self-signed)" || return 1
    case "$cert_mode" in
      self-signed | self | quick)
        cert_mode=self-signed
        cert_source=''; key_source=''
        return 0
        ;;
      custom)
        cert_source="$(prompt_nonempty '证书路径')" || return 1
        key_source="$(prompt_nonempty '私钥路径')" || return 1
        if _validate_certificate_bundle "$cert_source" "$key_source"; then return 0; fi
        print_warn '证书或私钥无效，请重新选择。'
        ;;
      *) print_warn '请输入 self-signed 或 custom。' ;;
    esac
  done
}

_create_add_certificate() {
  local tag="$1" domain="$2" mode="$3" source="$4" key="$5" pair
  if [ "$mode" = custom ]; then
    pair="$(import_custom_certificate_bundle "$tag" "$source" "$key")" || return 1
  else
    pair="$(ensure_tls_material "$tag" "$domain")" || return 1
  fi
  printf '%s|%s' "$mode" "$pair"
}

_begin_node_add() {
  local port="$1" tag="$2" snapshot
  if [ -n "${_AUTO_ROLLBACK_DIR:-}" ] || [ -n "${_AUTO_ROLLBACK_OWNER:-}" ]; then
    print_err '已有未提交事务，拒绝替换回滚标记。'
    return 1
  fi
  acquire_lock || return 1
  invalidate_port_caches
  if ! validate_storage_tables || ! port_available "$port"; then
    print_err "端口 $port 已被占用或状态文件无效，请重新选择。"
    release_lock
    return 1
  fi
  # tag 也在锁内复验，随机标签碰撞不可覆盖已有节点。
  if ! jq -e --arg tag "$tag" 'has($tag) | not' "${NODES_FILE}" >/dev/null; then
    print_err "节点标签已存在或无法读取：$tag"
    release_lock
    return 1
  fi
  snapshot="$(backup_state)" || { release_lock; return 1; }
  _AUTO_ROLLBACK_DIR="$snapshot"
  _AUTO_ROLLBACK_OWNER="$BASHPID"
}

_abort_node_add() {
  local rc=0
  # Pre-transaction prompt failures must not release a caller-owned lock.
  [ -n "${_AUTO_ROLLBACK_DIR:-}" ] || return 0
  if [ "${_AUTO_ROLLBACK_OWNER:-}" != "${BASHPID}" ] ||
    [ "${LOCK_HELD:-false}" != true ] || [ "${LOCK_OWNER_PID:-}" != "${BASHPID}" ]; then
    print_err '事务回滚标记与当前进程锁不匹配。'
    return 1
  fi
  rollback_pending_transaction || rc=1
  release_lock || rc=1
  return "$rc"
}

_commit_node_add() {
  if [ -z "${_AUTO_ROLLBACK_DIR:-}" ] ||
    [ "${_AUTO_ROLLBACK_OWNER:-}" != "${BASHPID}" ] ||
    [ "${LOCK_HELD:-false}" != true ] || [ "${LOCK_OWNER_PID:-}" != "${BASHPID}" ]; then
    print_err '没有当前进程持有的待提交节点事务。'
    return 1
  fi
  if ! sanitize_permissions; then _abort_node_add; return 1; fi
  _AUTO_ROLLBACK_DIR=''
  _AUTO_ROLLBACK_OWNER=''
  release_lock
}

prompt_reality_sni() {
  local value detected
  while true; do
    value="$(prompt_with_default "Reality 域名（留空/auto 自动检测）" "auto")" || return 1
    case "${value,,}" in
    "" | auto)
      print_info "正在检测 Reality SNI（TLS 1.3 + HTTP/2）..." >&2
      if declare -F detect_sni_best >/dev/null 2>&1; then
        detected="$(detect_sni_best 2>/dev/null || true)"
        if [ -n "${detected}" ]; then
          print_ok "自动选择：${detected}" >&2
          printf '%s' "${detected}"
          return 0
        fi
      fi
      print_warn "自动检测失败，回退 ${DEFAULT_REALITY_SERVER}；建议稍后运行 mm sni 手动指定。"
      printf '%s' "${DEFAULT_REALITY_SERVER}"
      return 0
      ;;
    *)
      if is_safe_domain "${value}"; then
        printf '%s' "${value}"
        return 0
      fi
      print_warn "域名格式无效：${value}"
      ;;
    esac
  done
}

prompt_tls_sni() {
  local value detected
  while true; do
    value="$(prompt_with_default "SNI 域名（留空=${DEFAULT_TLS_SERVER}；输入 auto 自动检测；自定义证书必须填写证书域名）" "${DEFAULT_TLS_SERVER}")" || return 1
    case "${value,,}" in
    "" | auto)
      if [ "${value}" = "" ]; then
        printf '%s' "${DEFAULT_TLS_SERVER}"
        return 0
      fi
      print_info "正在检测 TLS SNI（TLS 1.3 + HTTP/2）..." >&2
      if declare -F detect_sni_best >/dev/null 2>&1; then
        detected="$(detect_sni_best 2>/dev/null || true)"
        if [ -n "${detected}" ]; then
          print_ok "自动选择：${detected}" >&2
          printf '%s' "${detected}"
          return 0
        fi
      fi
      print_warn "自动检测失败，回退 ${DEFAULT_TLS_SERVER}；请稍后手动指定。" >&2
      printf '%s' "${DEFAULT_TLS_SERVER}"
      return 0
      ;;
    *)
      if is_safe_domain "${value}"; then
        printf '%s' "${value}"
        return 0
      fi
      print_warn "域名格式无效：${value}" >&2
      ;;
    esac
  done
}

add_vless_reality() {
  local tag port name uuid reality_server key_output private_key public_key short_id node_json secret_json
  ensure_singbox_ready || return 1
  tag="$(generate_tag "vless-reality")" || { _abort_node_add || true; return 1; }
  port="$(prompt_port 443)" || return 1
  port="$(normalize_node_port "$port")" || return 1
  name="$(prompt_with_default "节点名称" "$(node_display_name "Reality")")" || { _abort_node_add || true; return 1; }
  uuid="$(prompt_optional_value "UUID（留空自动生成）")" || { _abort_node_add || true; return 1; }
  uuid="${uuid:-$(generate_uuid)}" || { _abort_node_add || true; return 1; }
  reality_server="$(prompt_reality_sni)" || { _abort_node_add || true; return 1; }

  key_output="$("${MIHOMO_BIN}" generate reality-keypair)" || { _abort_node_add || true; return 1; }
  private_key="$(printf '%s\n' "$key_output" | sed -n 's/^PrivateKey:[[:space:]]*//p' | head -n 1)" || { _abort_node_add || true; return 1; }
  public_key="$(printf '%s\n' "$key_output" | sed -n 's/^PublicKey:[[:space:]]*//p' | head -n 1)" || { _abort_node_add || true; return 1; }
  [ -n "$private_key" ] || fatal "无法解析 Reality 私钥。"
  [ -n "$public_key" ] || fatal "无法解析 Reality 公钥。"
  short_id="$(generate_hex 4)" || { _abort_node_add || true; return 1; }

  _begin_node_add "$port" "$tag" || return 1
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
    }')" || { _abort_node_add || true; return 1; }

  secret_json="$(jq -n \
    --arg uuid "$uuid" \
    --arg private_key "$private_key" '{ uuid: $uuid, private_key: $private_key }')" || { _abort_node_add || true; return 1; }

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! reload_service; then
    _abort_node_add || true
    print_err "添加节点失败：${name}"
    return 1
  fi

  _commit_node_add || return 1
  print_ok "已添加节点：${name}"
}

add_vless_xudp() {
  local tag port name uuid reality_server key_output private_key public_key short_id node_json secret_json
  ensure_singbox_ready || return 1
  tag="$(generate_tag "vless-xudp")" || { _abort_node_add || true; return 1; }
  port="$(prompt_port 5444)" || return 1
  port="$(normalize_node_port "$port")" || return 1
  name="$(prompt_with_default "节点名称" "$(node_display_name "XUDP")")" || { _abort_node_add || true; return 1; }
  uuid="$(prompt_optional_value "UUID（留空自动生成）")" || { _abort_node_add || true; return 1; }
  uuid="${uuid:-$(generate_uuid)}" || { _abort_node_add || true; return 1; }
  reality_server="$(prompt_reality_sni)" || { _abort_node_add || true; return 1; }

  key_output="$("${MIHOMO_BIN}" generate reality-keypair)" || { _abort_node_add || true; return 1; }
  private_key="$(printf '%s\n' "$key_output" | sed -n 's/^PrivateKey:[[:space:]]*//p' | head -n 1)" || { _abort_node_add || true; return 1; }
  public_key="$(printf '%s\n' "$key_output" | sed -n 's/^PublicKey:[[:space:]]*//p' | head -n 1)" || { _abort_node_add || true; return 1; }
  [ -n "$private_key" ] || fatal "无法解析 Reality 私钥。"
  [ -n "$public_key" ] || fatal "无法解析 Reality 公钥。"
  short_id="$(generate_hex 4)" || { _abort_node_add || true; return 1; }

  _begin_node_add "$port" "$tag" || return 1
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
    }')" || { _abort_node_add || true; return 1; }

  secret_json="$(jq -n \
    --arg uuid "$uuid" \
    --arg private_key "$private_key" '{ uuid: $uuid, private_key: $private_key }')" || { _abort_node_add || true; return 1; }

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! reload_service; then
    _abort_node_add || true
    print_err "添加节点失败：${name}"
    return 1
  fi

  _commit_node_add || return 1
  print_ok "已添加节点：${name}"
}

add_vless_ws_tls() {
  local tag port name uuid preferred_domain host_domain ws_path cert_bundle cert_mode cert_source key_source cert_file key_file node_json secret_json
  ensure_singbox_ready || return 1
  tag="$(generate_tag "vless-ws-tls")" || { _abort_node_add || true; return 1; }
  port="$(prompt_port 8443)" || return 1
  port="$(normalize_node_port "$port")" || return 1
  name="$(prompt_with_default "节点名称" "$(node_display_name "WS-TLS")")" || { _abort_node_add || true; return 1; }
  uuid="$(prompt_optional_value "UUID（留空自动生成）")" || { _abort_node_add || true; return 1; }
  uuid="${uuid:-$(generate_uuid)}" || { _abort_node_add || true; return 1; }
  preferred_domain="$(prompt_cdn_domain)" || { _abort_node_add || true; return 1; }
  host_domain="$(prompt_safe_domain "Host/SNI 域名" "${DEFAULT_TLS_SERVER}")" || { _abort_node_add || true; return 1; }
  ws_path="$(prompt_with_default "WebSocket 路径" "$(random_ws_path)")" || { _abort_node_add || true; return 1; }
  [[ "$ws_path" = /* ]] || ws_path="/$ws_path"
  _collect_add_certificate || return 1
  _begin_node_add "$port" "$tag" || return 1
  cert_bundle="$(_create_add_certificate "$tag" "$host_domain" "$cert_mode" "$cert_source" "$key_source")" || { _abort_node_add || true; return 1; }
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
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      preferred_domain: $preferred_domain,
      host_domain: $host_domain,
      ws_path: $ws_path,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')" || { _abort_node_add || true; return 1; }

  secret_json="$(jq -n --arg uuid "$uuid" '{ uuid: $uuid }')" || { _abort_node_add || true; return 1; }

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! reload_service; then
    _abort_node_add || true
    print_err "添加节点失败：${name}"
    return 1
  fi

  _commit_node_add || return 1
  print_ok "已添加节点：${name}"
}

add_anytls() {
  local tag port name password tls_server cert_bundle cert_mode cert_source key_source cert_file key_file node_json secret_json
  ensure_singbox_ready || return 1
  tag="$(generate_tag "anytls")" || { _abort_node_add || true; return 1; }
  port="$(prompt_port 5443)" || return 1
  port="$(normalize_node_port "$port")" || return 1
  name="$(prompt_with_default "节点名称" "$(node_display_name "AnyTLS")")" || { _abort_node_add || true; return 1; }
  password="$(prompt_optional_value "密码（留空自动生成）")" || { _abort_node_add || true; return 1; }
  password="${password:-$(generate_hex 8)}" || { _abort_node_add || true; return 1; }
  tls_server="$(prompt_tls_sni)" || { _abort_node_add || true; return 1; }
  _collect_add_certificate || return 1
  _begin_node_add "$port" "$tag" || return 1
  cert_bundle="$(_create_add_certificate "$tag" "$tls_server" "$cert_mode" "$cert_source" "$key_source")" || { _abort_node_add || true; return 1; }
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
    }')" || { _abort_node_add || true; return 1; }

  secret_json="$(jq -n --arg password "$password" '{ password: $password }')" || { _abort_node_add || true; return 1; }

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! reload_service; then
    _abort_node_add || true
    print_err "添加节点失败：${name}"
    return 1
  fi

  _commit_node_add || return 1
  print_ok "已添加节点：${name}"
}

add_vless_argo() {
  local tag port name uuid preferred_domain ws_path argo_mode argo_token endpoint_domain node_json secret_json
  ensure_singbox_ready || return 1
  tag="$(generate_tag "vless-argo")" || { _abort_node_add || true; return 1; }
  port="$(prompt_port 8001)" || return 1
  port="$(normalize_node_port "$port")" || return 1
  name="$(prompt_with_default "节点名称" "$(node_display_name "Argo")")" || { _abort_node_add || true; return 1; }
  uuid="$(prompt_optional_value "UUID（留空自动生成）")" || { _abort_node_add || true; return 1; }
  uuid="${uuid:-$(generate_uuid)}" || { _abort_node_add || true; return 1; }
  preferred_domain="$(prompt_cdn_domain)" || { _abort_node_add || true; return 1; }
  ws_path="$(prompt_with_default "WebSocket 路径" "$(random_ws_path)")" || { _abort_node_add || true; return 1; }
  [[ "$ws_path" = /* ]] || ws_path="/$ws_path"
  argo_mode="$(prompt_choice "隧道模式 (temp/token)" "temp")" || { _abort_node_add || true; return 1; }
  if [ "${argo_mode}" = "token" ]; then
    argo_token="$(prompt_nonempty "Cloudflared 隧道 Token")" || { _abort_node_add || true; return 1; }
    endpoint_domain="$(prompt_nonempty "Argo 回源域名")" || { _abort_node_add || true; return 1; }
    if ! is_safe_domain "${endpoint_domain}"; then
      print_warn "回源域名格式无效：${endpoint_domain}，已回退临时隧道。"
      argo_mode="temp"
      argo_token=""
      endpoint_domain=""
    fi
  else
    argo_mode="temp"
    argo_token=""
    endpoint_domain=""
  fi

  _begin_node_add "$port" "$tag" || return 1
  node_json="$(jq -n \
    --arg protocol "vless-argo" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg preferred_domain "$preferred_domain" \
    --arg ws_path "$ws_path" \
    --arg argo_mode "$argo_mode" \
    --arg endpoint_domain "$endpoint_domain" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      preferred_domain: $preferred_domain,
      ws_path: $ws_path,
      argo_mode: $argo_mode,
      endpoint_domain: $endpoint_domain
    }')" || { _abort_node_add || true; return 1; }

  secret_json="$(jq -n \
    --arg uuid "$uuid" \
    --arg argo_token "$argo_token" '{ uuid: $uuid, argo_token: $argo_token }')" || { _abort_node_add || true; return 1; }

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! reload_service || ! start_argo_node "$tag"; then
    # L12：先显式停掉可能已启动的 cloudflared 隧道，避免回滚后进程残留/孤儿 PID
    stop_argo_node "$tag" 2>/dev/null || true
    _abort_node_add || true
    print_err "添加节点失败：${name}"
    return 1
  fi

  _commit_node_add || return 1
  print_ok "已添加节点：${name}"
}

add_tuic_v5() {
  local tag port name uuid password tls_server cert_bundle cert_mode cert_source key_source cert_file key_file node_json secret_json
  ensure_singbox_ready || return 1
  tag="$(generate_tag "tuic-v5")" || { _abort_node_add || true; return 1; }
  port="$(prompt_port 10443)" || return 1
  port="$(normalize_node_port "$port")" || return 1
  name="$(prompt_with_default "节点名称" "$(node_display_name "TUIC")")" || { _abort_node_add || true; return 1; }
  uuid="$(prompt_optional_value "UUID（留空自动生成）")" || { _abort_node_add || true; return 1; }
  uuid="${uuid:-$(generate_uuid)}" || { _abort_node_add || true; return 1; }
  password="$(prompt_optional_value "密码（留空自动生成）")" || { _abort_node_add || true; return 1; }
  password="${password:-$uuid}"
  tls_server="$(prompt_tls_sni)" || { _abort_node_add || true; return 1; }
  _collect_add_certificate || return 1
  _begin_node_add "$port" "$tag" || return 1
  cert_bundle="$(_create_add_certificate "$tag" "$tls_server" "$cert_mode" "$cert_source" "$key_source")" || { _abort_node_add || true; return 1; }
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
    }')" || { _abort_node_add || true; return 1; }

  secret_json="$(jq -n --arg uuid "$uuid" --arg password "$password" '{ uuid: $uuid, password: $password }')" || { _abort_node_add || true; return 1; }

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! reload_service; then
    _abort_node_add || true
    print_err "添加节点失败：${name}"
    return 1
  fi

  _commit_node_add || return 1
  print_ok "已添加节点：${name}"
}

add_hy2() {
  local tag port name password tls_server cert_bundle cert_mode cert_source key_source cert_file key_file node_json secret_json up_mbps down_mbps
  ensure_singbox_ready || return 1
  tag="$(generate_tag "hy2")" || { _abort_node_add || true; return 1; }
  port="$(prompt_port 11443)" || return 1
  port="$(normalize_node_port "$port")" || return 1
  name="$(prompt_with_default "节点名称" "$(node_display_name "HY2")")" || { _abort_node_add || true; return 1; }
  password="$(prompt_optional_value "密码（留空自动生成）")" || { _abort_node_add || true; return 1; }
  password="${password:-$(generate_hex 8)}" || { _abort_node_add || true; return 1; }
  tls_server="$(prompt_tls_sni)" || { _abort_node_add || true; return 1; }
  # 带宽须为非负整数（留空=默认 200，0=不限速），非数字/负数直接拒收重输；
  # 非数字会被 jq --argjson 当成非法 JSON 中断，必须在此拦截。
  up_mbps="$(prompt_optional_value "上行带宽 Mbps（留空=默认 200，0=不限速）")" || { _abort_node_add || true; return 1; }
  while ! up_mbps="$(normalize_hy2_mbps "${up_mbps}")"; do
    print_warn "上行带宽应为非负整数（Mbps）。"
    up_mbps="$(prompt_optional_value "上行带宽 Mbps（留空=默认 200，0=不限速）")" || { _abort_node_add || true; return 1; }
  done
  up_mbps="${up_mbps:-200}"
  down_mbps="$(prompt_optional_value "下行带宽 Mbps（留空=默认 200，0=不限速）")" || { _abort_node_add || true; return 1; }
  while ! down_mbps="$(normalize_hy2_mbps "${down_mbps}")"; do
    print_warn "下行带宽应为非负整数（Mbps）。"
    down_mbps="$(prompt_optional_value "下行带宽 Mbps（留空=默认 200，0=不限速）")" || { _abort_node_add || true; return 1; }
  done
  down_mbps="${down_mbps:-200}"
  _collect_add_certificate || return 1
  _begin_node_add "$port" "$tag" || return 1
  cert_bundle="$(_create_add_certificate "$tag" "$tls_server" "$cert_mode" "$cert_source" "$key_source")" || { _abort_node_add || true; return 1; }
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "hy2" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg tls_server "$tls_server" \
    --argjson up_mbps "$up_mbps" \
    --argjson down_mbps "$down_mbps" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      tls_server: $tls_server,
      up_mbps: $up_mbps,
      down_mbps: $down_mbps,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')" || { _abort_node_add || true; return 1; }

  secret_json="$(jq -n --arg password "$password" '{ password: $password }')" || { _abort_node_add || true; return 1; }

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! reload_service; then
    _abort_node_add || true
    print_err "添加节点失败：${name}"
    return 1
  fi

  _commit_node_add || return 1
  print_ok "已添加节点：${name}"
}

add_socks5() {
  local tag port name username password node_json secret_json
  ensure_singbox_ready || return 1
  tag="$(generate_tag "socks5")" || { _abort_node_add || true; return 1; }
  port="$(prompt_port 1080)" || return 1
  port="$(normalize_node_port "$port")" || return 1
  name="$(prompt_with_default "节点名称" "$(node_display_name "SOCKS5")")" || { _abort_node_add || true; return 1; }
  username="$(prompt_with_default "用户名" "user")" || { _abort_node_add || true; return 1; }
  password="$(prompt_optional_value "密码（留空自动生成）")" || { _abort_node_add || true; return 1; }
  password="${password:-$(generate_hex 6)}" || { _abort_node_add || true; return 1; }

  _begin_node_add "$port" "$tag" || return 1
  node_json="$(jq -n \
    --arg protocol "socks5" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg username "$username" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      username: $username
    }')" || { _abort_node_add || true; return 1; }

  secret_json="$(jq -n --arg password "$password" '{ password: $password }')" || { _abort_node_add || true; return 1; }

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! reload_service; then
    _abort_node_add || true
    print_err "添加节点失败：${name}"
    return 1
  fi

  _commit_node_add || return 1
  print_ok "已添加节点：${name}"
}
