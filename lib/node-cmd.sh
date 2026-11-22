#!/usr/bin/env bash
set -eEuo pipefail

umask 077

wipe_records() {
  local nodes_tmp secrets_tmp
  nodes_tmp="$(mktemp "${BASE_DIR}/.nodes.XXXXXX")" || return 1
  secrets_tmp="$(mktemp "${BASE_DIR}/.secrets.XXXXXX")" || { rm -f -- "$nodes_tmp"; return 1; }
  if ! printf '{}\n' >"$nodes_tmp" || ! printf '{}\n' >"$secrets_tmp" ||
    ! chmod 600 "$nodes_tmp" "$secrets_tmp" ||
    ! mv -- "$nodes_tmp" "${NODES_FILE}" || ! mv -- "$secrets_tmp" "${SECRETS_FILE}"; then
    rm -f -- "$nodes_tmp" "$secrets_tmp"
    return 1
  fi
  invalidate_port_caches
}

abort_node_delete() {
  rollback_pending_transaction || print_err "节点删除失败，快照恢复未能完成。"
  if [ "${_DELETE_OWNS_LOCK:-false}" = true ]; then release_lock; fi
  return 1
}

# Prompt outside the lock; validate and resolve selected records again after locking.
delete_nodes_transaction() {
  local _DELETE_OWNS_LOCK=false delete_all=false backup_dir tag cert_file key_file all_tags
  local -a tags=("$@")
  [ "${#tags[@]}" -ne 0 ] || delete_all=true
  stack_transaction_available || return 1
  if [ "${LOCK_HELD:-false}" != true ] || [ "${LOCK_OWNER_PID:-}" != "$BASHPID" ]; then
    acquire_lock || return 1
    _DELETE_OWNS_LOCK=true
  fi
  init_storage || { abort_node_delete; return 1; }
  if [ "${#tags[@]}" -eq 0 ]; then
    all_tags="$(iter_node_tags)" || { abort_node_delete; return 1; }
    while IFS= read -r tag; do [ -z "$tag" ] || tags+=("$tag"); done <<<"$all_tags"
  fi
  for tag in "${tags[@]}"; do
    if ! jq -e --arg tag "$tag" 'has($tag)' "$NODES_FILE" >/dev/null; then
      print_err "所选节点已不存在：$tag"
      abort_node_delete
      return 1
    fi
  done
  backup_dir="$(backup_state)" || { abort_node_delete; return 1; }
  _AUTO_ROLLBACK_DIR="$backup_dir"
  _AUTO_ROLLBACK_OWNER="$BASHPID"
  for tag in "${tags[@]}"; do
    cert_file="$(node_value "$tag" certificate_path)" || { abort_node_delete; return 1; }
    key_file="$(node_value "$tag" key_path)" || { abort_node_delete; return 1; }
    if ! stop_argo_node "$tag" || ! delete_node_records "$tag" ||
      ! remove_node_certificates "$tag" "$cert_file" "$key_file"; then
      abort_node_delete
      return 1
    fi
  done
  if [ "$delete_all" = true ] && ! cleanup_orphan_certs; then
    abort_node_delete
    return 1
  fi
  if ! invalidate_port_caches || ! render_config || ! reload_service || ! sanitize_permissions; then
    abort_node_delete
    return 1
  fi
  _AUTO_ROLLBACK_DIR=""
  _AUTO_ROLLBACK_OWNER=""
  if [ "$_DELETE_OWNS_LOCK" = true ]; then release_lock; fi
}

delete_all_nodes() {
  delete_nodes_transaction || return 1
  print_ok "已删除全部节点（含证书）并重启服务。"
}

print_node_list() {
  local idx=1
  local tag protocol name port public_ip
  if [ -n "$(manager_env_or_setting "direct_host" "")" ] || [ -n "$(manager_env_or_setting "server_ip" "")" ]; then
    public_ip=""
  else
    public_ip="$(get_public_ip)"
  fi
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    protocol="$(node_value "$tag" "protocol")"
    name="$(node_value "$tag" "name")"
    port="$(node_value "$tag" "port")"
    echo "${idx}. ${name} | ${protocol} | 端口: ${port}"
    echo "   标识: ${tag}"
    echo "   链接: $(build_share_link "$tag" "$public_ip")"
    idx=$((idx + 1))
  done < <(iter_node_tags)

  if [ "${idx}" -eq 1 ]; then
    echo "当前没有节点。"
  fi
}

