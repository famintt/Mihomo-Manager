#!/usr/bin/env bash
set -eEuo pipefail

umask 077

ensure_dir_mode() {
  local dir="$1"
  local mode="$2"
  if install -d -m "$mode" "$dir" 2>/dev/null; then
    return 0
  fi
  mkdir -p "$dir" || return 1
  chmod "$mode" "$dir"
}

ensure_file_mode() {
  local file="$1"
  local mode="$2"
  local default_content="${3:-}"
  [ ! -L "$file" ] || return 1
  if [ ! -f "$file" ]; then
    printf '%s' "$default_content" >"$file" || return 1
  fi
  chmod "$mode" "$file"
}

validate_json_object() {
  local file="$1"
  [ -f "$file" ] && [ ! -L "$file" ] &&
    jq -se 'length == 1 and (.[0] | type == "object")' "$file" >/dev/null 2>&1
}

validate_storage_tables() {
  local nodes="${1:-${NODES_FILE}}" secrets="${2:-${SECRETS_FILE}}" file
  for file in "$nodes" "$secrets"; do
    if [ ! -f "$file" ] || [ -L "$file" ] ||
      ! jq -se 'length == 1 and (.[0] | type == "object" and all(.[]; type == "object"))' "$file" >/dev/null 2>&1; then
      print_err "状态表缺失或不是有效的 JSON 对象，停止操作：$file"
      return 1
    fi
  done
}

init_storage() {
  # A partial installation is evidence of damage, never a new empty database.
  if [ -e "${NODES_FILE}" ] || [ -L "${NODES_FILE}" ] ||
    [ -e "${SECRETS_FILE}" ] || [ -L "${SECRETS_FILE}" ]; then
    validate_storage_tables || return 1
  elif [ -e "${CONFIG_FILE}" ] || [ -e "${SETTING_FILE}" ]; then
    print_err "既有安装的节点/密钥表丢失，请先恢复备份。"
    return 1
  fi
  if [ -e "${SETTING_FILE}" ] && ! validate_json_object "${SETTING_FILE}"; then
    print_err "设置文件损坏，停止初始化：${SETTING_FILE}"
    return 1
  fi
  local dir
  for dir in "${BASE_DIR}" "${LIB_DIR}" "${CERT_DIR}" "${LOG_DIR}" "${RUNTIME_DIR}"; do
    [ ! -L "$dir" ] || { print_err "拒绝符号链接目录：$dir"; return 1; }
    ensure_dir_mode "$dir" 700 || return 1
  done
  ensure_file_mode "${NODES_FILE}" 600 "{}"$'\n' || return 1
  ensure_file_mode "${SECRETS_FILE}" 600 "{}"$'\n' || return 1
  ensure_file_mode "${CONFIG_FILE}" 600 "{}"$'\n' || return 1
  ensure_file_mode "${SETTING_FILE}" 600 "{}"$'\n' || return 1
  if declare -F service_data_permissions >/dev/null 2>&1; then
    service_data_permissions || return 1
  fi
}

sanitize_permissions() {
  local dir file
  for dir in "${BASE_DIR}" "${LIB_DIR}" "${CERT_DIR}" "${LOG_DIR}" "${RUNTIME_DIR}"; do
    [ ! -L "$dir" ] || { print_err "拒绝符号链接目录：$dir"; return 1; }
    ensure_dir_mode "$dir" 700 || return 1
  done
  for file in "${NODES_FILE}" "${SECRETS_FILE}" "${CONFIG_FILE}" "${SETTING_FILE}"; do
    [ ! -L "$file" ] || return 1
    [ ! -f "$file" ] || chmod 600 "$file" || return 1
  done
  find "${CERT_DIR}" -type f -exec chmod 600 {} + || return 1
  find "${RUNTIME_DIR}" -type f -exec chmod 600 {} + || return 1
  if declare -F service_data_permissions >/dev/null 2>&1; then
    service_data_permissions || return 1
  fi
}

prepare_lock_path() {
  local parent
  parent="$(dirname -- "${LOCK_FILE}")"
  [ ! -L "$parent" ] && [ ! -L "${LOCK_FILE}" ] || return 1
  if [ ! -d "$parent" ]; then
    ensure_dir_mode "$parent" 700 || return 1
  elif [ "$parent" = "${LOCK_ROOT}" ]; then
    [ "$(stat -c %u "$parent")" = "${EUID}" ] || return 1
    chmod 700 "$parent" || return 1
  fi
}

