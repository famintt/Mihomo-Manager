#!/usr/bin/env bash
set -eEuo pipefail

umask 077

# 9.2：CERT_FP_CACHE 声明于 env.sh（见注释；此处勿再 declare，避免函数作用域遮蔽）。
# 9.4：自签证书优先 ECDSA P-256（握手计算量小、公钥短，移动端低能耗），
# 旧 OpenSSL 不支持 EC 时的回退 RSA-2048；两者均先试 -addext，不支持时回退 -extfile。
_generate_self_signed() {
  local key_file="$1" cert_file="$2" domain="$3"
  local saf extfile alg
  if is_ip_address "$domain"; then
    saf="subjectAltName=IP:${domain}"
  else
    saf="subjectAltName=DNS:${domain}"
  fi

  local -a algs=()
  if openssl ecparam -name prime256v1 -check >/dev/null 2>&1; then
    algs+=(ecdsa)
  fi
  algs+=(rsa)

  for alg in "${algs[@]}"; do
    if [ "${alg}" = "ecdsa" ]; then
      if openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 36135 \
        -keyout "${key_file}" -out "${cert_file}" -subj "/CN=${domain}" \
        -addext "${saf}" >/dev/null 2>&1; then
        return 0
      fi
      extfile="$(mktemp "${CERT_DIR}/.ext.XXXXXX")"
      printf '%s\n' "${saf}" >"${extfile}"
      if openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 36135 \
        -keyout "${key_file}" -out "${cert_file}" -subj "/CN=${domain}" \
        -extfile "${extfile}" >/dev/null 2>&1; then
        rm -f "${extfile}"
        return 0
      fi
      rm -f "${extfile}"
    else
      if openssl req -x509 -newkey rsa:2048 -nodes -days 36135 \
        -keyout "${key_file}" -out "${cert_file}" -subj "/CN=${domain}" \
        -addext "${saf}" >/dev/null 2>&1; then
        return 0
      fi
      extfile="$(mktemp "${CERT_DIR}/.ext.XXXXXX")"
      printf '%s\n' "${saf}" >"${extfile}"
      if openssl req -x509 -newkey rsa:2048 -nodes -days 36135 \
        -keyout "${key_file}" -out "${cert_file}" -subj "/CN=${domain}" \
        -extfile "${extfile}" >/dev/null 2>&1; then
        rm -f "${extfile}"
        return 0
      fi
      rm -f "${extfile}"
    fi
  done
  return 1
}

# Validate a PEM certificate/private key pair noninteractively.
_validate_certificate_bundle() {
  local cert_file="$1" key_file="$2" cert_pub key_pub
  openssl x509 -in "$cert_file" -noout >/dev/null 2>&1 || return 1
  openssl pkey -in "$key_file" -passin pass: -noout >/dev/null 2>&1 || return 1
  cert_pub="$(openssl x509 -in "$cert_file" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 -r 2>/dev/null | awk '{print $1}')" || return 1
  key_pub="$(openssl pkey -in "$key_file" -passin pass: -pubout -outform DER 2>/dev/null | openssl dgst -sha256 -r 2>/dev/null | awk '{print $1}')" || return 1
  [ -n "$cert_pub" ] && [ "$cert_pub" = "$key_pub" ] || return 1
  openssl verify -trusted "$cert_file" -partial_chain "$cert_file" >/dev/null 2>&1
}