sub_command() {
  local out_file="${1:-}" links="" tag content public_ip direct_host server_ip tags link output_tmp
  init_storage || return 1
  validate_storage_tables || return 1
  direct_host="$(manager_env_or_setting direct_host '')" || return 1
  server_ip="$(manager_env_or_setting server_ip '')" || return 1
  if [ -n "$direct_host" ] || [ -n "$server_ip" ]; then
    public_ip=""
  else
    public_ip="$(get_public_ip)" || return 1
  fi
  tags="$(iter_node_tags)" || return 1
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    link="$(build_share_link "$tag" "$public_ip")" || return 1
    [ -n "$link" ] || return 1
    links+="$link"$'\n'
  done <<<"$tags"
  if [ -z "$links" ]; then
    print_err "当前没有可输出的节点。"
    return 1
  fi
  content="$(printf '%s' "$links" | base64 | tr -d '\n')" || return 1
  if [ -n "$out_file" ]; then
    [ ! -L "$out_file" ] || return 1
    output_tmp="$(mktemp "${out_file}.tmp.XXXXXX")" || return 1
    if ! printf '%s\n' "$content" >"$output_tmp" || ! chmod 600 "$output_tmp" ||
      ! mv -- "$output_tmp" "$out_file"; then
      rm -f -- "$output_tmp"
      return 1
    fi
    print_ok "订阅已写入：${out_file}（节点数：$(printf '%s' "$links" | grep -c .)）"
  else
    printf '%s\n' "$content"
  fi
}

select_node_tag() {
  local -a rows
  local idx input tag protocol name port
  mapfile -t rows < <(jq -r 'to_entries[] | [.key, .value.protocol, .value.name, (.value.port|tostring)] | @tsv' "${NODES_FILE}" 2>/dev/null)
  [ "${#rows[@]}" -gt 0 ] || return 1

  idx=1
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r tag protocol name port <<<"${row}"
    printf '%s\n' "${idx}. ${name} | ${protocol} | 端口: ${port}" >&2
    idx=$((idx + 1))
  done

  read -r -p "请选择节点编号: " input || return 1
  if ! [[ "${input}" =~ ^[0-9]+$ ]] || [ "${input}" -lt 1 ] || [ "${input}" -gt "${#rows[@]}" ]; then
    return 1
  fi

  IFS=$'\t' read -r tag _ <<<"${rows[$((input - 1))]}"
  printf '%s' "${tag}"
}

list_nodes() {
  init_storage
  echo
  print_node_list
  echo
}

delete_node() {
  local tag
  validate_storage_tables || return 1
  tag="$(select_node_tag)" || {
    print_warn "没有可选节点，或输入的编号无效。"
    return 0
  }
  if ! confirm_yes "确认删除节点 $tag 吗？"; then return 0; fi
  delete_nodes_transaction "$tag" || return 1
  print_ok "已删除节点：$tag"
}

show_status() {
  local count installed_version
  init_storage
  count="$(jq 'length' "${NODES_FILE}" 2>/dev/null || printf '0')"
  installed_version="${MIHOMO_VERSION#v}"
  if [ -x "${MIHOMO_BIN}" ]; then
    installed_version="$("${MIHOMO_BIN}" -v 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 | tr -d 'v' || true)"
    installed_version="${installed_version:-${MIHOMO_VERSION#v}}"
  fi
  echo
  echo "项目名称：${PROJECT_NAME}"
  echo "当前版本：${SCRIPT_VERSION}"
  echo "服务状态：$(service_state)"
  echo "节点数量：${count}"
  if systemd_available; then
    if systemd_timer_active; then
      echo "守护定时器：active (下次触发已调度)"
    else
      echo "守护定时器：inactive (未调度)"
    fi
  elif openrc_available; then
    echo "守护方式：OpenRC + cron"
  else
    echo "守护方式：cron"
  fi
  echo "mihomo 版本：${installed_version}"
  echo "cloudflared 版本：$(cloudflared_installed_version)"
  # 1.2：可观测面处于开态时展示实时连接汇总（本地 127.0.0.1 的 clash_api）
  if clash_api_enabled; then
    local _conns
    if _conns="$(clash_api_conn_summary 2>/dev/null || true)"; then
      echo "实时连接：${_conns}"
    else
      echo "实时连接：不可用（mihomo 未运行或可观测面未启用）"
    fi
  fi
  echo
  print_node_list
  echo
}