close_lock_fd() {
  if [[ "${LOCK_FD:-}" =~ ^[0-9]+$ ]]; then
    exec {LOCK_FD}>&-
  fi
  LOCK_FD=""
}

forget_inherited_lock() {
  if [ "${LOCK_HELD:-false}" = true ] && [ "${LOCK_OWNER_PID:-}" != "${BASHPID}" ]; then
    # flock -u would unlock the parent's shared open-file description.
    close_lock_fd
    LOCK_HELD=false
    LOCK_OWNER_PID=""
  fi
}

lock_process_identity() {
  local pid="$1" stat_line boot rest
  local -a _lock_stat_fields
  [ -r "/proc/$pid/stat" ] || return 1
  IFS= read -r stat_line <"/proc/$pid/stat" || return 1
  rest="${stat_line##*) }"
  read -r -a _lock_stat_fields <<<"$rest"
  [ "${#_lock_stat_fields[@]}" -ge 20 ] || return 1
  IFS= read -r boot </proc/sys/kernel/random/boot_id || return 1
  printf '%s:%s' "$boot" "${_lock_stat_fields[19]}"
}

try_mkdir_lock() {
  local owner identity current self="${BASHPID}"
  if ! mkdir -- "${LOCK_DIR_FALLBACK}" 2>/dev/null; then
    # No age-based eviction: a long-running live owner keeps its lock.
    [ -f "${LOCK_DIR_FALLBACK}/owner" ] && [ ! -L "${LOCK_DIR_FALLBACK}/owner" ] || return 1
    read -r owner identity <"${LOCK_DIR_FALLBACK}/owner" || return 1
    [[ "$owner" =~ ^[1-9][0-9]*$ ]] || return 1
    current="$(lock_process_identity "$owner" 2>/dev/null || true)"
    if kill -0 "$owner" 2>/dev/null && { [ -z "$identity" ] || [ "$identity" = "$current" ]; }; then
      return 1
    fi
    # One reaper at a time; never recursively remove a lock path another owner may reuse.
    mkdir "${LOCK_DIR_FALLBACK}/reap" 2>/dev/null || return 1
    if [ "$(<"${LOCK_DIR_FALLBACK}/owner")" != "$owner $identity" ]; then
      rmdir "${LOCK_DIR_FALLBACK}/reap" 2>/dev/null || true
      return 1
    fi
    rm -- "${LOCK_DIR_FALLBACK}/owner" || return 1
    rmdir "${LOCK_DIR_FALLBACK}/reap" || return 1
    rmdir "${LOCK_DIR_FALLBACK}" 2>/dev/null || return 1
    mkdir -- "${LOCK_DIR_FALLBACK}" 2>/dev/null || return 1
  fi
  identity="$(lock_process_identity "$self" 2>/dev/null || true)"
  if ! printf '%s %s\n' "${BASHPID}" "$identity" >"${LOCK_DIR_FALLBACK}/owner"; then
    rmdir "${LOCK_DIR_FALLBACK}" 2>/dev/null || true
    return 1
  fi
}

try_acquire_lock() {
  forget_inherited_lock
  [ "${LOCK_HELD:-false}" != true ] || return 0
  prepare_lock_path || return 1
  if command_exists flock; then
    exec {LOCK_FD}>>"${LOCK_FILE}" || return 1
    chmod 600 "${LOCK_FILE}" || { close_lock_fd; return 1; }
    if ! flock -n "${LOCK_FD}"; then
      close_lock_fd
      return 1
    fi
  else
    try_mkdir_lock || return 1
  fi
  LOCK_HELD=true
  LOCK_OWNER_PID="${BASHPID}"
}

acquire_lock() {
  local started="${SECONDS}"
  [[ "${LOCK_TIMEOUT}" =~ ^[0-9]+$ ]] || return 1
  while ! try_acquire_lock; do
    if [ $((SECONDS - started)) -ge "${LOCK_TIMEOUT}" ]; then
      print_err "在 ${LOCK_TIMEOUT} 秒内无法获取锁。"
      return 1
    fi
    sleep 1
  done
}

release_lock() {
  [ "${LOCK_HELD:-false}" = true ] || return 0
  if [ "${LOCK_OWNER_PID:-}" != "${BASHPID}" ]; then
    forget_inherited_lock
    return 0
  fi
  if [ -n "${LOCK_FD:-}" ]; then
    flock -u "${LOCK_FD}" || true
    close_lock_fd
  else
    rm -f -- "${LOCK_DIR_FALLBACK}/owner"
    rmdir "${LOCK_DIR_FALLBACK}" 2>/dev/null || true
  fi
  LOCK_HELD=false
  LOCK_OWNER_PID=""
}