_publish_certificate_bundle() {
  local tag="$1" cert_source="$2" key_source="$3" cert_file key_file stage had_cert=false had_key=false
  [[ "$tag" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  cert_file="${CERT_DIR}/${tag}.custom.crt"; key_file="${CERT_DIR}/${tag}.custom.key"
  stage="$(mktemp -d "${CERT_DIR}/.cert-import.XXXXXX")" || return 1
  if ! cp -- "$cert_source" "${stage}/candidate.crt" || ! cp -- "$key_source" "${stage}/candidate.key" || ! _validate_certificate_bundle "${stage}/candidate.crt" "${stage}/candidate.key"; then rm -rf -- "$stage"; return 1; fi
  chmod 600 "${stage}/candidate.crt" "${stage}/candidate.key" || { rm -rf -- "$stage"; return 1; }
  if [ -e "$cert_file" ] || [ -L "$cert_file" ]; then mv -- "$cert_file" "${stage}/previous.crt" || { rm -rf -- "$stage"; return 1; }; had_cert=true; fi
  if [ -e "$key_file" ] || [ -L "$key_file" ]; then
    if ! mv -- "$key_file" "${stage}/previous.key"; then [ "$had_cert" = false ] || mv -- "${stage}/previous.crt" "$cert_file"; rm -rf -- "$stage"; return 1; fi
    had_key=true
  fi
  if ! mv -- "${stage}/candidate.crt" "$cert_file" || ! mv -- "${stage}/candidate.key" "$key_file"; then
    rm -f -- "$cert_file" "$key_file"
    [ "$had_cert" = false ] || mv -- "${stage}/previous.crt" "$cert_file"
    [ "$had_key" = false ] || mv -- "${stage}/previous.key" "$key_file"
    rm -rf -- "$stage"; return 1
  fi
  if declare -F service_certificate_permissions >/dev/null; then
    if ! service_certificate_permissions "$cert_file" "$key_file"; then rm -f -- "$cert_file" "$key_file"; [ "$had_cert" = false ] || mv -- "${stage}/previous.crt" "$cert_file"; [ "$had_key" = false ] || mv -- "${stage}/previous.key" "$key_file"; rm -rf -- "$stage"; return 1; fi
  elif ! chmod 600 "$cert_file" "$key_file"; then rm -f -- "$cert_file" "$key_file"; [ "$had_cert" = false ] || mv -- "${stage}/previous.crt" "$cert_file"; [ "$had_key" = false ] || mv -- "${stage}/previous.key" "$key_file"; rm -rf -- "$stage"; return 1
  fi
  rm -rf -- "$stage"
  printf '%s|%s' "$cert_file" "$key_file"
}

ensure_tls_material() {
  local tag="$1" domain="$2" cert_file key_file
  [[ "$tag" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  cert_file="${CERT_DIR}/${tag}.crt"; key_file="${CERT_DIR}/${tag}.key"
  if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then _generate_self_signed "$key_file" "$cert_file" "$domain" || { rm -f -- "$cert_file" "$key_file"; print_err "自签证书生成失败（含 SAN）：${domain}"; return 1; }; fi
  _validate_certificate_bundle "$cert_file" "$key_file" || { print_err "证书或私钥无效：${tag}"; return 1; }
  if declare -F service_certificate_permissions >/dev/null; then service_certificate_permissions "$cert_file" "$key_file" || return 1; else chmod 600 "$cert_file" "$key_file" || return 1; fi
  printf '%s|%s' "$cert_file" "$key_file"
}

cert_covers_host() {
  local cert_file="$1" host="$2" result
  [ -f "$cert_file" ] && [ -n "$host" ] || return 1
  openssl x509 -in "$cert_file" -noout >/dev/null 2>&1 || return 1
  # OpenSSL 1.1.1 may return zero for a mismatch; require its positive result too.
  if is_ip_address "$host"; then
    result="$(LC_ALL=C openssl x509 -in "$cert_file" -noout -checkip "$host" 2>/dev/null)" || return 1
    [ "$result" = "IP $host does match certificate" ]
  else
    result="$(LC_ALL=C openssl x509 -in "$cert_file" -noout -checkhost "$host" 2>/dev/null)" || return 1
    [ "$result" = "Hostname $host does match certificate" ]
  fi
}

# 分享链接是否需要跳过证书校验（追加 insecure/pinSHA256/allowInsecure）：
#   - 自签（self-signed）→ 是；
#   - 自定义证书且本机配置了证书文件 → 证书不覆盖目标 SNI 时是（自定义证书 +
#     伪装 SNI 部署，客户端常规校验必然失败）；证书覆盖目标主机名为否；
#   - 自定义/无证书文件（未配置本地证书的受信部署）→ 否（无据可依，保持旧行为）。
# 输出 0=需要跳过校验（需加 insecure），1=不需要。
cert_needs_insecure() {
  local cert_mode="$1" cert_file="$2" host="$3"
  [ "${cert_mode}" = "self-signed" ] && return 0
  [ -n "${cert_file}" ] && [ -f "${cert_file}" ] || return 1
  ! cert_covers_host "${cert_file}" "${host}"
}

cert_fingerprint() {
  local cert_file="$1"
  [ -f "${cert_file}" ] || return 1
  # 9.2：mtime 指纹缓存——同证书重复计算（ldc/分享链接）只做一次 openssl
  local mtime cached key
  mtime="$(stat -c %Y "${cert_file}" 2>/dev/null || true)"
  [ -n "${mtime}" ] || mtime=""
  key="${cert_file}|${mtime}"
  # L7：关联数组下标 -v 检测要求 bash >= 4.3，而 require_bash4 仅保证 >= 4.0，
  # 改用 ${arr[key]+set} 惯用法（bash 3.0+ 通吃），避免低版本运行时数组未定义告警。
  if [[ "${CERT_FP_CACHE[$key]+set}" = "set" ]]; then
    printf '%s' "${CERT_FP_CACHE["$key"]}"
    return 0
  fi
  cached="$(openssl x509 -in "${cert_file}" -outform DER 2>/dev/null | openssl dgst -sha256 -r 2>/dev/null | awk '{print $1}')"
  [ -n "${cached}" ] || return 1
  CERT_FP_CACHE["${key}"]="${cached}"
  printf '%s' "${cached}"
}

managed_cert_path() {
  local tag="$1"
  local path="$2"
  [ "${path%/*}" = "${CERT_DIR}" ] || return 1
  case "$path" in
  "${CERT_DIR}/${tag}."*/*) return 1 ;;
  "${CERT_DIR}/${tag}."*) return 0 ;;
  *) return 1 ;;
  esac
}

import_custom_certificate_bundle() {
  local tag="$1" cert_path="$2" key_path="$3"
  _publish_certificate_bundle "$tag" "$cert_path" "$key_path"
}

import_custom_certificate_content() {
  local tag="$1" cert_b64="$2" key_b64="$3" stage pair
  [ -n "$cert_b64" ] && [ -n "$key_b64" ] || return 1
  stage="$(mktemp -d "${CERT_DIR}/.cert-content.XXXXXX")" || return 1
  if ! printf '%s' "$cert_b64" | base64 -d >"${stage}/candidate.crt" || ! printf '%s' "$key_b64" | base64 -d >"${stage}/candidate.key"; then
    rm -rf -- "$stage"; return 1
  fi
  pair="$(_publish_certificate_bundle "$tag" "${stage}/candidate.crt" "${stage}/candidate.key")" || { rm -rf -- "$stage"; return 1; }
  rm -rf -- "$stage"
  printf '%s' "$pair"
}

remove_node_certificates() {
  local tag="$1"
  local cert_file="${2:-}"
  local key_file="${3:-}"

  if [ -n "$cert_file" ] && [ -f "$cert_file" ] && managed_cert_path "$tag" "$cert_file"; then
    rm -f "$cert_file" || return 1
  fi
  if [ -n "$key_file" ] && [ -f "$key_file" ] && managed_cert_path "$tag" "$key_file"; then
    rm -f "$key_file" || return 1
  fi
}

migrate_custom_certificate_bundle() {
  local tag="$1"
  local cert_mode cert_file key_file pair

  cert_mode="$(node_value "$tag" "certificate_mode")"
  [ "$cert_mode" = "custom" ] || return 0

  cert_file="$(node_value "$tag" "certificate_path")"
  key_file="$(node_value "$tag" "key_path")"
  if managed_cert_path "$tag" "$cert_file" && managed_cert_path "$tag" "$key_file"; then
    _validate_certificate_bundle "$cert_file" "$key_file" || { print_err "托管的自定义证书或私钥无效：${tag}"; return 1; }
    if declare -F service_certificate_permissions >/dev/null; then service_certificate_permissions "$cert_file" "$key_file" || return 1; fi
    return 0
  fi
  if [ ! -r "$cert_file" ] || [ ! -r "$key_file" ]; then
    print_err "自定义证书不可读取，无法导入托管目录：${tag}"
    return 1
  fi

  pair="$(import_custom_certificate_bundle "$tag" "$cert_file" "$key_file")" || return 1
  json_set_field "${NODES_FILE}" "$tag" "certificate_path" "${pair%|*}" || return 1
  json_set_field "${NODES_FILE}" "$tag" "key_path" "${pair#*|}" || return 1
}

migrate_custom_certificates() {
  local tags tag
  if ! tags="$(iter_node_tags)"; then
    print_err "读取节点列表失败。"
    return 1
  fi
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    migrate_custom_certificate_bundle "$tag" || return 1
  done <<<"$tags"
}

prompt_certificate_bundle() {
  local tag="$1"
  local default_domain="$2"
  local mode cert_path key_path pair

  while true; do
    mode="$(prompt_choice "证书模式 (self-signed/custom)" "self-signed")"
    case "$mode" in
    self-signed | self | quick)
      pair="$(ensure_tls_material "$tag" "$default_domain")" || return 1
      printf 'self-signed|%s|%s' "${pair%|*}" "${pair#*|}"
      return 0
      ;;
    custom)
      cert_path="$(prompt_nonempty "证书路径")"
      key_path="$(prompt_nonempty "私钥路径")"
      [ -r "$cert_path" ] || {
        print_warn "证书不可读取：${cert_path}"
        continue
      }
      [ -r "$key_path" ] || {
        print_warn "私钥不可读取：${key_path}"
        continue
      }
      if ! pair="$(import_custom_certificate_bundle "$tag" "$cert_path" "$key_path")"; then
        print_warn "导入自定义证书失败，请检查路径和权限。"
        continue
      fi
      printf 'custom|%s|%s' "${pair%|*}" "${pair#*|}"
      return 0
      ;;
    *)
      print_warn "请输入 self-signed 或 custom。"
      ;;
    esac
  done
}

cleanup_orphan_certs() {
  local file tag rc list_file
  local -a cert_files=()
  [ -r "$NODES_FILE" ] && [ -r "$CERT_DIR" ] || return 1
  jq -e 'type == "object" and all(.[]; type == "object")' "$NODES_FILE" >/dev/null 2>&1 || return 1
  list_file="$(mktemp "${CERT_DIR}/.cert-list.XXXXXX")" || return 1
  if ! find "$CERT_DIR" -maxdepth 1 -type f \( -name "*.crt" -o -name "*.key" \) -print0 >"$list_file"; then rm -f -- "$list_file"; return 1; fi
  while IFS= read -r -d '' file; do cert_files+=("$file"); done <"$list_file"
  rm -f -- "$list_file" || return 1
  for file in "${cert_files[@]}"; do
    tag="${file##*/}"; tag="${tag%%.*}"
    [[ "$tag" =~ ^[A-Za-z0-9_-]+$ ]] || continue
    case "${file##*/}" in "$tag.crt"|"$tag.key"|"$tag.custom.crt"|"$tag.custom.key") ;; *) continue ;; esac
    if jq -e --arg tag "$tag" 'has($tag)' "$NODES_FILE" >/dev/null 2>&1; then continue; else rc=$?; fi
    [ "$rc" -eq 1 ] || return 1
    rm -f -- "$file" || return 1
  done
}