stack_transaction_available() {
  if [ -n "${_AUTO_ROLLBACK_DIR:-}" ] && [ "${_AUTO_ROLLBACK_OWNER:-}" = "$BASHPID" ]; then
    print_err "已有未提交事务，拒绝嵌套重启或恢复。"
    return 1
  fi
}

restart_stack() {
  local owned=false snapshot
  stack_transaction_available || return 1
  if [ "${LOCK_HELD:-false}" != true ] || [ "${LOCK_OWNER_PID:-}" != "$BASHPID" ]; then
    acquire_lock || return 1
    owned=true
  fi
  if ! init_storage || ! snapshot="$(backup_state)"; then
    if [ "$owned" = true ]; then release_lock; fi
    return 1
  fi
  _AUTO_ROLLBACK_DIR="$snapshot"
  _AUTO_ROLLBACK_OWNER="$BASHPID"
  if ! render_config || ! reload_service || ! restart_all_argo_nodes || ! sanitize_permissions; then
    rollback_pending_transaction || print_err "重启失败且原状态未能完整恢复，请保留快照。"
    if [ "$owned" = true ]; then release_lock; fi
    return 1
  fi
  _AUTO_ROLLBACK_DIR=""
  _AUTO_ROLLBACK_OWNER=""
  if [ "$owned" = true ]; then release_lock; fi
}

restore_stack() {
  local owned=false target previous
  stack_transaction_available || return 1
  if [ "${LOCK_HELD:-false}" != true ] || [ "${LOCK_OWNER_PID:-}" != "$BASHPID" ]; then
    acquire_lock || return 1
    owned=true
  fi
  # Validate the chosen target before capturing damaged/missing live state. Raw
  # quarantine stays outside dated valid backups and is never a restore target.
  if ! target="$(latest_state_backup)" || ! validate_state_backup "$target" ||
    ! previous="$(quarantine_state)"; then
    if [ "$owned" = true ]; then release_lock; fi
    return 1
  fi
  _AUTO_ROLLBACK_DIR="$previous"
  _AUTO_ROLLBACK_OWNER="$BASHPID"
  if validate_storage_tables && validate_json_object "$SETTING_FILE" &&
    [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] && mihomo_validate "$CONFIG_FILE"; then
    if ! printf '%s\n' restart-safe >"$previous/.restart-safe"; then
      _AUTO_ROLLBACK_DIR='' _AUTO_ROLLBACK_OWNER=''
      if [ "$owned" = true ]; then release_lock; fi
      return 1
    fi
  fi
  if ! stop_all_argo_nodes || ! stop_service || ! restore_state_backup "$target" ||
    ! mihomo_validate "$CONFIG_FILE" || ! start_service ||
    ! restart_all_argo_nodes || ! sanitize_permissions; then
    rollback_pending_transaction || print_err "恢复失败且操作前状态未能完整恢复，请保留隔离快照：$previous"
    if [ "$owned" = true ]; then release_lock; fi
    return 1
  fi
  _AUTO_ROLLBACK_DIR=''
  _AUTO_ROLLBACK_OWNER=''
  if ! rm -rf -- "$previous"; then
    print_warn "恢复已提交，隔离快照清理失败：$previous"
  fi
  if [ "$owned" = true ]; then release_lock; fi
  print_ok "已恢复指定快照并重启服务：$target"
}