json_update() {
  local file="$1"
  shift
  local tmp
  validate_json_object "$file" || return 1
  tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
  if ! jq "$@" "$file" >"${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  if ! chmod 600 "${tmp}" || ! mv "${tmp}" "$file"; then
    rm -f "${tmp}"
    return 1
  fi
}

json_set_record() {
  local file="$1"
  local tag="$2"
  local json="$3"
  # shellcheck disable=SC2016
  json_update "$file" --arg tag "$tag" --argjson value "$json" '.[$tag] = $value' || return 1
  invalidate_port_caches_if_defined
}

json_delete_record() {
  local file="$1"
  local tag="$2"
  # shellcheck disable=SC2016
  json_update "$file" --arg tag "$tag" 'del(.[$tag])' || return 1
  invalidate_port_caches_if_defined
}

json_set_field() {
  local file="$1"
  local tag="$2"
  local field="$3"
  local value="$4"
  # shellcheck disable=SC2016
  json_update "$file" --arg tag "$tag" --arg field "$field" --arg value "$value" '.[$tag][$field] = $value' || return 1
  invalidate_port_caches_if_defined
}

invalidate_port_caches_if_defined() {
  if declare -F invalidate_port_caches >/dev/null 2>&1; then
    invalidate_port_caches
  fi
}

record_value() {
  local file="$1"
  local tag="$2"
  local field="$3"
  # tr -d '\r'：防御个别平台 jq 输出 CRLF 导致取值带 \r 无法匹配
  jq -r --arg tag "$tag" --arg field "$field" '.[$tag][$field] // empty' "$file" | tr -d '\r'
}

node_value() {
  record_value "${NODES_FILE}" "$1" "$2"
}

secret_value() {
  record_value "${SECRETS_FILE}" "$1" "$2"
}

iter_node_tags() {
  jq -r 'keys[]' "${NODES_FILE}" 2>/dev/null | tr -d '\r'
}

# 9.3：jq 批量化——一次启动输出全部节点 protocol/port/argo_mode（TSV，@tsv 转义 tab/换行）。
# 由调用方定读法（read -r tag protocol port mode），供 watchdog/argo 替代逐节点 node_value 多次 jq。
# 字段顺序与 node_value 语义一致：protocol / port / argo_mode。
node_meta_bulk() {
  if [ ! -f "${NODES_FILE}" ]; then
    return 0
  fi
  jq -r 'to_entries[] | [.key,
       (.value.protocol // ""),
       ((.value.port // "") | tostring),
       (.value.argo_mode // "")] | @tsv' "${NODES_FILE}" 2>/dev/null | tr -d '\r'
}

delete_node_records() {
  local tag="$1"
  json_delete_record "${NODES_FILE}" "$tag" || return 1
  json_delete_record "${SECRETS_FILE}" "$tag" || return 1
}

reconcile_state() {
  # Finish both reads before changing either table; jq errors never mean "absent".
  validate_storage_tables || return 1
  local nodes_tags secret_tags tag present
  nodes_tags="$(iter_node_tags)" || return 1
  secret_tags="$(jq -r 'keys[]' "${SECRETS_FILE}")" || return 1
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    present="$(jq -r --arg tag "$tag" 'has($tag)' "${SECRETS_FILE}")" || return 1
    if [ "$present" = false ]; then
      print_warn "对账：节点 $tag 缺少密钥记录，已移除。"
      json_delete_record "${NODES_FILE}" "$tag" || return 1
    fi
  done <<<"$nodes_tags"
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    present="$(jq -r --arg tag "$tag" 'has($tag)' "${NODES_FILE}")" || return 1
    if [ "$present" = false ]; then
      print_warn "对账：孤儿密钥 $tag，已移除。"
      json_delete_record "${SECRETS_FILE}" "$tag" || return 1
    fi
  done <<<"$secret_tags"
}

backup_state() {
  local backup_dir tmpdir f old i j links
  local -a files=("${NODES_FILE}" "${SECRETS_FILE}" "${CONFIG_FILE}" "${SETTING_FILE}")
  local -a names=(nodes.json secrets.json config.yaml settings.json) backups=()
  validate_storage_tables || return 1
  validate_json_object "${SETTING_FILE}" || return 1
  ensure_dir_mode "${BASE_DIR}/backups" 700 || return 1
  tmpdir="$(mktemp -d "${BASE_DIR}/backups/.staging.XXXXXX")" || return 1
  backup_dir="${BASE_DIR}/backups/$(date +%Y%m%d-%H%M%S)-${BASHPID}-${tmpdir##*.}"
  if ! mkdir "$tmpdir/certs"; then rm -rf -- "$tmpdir"; return 1; fi
  for i in "${!files[@]}"; do
    f="${files[$i]}"
    if [ ! -f "$f" ] || [ -L "$f" ] ||
      ! cp -- "$f" "$tmpdir/${names[$i]}" || ! chmod 600 "$tmpdir/${names[$i]}"; then
      rm -rf -- "$tmpdir"
      return 1
    fi
  done
  if [ -d "${CERT_DIR}" ]; then
    links="$(find "${CERT_DIR}" -type l -print -quit)" || { rm -rf -- "$tmpdir"; return 1; }
    if [ -n "$links" ] || ! cp -a "${CERT_DIR}/." "$tmpdir/certs/"; then
      rm -rf -- "$tmpdir"
      return 1
    fi
  fi
  # MANIFEST.sha256 is explicitly excluded from the file scan.
  # shellcheck disable=SC2094
  if ! (cd "$tmpdir" && find . -type f ! -name MANIFEST.sha256 -exec sha256sum {} + >MANIFEST.sha256) ||
    ! chmod -R go-rwx "$tmpdir" || ! mv -- "$tmpdir" "$backup_dir"; then
    rm -rf -- "$tmpdir"
    return 1
  fi
  # Never prune the snapshot backing an in-flight transaction.
  for old in "${BASE_DIR}/backups/"[0-9]*; do
    if [ ! -d "$old" ] || [ -L "$old" ]; then continue; fi
    j=${#backups[@]}
    while [ "$j" -gt 0 ] && [ "$old" -ot "${backups[$((j-1))]}" ]; do
      backups[j]="${backups[$((j-1))]}"
      j=$((j-1))
    done
    backups[j]="$old"
  done
  for ((i=0; i<${#backups[@]}-10; i++)); do
    [ "${backups[$i]}" = "$backup_dir" ] || [ "${backups[$i]}" = "${_AUTO_ROLLBACK_DIR:-}" ] ||
      rm -rf -- "${backups[$i]}" || return 1
  done
  printf '%s' "$backup_dir"
}

# Validate a published backup before changing live state. Raw recovery images never
# enter the dated backup list and are not accepted through this public interface.
validate_state_backup() {
  local snapshot="$1" links
  [ -d "$snapshot" ] && [ ! -L "$snapshot" ] || return 1
  [ ! -e "$snapshot/.raw-state-v1" ] && [ ! -L "$snapshot/.raw-state-v1" ] || return 1
  validate_storage_tables "$snapshot/nodes.json" "$snapshot/secrets.json" || return 1
  validate_json_object "$snapshot/settings.json" || return 1
  [ -f "$snapshot/config.yaml" ] && [ ! -L "$snapshot/config.yaml" ] || return 1
  [ -d "$snapshot/certs" ] && [ ! -L "$snapshot/certs" ] || return 1
  links="$(find "$snapshot" -type l -print -quit)" || return 1
  [ -z "$links" ] || return 1
  if [ -e "$snapshot/MANIFEST.sha256" ]; then
    [ -f "$snapshot/MANIFEST.sha256" ] || return 1
    (cd "$snapshot" && sha256sum -c MANIFEST.sha256 >/dev/null) || return 1
  fi
}

# A private, checksummed image of exact bytes and absence, even if JSON is broken.
# Five fixed presence bits describe the four state files followed by certificates.
quarantine_state() {
  local image f i bits='' links
  local -a files=("${NODES_FILE}" "${SECRETS_FILE}" "${CONFIG_FILE}" "${SETTING_FILE}")
  local -a names=(nodes.json secrets.json config.yaml settings.json)
  image="$(mktemp -d "${BASE_DIR}/.quarantine.XXXXXX")" || return 1
  for i in "${!files[@]}"; do
    f="${files[$i]}"
    if [ -L "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; }; then
      rm -rf -- "$image"; return 1
    fi
    if [ -f "$f" ]; then
      if ! cp -p -- "$f" "$image/${names[$i]}"; then rm -rf -- "$image"; return 1; fi
      bits+="1"
    else
      bits+="0"
    fi
  done
  if [ -L "${CERT_DIR}" ] || { [ -e "${CERT_DIR}" ] && [ ! -d "${CERT_DIR}" ]; }; then
    rm -rf -- "$image"; return 1
  fi
  if [ -d "${CERT_DIR}" ]; then
    links="$(find "${CERT_DIR}" -type l -print -quit)" || { rm -rf -- "$image"; return 1; }
    if [ -n "$links" ] || ! cp -a -- "${CERT_DIR}" "$image/certs"; then
      rm -rf -- "$image"; return 1
    fi
    bits+="1"
  else
    bits+="0"
  fi
  # MANIFEST.sha256 is explicitly excluded from the file scan.
  # shellcheck disable=SC2094
  if ! printf '%s\n' raw-state-v1 >"$image/.raw-state-v1" ||
    ! printf '%s\n' "$bits" >"$image/PRESENCE" ||
    ! (cd "$image" && find . -type f ! -name MANIFEST.sha256 -exec sha256sum {} + >MANIFEST.sha256) ||
    ! chmod -R go-rwx "$image"; then
    rm -rf -- "$image"; return 1
  fi
  printf '%s' "$image"
}

validate_raw_state() {
  local image="$1" bits links i
  local -a names=(nodes.json secrets.json config.yaml settings.json certs)
  [ -d "$image" ] && [ ! -L "$image" ] || return 1
  for i in .raw-state-v1 PRESENCE MANIFEST.sha256; do
    [ -f "$image/$i" ] && [ ! -L "$image/$i" ] || return 1
  done
  [ "$(<"$image/.raw-state-v1")" = raw-state-v1 ] || return 1
  bits="$(<"$image/PRESENCE")"
  [[ "$bits" =~ ^[01]{5}$ ]] || return 1
  links="$(find "$image" -type l -print -quit)" || return 1
  [ -z "$links" ] || return 1
  for i in "${!names[@]}"; do
    if [ "${bits:$i:1}" = 1 ]; then
      if [ "$i" -eq 4 ]; then [ -d "$image/${names[$i]}" ] || return 1
      else [ -f "$image/${names[$i]}" ] || return 1; fi
    else
      [ ! -e "$image/${names[$i]}" ] || return 1
    fi
  done
  (cd "$image" && sha256sum -c MANIFEST.sha256 >/dev/null) || return 1
}

# Both valid backups and raw quarantine use this single staged publish/revert path.
# Until every publish succeeds, previous files and the old certificate tree remain
# under stage/previous. A failed reversal retains that stage for manual recovery.
restore_state_image() {
  local snapshot="$1" raw="${2:-false}" stage f i bits=11111 failed=0 revert_failed=0
  local -a files=("${NODES_FILE}" "${SECRETS_FILE}" "${CONFIG_FILE}" "${SETTING_FILE}")
  local -a names=(nodes.json secrets.json config.yaml settings.json)
  if [ "$raw" = true ]; then
    validate_raw_state "$snapshot" || return 1
    bits="$(<"$snapshot/PRESENCE")"
  else
    validate_state_backup "$snapshot" || return 1
  fi
  stage="$(mktemp -d "${BASE_DIR}/.restore.XXXXXX")" || return 1
  if ! mkdir "$stage/previous"; then rm -rf -- "$stage"; return 1; fi
  if [ "${bits:4:1}" = 1 ]; then
    if ! mkdir "$stage/new-certs" || ! cp -a "$snapshot/certs/." "$stage/new-certs/"; then
      rm -rf -- "$stage"; return 1
    fi
  fi
  for i in "${!files[@]}"; do
    f="${files[$i]}"
    if [ -L "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; }; then
      rm -rf -- "$stage"; return 1
    fi
    if [ "${bits:$i:1}" = 1 ]; then
      if ! cp -- "$snapshot/${names[$i]}" "$stage/${names[$i]}" || ! chmod 600 "$stage/${names[$i]}"; then
        rm -rf -- "$stage"; return 1
      fi
    fi
    if [ -e "$f" ] && ! cp -p -- "$f" "$stage/previous/${names[$i]}"; then
      rm -rf -- "$stage"; return 1
    fi
  done
  if [ -L "${CERT_DIR}" ] || { [ -e "${CERT_DIR}" ] && [ ! -d "${CERT_DIR}" ]; }; then
    rm -rf -- "$stage"; return 1
  fi
  if [ -e "${CERT_DIR}" ] && ! mv -- "${CERT_DIR}" "$stage/previous/certs"; then
    rm -rf -- "$stage"; return 1
  fi
  if [ "${bits:4:1}" = 1 ] && ! mv -- "$stage/new-certs" "${CERT_DIR}"; then
    if [ -d "$stage/previous/certs" ] && ! mv -- "$stage/previous/certs" "${CERT_DIR}"; then
      print_err "证书恢复失败，原证书保留在 $stage/previous/certs"
      return 1
    fi
    rm -rf -- "$stage"; return 1
  fi
  for i in "${!files[@]}"; do
    if [ "${bits:$i:1}" = 1 ]; then
      if ! mv -- "$stage/${names[$i]}" "${files[$i]}"; then failed=1; break; fi
    elif ! rm -f -- "${files[$i]}"; then failed=1; break
    fi
  done
  if [ "$failed" -eq 0 ]; then
    invalidate_port_caches_if_defined || failed=1
    # Raw absence is deliberate; normal sanitization would recreate missing dirs.
    if [ "$raw" != true ] && ! sanitize_permissions; then failed=1; fi
  fi
  if [ "$failed" -ne 0 ]; then
    for i in "${!files[@]}"; do
      if [ -f "$stage/previous/${names[$i]}" ]; then
        cp -p -- "$stage/previous/${names[$i]}" "${files[$i]}" || revert_failed=1
      else
        rm -f -- "${files[$i]}" || revert_failed=1
      fi
    done
    if ! rm -rf -- "${CERT_DIR}"; then revert_failed=1
    elif [ -d "$stage/previous/certs" ]; then
      mv -- "$stage/previous/certs" "${CERT_DIR}" || revert_failed=1
    fi
    print_err "快照发布失败，暂存及原状态保留在 $stage（回退失败：$revert_failed）"
    return 1
  fi
  if ! rm -rf -- "$stage"; then
    print_err "状态已发布，但暂存目录清理失败：$stage"
    return 1
  fi
}

restore_state_backup() {
  restore_state_image "$1" false || return 1
  print_ok "已从备份恢复：$1"
}

restore_raw_state() {
  restore_state_image "$1" true
}

latest_state_backup() {
  local candidate latest=""
  for candidate in "${BASE_DIR}/backups/"[0-9]*; do
    if [ ! -d "$candidate" ] || [ -L "$candidate" ]; then continue; fi
    if [ -z "$latest" ] || [ "$candidate" -nt "$latest" ]; then latest="$candidate"; fi
  done
  [ -n "$latest" ] || { print_err "没有可用的状态备份。"; return 1; }
  printf '%s' "$latest"
}

restore_latest_backup() {
  local latest
  latest="$(latest_state_backup)" || return 1
  restore_state_backup "$latest"
}

rotate_log_file() {
  local file="$1"
  local size max_bytes idx

  [ ! -L "$file" ] || return 1
  [ -e "$file" ] || return 0
  [ -f "$file" ] || return 1
  [[ "${LOG_ROTATE_SIZE_MB}" =~ ^[1-9][0-9]*$ ]] &&
    [[ "${LOG_ROTATE_BACKUPS}" =~ ^[0-9]+$ ]] || return 1
  # Never follow a backup symlink while running as root.
  for ((idx=1; idx<=LOG_ROTATE_BACKUPS; idx++)); do
    [ ! -L "${file}.${idx}" ] || return 1
  done
  size="$(wc -c <"$file" 2>/dev/null | tr -d '[:space:]')" || return 1
  [ -n "$size" ] || return 1

  max_bytes=$((LOG_ROTATE_SIZE_MB * 1024 * 1024))
  if [ "$size" -lt "$max_bytes" ]; then
    return 0
  fi

  if [ "${LOG_ROTATE_BACKUPS}" -le 0 ]; then
    : >"$file" || return 1
    chmod 600 "$file" || return 1
    return 0
  fi

  rm -f "${file}.${LOG_ROTATE_BACKUPS}" || return 1

  if [ "${LOG_ROTATE_BACKUPS}" -gt 1 ]; then
    idx=$((LOG_ROTATE_BACKUPS - 1))
    while [ "$idx" -ge 1 ]; do
      if [ -f "${file}.${idx}" ]; then
        mv "${file}.${idx}" "${file}.$((idx + 1))" || return 1
      fi
      idx=$((idx - 1))
    done
  fi

  cp "$file" "${file}.1" || return 1
  : >"$file" || return 1
  chmod 600 "$file" "${file}.1" || return 1
  return 0
}
