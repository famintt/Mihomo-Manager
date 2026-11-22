#!/usr/bin/env bash
set -eEuo pipefail

umask 077

detect_arch() {
  case "$(uname -m)" in
  x86_64 | amd64) printf 'amd64' ;;
  aarch64 | arm64) printf 'arm64' ;;
  armv7l | armv7) printf 'armv7' ;;
  armv6l | armv6) printf 'armv6' ;;
  *) return 1 ;;
  esac
}

pkg_install() {
  if command_exists apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || return 1
    apt-get install -y "$@"
  elif command_exists dnf; then
    dnf install -y "$@"
  elif command_exists yum; then
    yum install -y "$@"
  elif command_exists apk; then
    apk update >/dev/null 2>&1 || true
    apk add --no-cache "$@"
  elif command_exists pacman; then
    pacman -Sy --noconfirm "$@"
  elif command_exists zypper; then
    zypper --non-interactive install "$@"
  else
    fatal "暂不支持当前包管理器，请手动安装以下依赖：$*"
  fi
}

required_commands() {
  printf '%s\n' curl tar gzip jq openssl awk sed grep find head mktemp install nohup tr hostname kill rm mv chmod cat cp stat readlink sort wc cmp sha256sum git
  if systemd_available; then
    printf '%s\n' systemctl getent setpriv chown
  elif openrc_available; then
    printf '%s\n' rc-service rc-update
  fi
}

deps_present() {
  local cmd
  while IFS= read -r cmd; do
    command_exists "${cmd}" || return 1
  done < <(required_commands)
  command_exists ss || command_exists netstat || return 1
  return 0
}

ensure_dependencies() {
  # 依赖齐全时跳过包管理器（避免每次菜单操作都全量刷新软件源索引）
  if ! deps_present; then
    local packages=()
    if command_exists apt-get; then
      packages=(ca-certificates curl tar gzip git jq openssl procps iproute2 util-linux findutils grep sed gawk coreutils)
    elif command_exists dnf || command_exists yum; then
      packages=(ca-certificates curl tar gzip git jq openssl procps-ng iproute util-linux findutils grep sed gawk coreutils)
    elif command_exists apk; then
      packages=(ca-certificates curl tar gzip git jq openssl procps iproute2 util-linux findutils grep sed gawk coreutils gcompat)
    elif command_exists pacman; then
      packages=(ca-certificates curl tar gzip git jq openssl procps-ng iproute2 util-linux findutils grep sed gawk coreutils)
    elif command_exists zypper; then
      packages=(ca-certificates curl tar gzip git jq openssl procps iproute2 util-linux findutils grep sed gawk coreutils)
    fi

    pkg_install "${packages[@]}" || return 1
  fi
  verify_runtime_prereqs
}

verify_runtime_prereqs() {
  local missing=() cmd
  while IFS= read -r cmd; do
    command_exists "${cmd}" || missing+=("${cmd}")
  done < <(required_commands)

  if ! command_exists ss && ! command_exists netstat; then
    missing+=("ss/netstat")
  fi

  if [ "${#missing[@]}" -gt 0 ]; then
    fatal "缺少必要命令：${missing[*]}"
  fi
}

ensure_binary_runs() {
  local binary="$1"
  local label="$2"
  shift 2

  if "$binary" "$@" >/dev/null 2>&1; then
    return 0
  fi

  if command_exists apk; then
    print_info "检测到 Alpine，正在安装 gcompat 兼容层"
    apk update >/dev/null 2>&1 || true
    apk add --no-cache gcompat >/dev/null 2>&1
  fi

  "$binary" "$@" >/dev/null 2>&1 || fatal "${label} 已安装，但当前系统无法运行。"
}

sync_project_assets_from_source() {
  [ -n "${SOURCE_ROOT:-}" ] || return 0
  local candidate path mode paths digest
  paths="$(candidate_payload_paths "$SOURCE_ROOT" | LC_ALL=C sort)" || return 1
  [ -n "$paths" ] || return 1
  candidate="$(mktemp -d)" || return 1
  chmod 0755 "$candidate" || { rm -rf -- "$candidate"; return 1; }
  for path in lib metadata scripts; do install -d -m 0755 "$candidate/$path" || { rm -rf -- "$candidate"; return 1; }; done
  while IFS= read -r path; do
    if [ ! -f "$SOURCE_ROOT/$path" ] || [ -L "$SOURCE_ROOT/$path" ]; then rm -rf -- "$candidate"; return 1; fi
    case "$path" in mm.sh | mtp.sh | scripts/watchdog.sh) mode=0755 ;; *) mode=0644 ;; esac
    install -m "$mode" "$SOURCE_ROOT/$path" "$candidate/$path" || { rm -rf -- "$candidate"; return 1; }
  done <<<"$paths"
  if ! (while IFS= read -r path; do
    digest="$(sha256_file "$candidate/$path")" || exit 1
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || exit 1
    printf '%s  %s\n' "$digest" "$path"
  done <<<"$paths") >"$candidate/MANIFEST.sha256"; then rm -rf -- "$candidate"; return 1; fi
  chmod 0644 "$candidate/MANIFEST.sha256" || { rm -rf -- "$candidate"; return 1; }
  if ! install_project_candidate "$candidate" "v$SCRIPT_VERSION"; then rm -rf -- "$candidate"; return 1; fi
  rm -rf -- "$candidate"
}

candidate_payload_paths() {
  local root="$1" modules_line module
  local -a modules=()
  [ "$(grep -Ec '^MM_MODULES=\([a-z0-9 -]+\)$' "$root/lib/env.sh")" = 1 ] || return 1
  modules_line="$(grep -m1 '^MM_MODULES=(' "$root/lib/env.sh")"
  modules_line="${modules_line#MM_MODULES=(}"
  modules_line="${modules_line%)}"
  read -r -a modules <<<"$modules_line"
  [ "${#modules[@]}" -gt 0 ] && [ "${modules[0]}" = env ] || return 1
  [ "$(printf '%s\n' "${modules[@]}" | LC_ALL=C sort -u | wc -l | tr -d ' ')" = "${#modules[@]}" ] || return 1
  printf '%s\n' VERSION README.md mm.sh mtp.sh metadata/upstream.env scripts/watchdog.sh
  for module in "${modules[@]}"; do
    [[ "$module" =~ ^[a-z][a-z0-9-]*$ ]] || return 1
    printf 'lib/%s.sh\n' "$module"
  done
}

validate_project_candidate() {
  local root="$1" tag="$2" version path expected actual mode digest special links
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { print_err "发布 tag 格式无效。"; return 1; }
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  for path in VERSION README.md mm.sh mtp.sh lib/env.sh metadata/upstream.env scripts/watchdog.sh MANIFEST.sha256; do
    if [ ! -f "$root/$path" ] || [ -L "$root/$path" ]; then print_err "候选缺少普通文件：$path"; return 1; fi
  done
  grep -Fxq 'REPO_OWNER="famintt"' "$root/mm.sh" || { print_err "候选仓库 owner 不是 famintt。"; return 1; }
  version="${tag#v}"
  if [ "$(cat "$root/VERSION")" != "$tag" ] || [ "$(wc -c <"$root/VERSION" | tr -d ' ')" != "$((${#tag}+1))" ]; then print_err "VERSION 与发布 tag 不一致。"; return 1; fi
  for path in mm.sh mtp.sh; do
    if [ "$(grep -c '^SCRIPT_VERSION=' "$root/$path")" != 1 ] || ! grep -Fxq "SCRIPT_VERSION=\"$version\"" "$root/$path"; then print_err "$path 版本声明与 tag 不一致。"; return 1; fi
  done
  expected="$(candidate_payload_paths "$root" | LC_ALL=C sort)" || return 1
  [ -n "$expected" ] || return 1
  actual="$(find "$root" -mindepth 1 -type f ! -path "$root/MANIFEST.sha256" -printf '%P\n' | LC_ALL=C sort)" || return 1
  [ "$actual" = "$expected" ] || { print_err "候选文件清单不完整或包含多余文件。"; return 1; }
  actual="$(find "$root" -mindepth 1 -type d -printf '%P\n' | LC_ALL=C sort)" || return 1
  [ "$actual" = $'lib\nmetadata\nscripts' ] || return 1
  special="$(find "$root" ! -type f ! -type d -print -quit)" || return 1
  [ -z "$special" ] || return 1
  links="$(find "$root" -type f -links +1 -print -quit)" || return 1
  [ -z "$links" ] || return 1
  [ "$(stat -c '%a' "$root")" = 755 ] || return 1
  while IFS= read -r path; do
    case "$path" in mm.sh | mtp.sh | scripts/watchdog.sh) mode=755 ;; *) mode=644 ;; esac
    [ "$(stat -c '%a' "$root/$path")" = "$mode" ] || { print_err "候选文件权限异常：$path"; return 1; }
    case "$path" in *.sh) bash -n "$root/$path" || return 1 ;; esac
    if [ "$path" = metadata/upstream.env ]; then bash -n "$root/$path" || return 1; fi
  done <<<"$expected"
  for path in lib metadata scripts; do [ "$(stat -c '%a' "$root/$path")" = 755 ] || return 1; done
  [ "$(stat -c '%a' "$root/MANIFEST.sha256")" = 644 ] || return 1
  actual="$(while IFS= read -r path; do
    digest="$(sha256_file "$root/$path")" || exit 1
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || exit 1
    printf '%s  %s\n' "$digest" "$path"
  done <<<"$expected")" || return 1
  if [ "$(cat "$root/MANIFEST.sha256")" != "$actual" ] || [ "$(wc -c <"$root/MANIFEST.sha256" | tr -d ' ')" != "$((${#actual}+1))" ]; then print_err "候选 MANIFEST.sha256 摘要或格式不匹配。"; return 1; fi
}
install_snapshot_paths() {
  local txn="$1" path i=0
  mkdir -p "$txn/files" || return 1
  : >"$txn/paths"
  for path in "$LIB_DIR" "$INSTALL_BIN" "${MTP_BIN:-/usr/local/bin/mtp}" "$WATCHDOG_TARGET" "$UPSTREAM_ENV" "$SYSTEMD_SERVICE_FILE" "$SYSTEMD_WATCHDOG_SERVICE_FILE" "$SYSTEMD_WATCHDOG_TIMER_FILE" "$OPENRC_SERVICE_FILE"; do
    [ -n "$path" ] && [ ! -L "$path" ] || return 1
    printf '%s\n' "$path" >>"$txn/paths" || return 1
    if [ -e "$path" ]; then cp -a -- "$path" "$txn/files/$i" || return 1; touch "$txn/present.$i" || return 1; fi
    i=$((i+1))
  done
  if command_exists crontab && crontab -l >"$txn/crontab" 2>/dev/null; then touch "$txn/had-crontab"; fi
}

install_restore_paths() {
  local txn="$1" path i=0 failed=0
  while IFS= read -r path; do
    rm -rf -- "$path" || failed=1
    if [ -f "$txn/present.$i" ]; then
      mkdir -p "$(dirname "$path")" && cp -a -- "$txn/files/$i" "$path" || failed=1
    fi
    i=$((i+1))
  done <"$txn/paths"
  if systemd_available; then systemctl daemon-reload >/dev/null 2>&1 || failed=1; fi
  if command_exists crontab; then
    if [ -f "$txn/had-crontab" ]; then crontab "$txn/crontab" || failed=1; else crontab -r >/dev/null 2>&1 || true; fi
  fi
  [ "$failed" = 0 ]
}

install_atomic_file() {
  local source="$1" target="$2" mode="$3" tmp
  mkdir -p "$(dirname "$target")" || return 1
  tmp="${target}.mm-new.${BASHPID}"
  [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || return 1
  if ! install -m "$mode" "$source" "$tmp" || ! mv -f -- "$tmp" "$target"; then rm -f -- "$tmp"; return 1; fi
}

install_publish_candidate() {
  local root="$1" txn="$2" stage="${LIB_DIR}.mm-stage.${2##*/}" old="${LIB_DIR}.mm-old.${2##*/}" file
  [ ! -e "$stage" ] && [ ! -e "$old" ] || return 1
  install -d -m 0755 "$stage" || return 1
  printf '%s\n' "$stage" "$old" >"$txn/staging-paths" || return 1
  for file in "$root"/lib/*.sh; do install -m 0644 "$file" "$stage/${file##*/}" || return 1; done
  install -m 0644 "$root/metadata/upstream.env" "$stage/upstream.env" || return 1
  install -m 0644 "$root/MANIFEST.sha256" "$stage/MANIFEST.sha256" || return 1
  install -m 0644 "$root/VERSION" "$stage/VERSION" || return 1
  if [ -d "$LIB_DIR" ]; then mv -- "$LIB_DIR" "$old" || return 1; fi
  mv -- "$stage" "$LIB_DIR" || return 1
  install_atomic_file "$root/metadata/upstream.env" "$UPSTREAM_ENV" 0644 || return 1
  install_atomic_file "$root/scripts/watchdog.sh" "$WATCHDOG_TARGET" 0755 || return 1
  install_atomic_file "$root/mtp.sh" "${MTP_BIN:-/usr/local/bin/mtp}" 0755 || return 1
  install_atomic_file "$root/mm.sh" "$INSTALL_BIN" 0755 || return 1
}

install_stop_watchdog() {
  local tmp
  if systemd_available; then
    if systemctl is-active --quiet "$WATCHDOG_TIMER_NAME"; then systemctl stop "$WATCHDOG_TIMER_NAME" || return 1; fi
    if systemctl is-active --quiet "$WATCHDOG_SERVICE_NAME"; then systemctl stop "$WATCHDOG_SERVICE_NAME" || return 1; fi
  fi
  if command_exists crontab; then
    tmp="$(mktemp)" || return 1
    (crontab -l 2>/dev/null | grep -Fv "$WATCHDOG_TARGET" | grep -Fv 'no crontab for' || true) >"$tmp"
    crontab "$tmp" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
  fi
}

install_load_modules() {
  local root="$1" file module modules_line
  local -a modules=()
  modules_line="$(grep -m1 '^MM_MODULES=(' "$root/env.sh")" || return 1
  modules_line="${modules_line#MM_MODULES=(}"
  modules_line="${modules_line%)}"
  read -r -a modules <<<"$modules_line"
  for module in "${modules[@]}"; do
    file="$root/$module.sh"
    [ -f "$file" ] || return 1
    # shellcheck source=/dev/null
    . "$file" || return 1
  done
  # shellcheck source=/dev/null
  . "$UPSTREAM_ENV"
}

install_project_candidate() {
  [ "$#" = 2 ] || { print_err "install_project_candidate 需要候选目录和 tag。"; return 2; }
  local candidate="$1" tag="$2" root txn state_snapshot="" stack=0 acquired=false failure=0 recovery_failed=0
  local service_active=false service_enabled=false
  local old_source="${SOURCE_ROOT:-}" old_version="${SCRIPT_VERSION:-}"
  [ -z "${_AUTO_ROLLBACK_DIR:-}" ] || { print_err "存在未提交状态事务，拒绝安装升级。"; return 1; }
  root="$(cd -P -- "$candidate" 2>/dev/null && pwd)" || return 1
  validate_project_candidate "$root" "$tag" || return 1
  if [ "${LOCK_HELD:-false}" != true ] || [ "${LOCK_OWNER_PID:-}" != "${BASHPID}" ]; then acquire_lock || return 1; acquired=true; fi
  txn="$(mktemp -d "${LOCK_ROOT}/.install.XXXXXX")" || { [ "$acquired" != true ] || release_lock; return 1; }
  if ! install_snapshot_paths "$txn"; then rm -rf -- "$txn"; [ "$acquired" != true ] || release_lock; return 1; fi
  if [ -e "$CONFIG_FILE" ] || [ -e "$SYSTEMD_SERVICE_FILE" ] || [ -e "$OPENRC_SERVICE_FILE" ]; then
    stack=1
    state_snapshot="$(backup_state)" || { print_err "无法创建升级状态快照，升级已取消。"; rm -rf -- "$txn"; [ "$acquired" != true ] || release_lock; return 1; }
    [ -d "$state_snapshot" ] || { rm -rf -- "$txn"; [ "$acquired" != true ] || release_lock; return 1; }
  fi
  if [ "$stack" = 1 ]; then
    if systemd_available; then
      if systemctl is-active --quiet "$SERVICE_NAME"; then service_active=true; fi
      if systemctl is-enabled --quiet "$SERVICE_NAME"; then service_enabled=true; fi
    elif openrc_available; then if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then service_active=true; fi
    elif declare -F service_state >/dev/null 2>&1 && [ "$(service_state)" = 运行中 ]; then service_active=true
    fi
    install_stop_watchdog || failure=1
    if [ "$failure" = 0 ]; then stop_service || failure=1; fi
    if [ "$failure" = 0 ] && declare -F stop_all_argo_nodes >/dev/null 2>&1; then stop_all_argo_nodes || failure=1; fi
    # Candidate sub_migrate verifies/stops legacy subscription processes with its new identity rules.
  fi
  if [ "$failure" = 0 ]; then install_publish_candidate "$root" "$txn" || failure=1; fi
  if [ "$failure" = 0 ] && [ "$stack" = 1 ]; then
    SOURCE_ROOT=""
    SCRIPT_VERSION="${tag#v}"
    install_load_modules "$LIB_DIR" || failure=1
    if [ "$failure" = 0 ]; then
      if ! declare -F sub_migrate >/dev/null 2>&1 || ! sub_migrate; then print_err "订阅迁移失败，停止发布。"; failure=1; fi
    fi
    if [ "$failure" = 0 ]; then
      # shellcheck disable=SC2034
      MM_DEFER_WATCHDOG_ENABLE=1
      if systemd_available; then create_systemd_units || failure=1
      elif openrc_available; then create_openrc_units || failure=1
      fi
      if [ "$failure" = 0 ]; then start_service || failure=1; fi
      unset MM_DEFER_WATCHDOG_ENABLE
    fi
    if [ "$failure" = 0 ] && declare -F restart_all_argo_nodes >/dev/null 2>&1; then restart_all_argo_nodes || failure=1; fi
    if [ "$failure" = 0 ] && declare -F ensure_sub >/dev/null 2>&1; then ensure_sub || failure=1; fi
    if [ "$failure" = 0 ]; then sanitize_permissions || failure=1; fi
    if [ "$failure" = 0 ]; then
      if declare -F ensure_watchdog_enabled >/dev/null 2>&1; then ensure_watchdog_enabled || failure=1
      elif systemd_available; then systemctl enable --now "$WATCHDOG_TIMER_NAME" >/dev/null 2>&1 || failure=1
      else create_cron_watchdog || failure=1
      fi
    fi
  fi
  if [ "$failure" != 0 ]; then
    print_err "候选版本安装/启动失败，正在恢复完整旧版本。"
    if [ "$stack" = 1 ]; then
      install_stop_watchdog || recovery_failed=1
      stop_service || recovery_failed=1
      if declare -F stop_all_argo_nodes >/dev/null 2>&1; then stop_all_argo_nodes || recovery_failed=1; fi
      if declare -F sub_stop >/dev/null 2>&1; then sub_stop || recovery_failed=1; fi
    fi
    if ! install_restore_paths "$txn"; then print_err "旧版本文件/服务单元恢复不完整。"; recovery_failed=1; fi
    SOURCE_ROOT="$old_source"
    SCRIPT_VERSION="$old_version"
    if [ -f "$LIB_DIR/env.sh" ]; then install_load_modules "$LIB_DIR" || recovery_failed=1; fi
    if [ -n "$state_snapshot" ]; then restore_state_backup "$state_snapshot" || recovery_failed=1; fi
    if [ "$stack" = 1 ] && [ "$recovery_failed" = 0 ]; then
      # A rollback never restarts the old public subscription ingress or watchdog.
      # shellcheck disable=SC2034
      MM_DEFER_WATCHDOG_ENABLE=1
      if [ "$service_active" = true ]; then start_service || recovery_failed=1; fi
      unset MM_DEFER_WATCHDOG_ENABLE
      if systemd_available; then
        if [ "$service_enabled" = true ]; then systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || recovery_failed=1; else systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || recovery_failed=1; fi
        systemctl disable --now "$WATCHDOG_TIMER_NAME" >/dev/null 2>&1 || recovery_failed=1
      fi
    fi
    if [ "$recovery_failed" = 0 ]; then
      install_cleanup_staging "$txn" || recovery_failed=1
    fi
    if [ "$recovery_failed" = 0 ]; then rm -rf -- "$txn"; else print_err "回滚未完整完成，保留恢复资料：$txn"; fi
    [ "$acquired" != true ] || release_lock
    return 1
  fi
  install_cleanup_staging "$txn" || { print_warn "版本已发布，保留暂存资料：$txn"; [ "$acquired" != true ] || release_lock; return 1; }
  rm -rf -- "$txn"
  [ "$acquired" != true ] || release_lock
  print_ok "候选版本 $tag 已完成原子发布。"
}

install_cleanup_staging() {
  local txn="$1" path
  [ ! -f "$txn/staging-paths" ] || while IFS= read -r path; do
    case "$path" in "${LIB_DIR}.mm-stage."* | "${LIB_DIR}.mm-old."*) rm -rf -- "$path" || return 1 ;; *) return 1 ;; esac
  done <"$txn/staging-paths"
}
validate_release_archive() {
  local bundle="$1" tag="$2" root="mihomo-manager-$2" entries_text listing_text entry line kind mode
  local -a entries=() listings=()
  local -A seen=()
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  tar -tzf "$bundle" >/dev/null 2>&1 || return 1
  entries_text="$(tar -tzf "$bundle")" || return 1
  listing_text="$(tar -tvzf "$bundle")" || return 1
  mapfile -t entries <<<"$entries_text"
  mapfile -t listings <<<"$listing_text"
  [ "${#entries[@]}" -gt 0 ] && [ "${#entries[@]}" = "${#listings[@]}" ] || return 1
  for i in "${!entries[@]}"; do
    entry="${entries[$i]}"; line="${listings[$i]}"
    [[ "$entry" == "$root/"* ]] || { print_err "归档包含根目录外路径。"; return 1; }
    [[ "$entry" != *"/../"* && "$entry" != *"//"* && "$entry" != /* && "$entry" != *$'\r'* ]] || return 1
    [ -z "${seen[$entry]+x}" ] || { print_err "归档包含重复路径：$entry"; return 1; }
    seen[$entry]=1
    kind="${line:0:1}"; mode="${line:0:10}"
    case "$entry" in
      "$root/" | "$root/lib/" | "$root/metadata/" | "$root/scripts/") [ "$kind" = d ] && [ "$mode" = drwxr-xr-x ] || return 1 ;;
      "$root/VERSION" | "$root/README.md" | "$root/MANIFEST.sha256" | "$root/metadata/upstream.env" | "$root/lib/"[a-z0-9-]*.sh) [ "$kind" = - ] && [ "$mode" = -rw-r--r-- ] || return 1 ;;
      "$root/mm.sh" | "$root/mtp.sh" | "$root/scripts/watchdog.sh") [ "$kind" = - ] && [ "$mode" = -rwxr-xr-x ] || return 1 ;;
      *) print_err "归档含未授权路径：$entry"; return 1 ;;
    esac
  done
  [ -n "${seen[$root/]+x}" ] && [ -n "${seen[$root/lib/]+x}" ] && [ -n "${seen[$root/metadata/]+x}" ] && [ -n "${seen[$root/scripts/]+x}" ]
}
install_release_bundle() {
  local tag="$1" bundle_name bundle_url checksums_url tmpdir bundle_file checksums_file expected actual root_dir result
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fatal "发布 tag 格式无效。"
  bundle_name="mihomo-manager-${tag}.tar.gz"
  tmpdir="$(mktemp -d)" || return 1
  bundle_file="${tmpdir}/${bundle_name}"; checksums_file="${tmpdir}/checksums.txt"
  bundle_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${tag}/${bundle_name}"
  checksums_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${tag}/checksums.txt"
  if ! download_file "${checksums_url}" "${checksums_file}"; then rm -rf -- "$tmpdir"; fatal "下载 checksums.txt 失败。"; fi
  if ! download_file "${bundle_url}" "${bundle_file}"; then rm -rf -- "$tmpdir"; fatal "下载 ${bundle_name} 失败。"; fi
  if [ "$(wc -l <"$checksums_file" | tr -d ' ')" != 1 ]; then rm -rf -- "$tmpdir"; fatal "checksums.txt 必须只有 bundle 一行。"; fi
  expected="$(sed -nE "s/^([0-9a-f]{64})  ${bundle_name}$/\\1/p" "$checksums_file")" || { rm -rf -- "$tmpdir"; return 1; }
  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then rm -rf -- "$tmpdir"; fatal "checksums.txt 格式或 bundle 名称不匹配。"; fi
  actual="$(sha256_file "$bundle_file")" || { rm -rf -- "$tmpdir"; return 1; }
  if [ "$actual" != "$expected" ]; then rm -rf -- "$tmpdir"; fatal "发布包 SHA256 校验失败。"; fi
  if ! gzip -t "$bundle_file"; then rm -rf -- "$tmpdir"; fatal "发布包 gzip 校验失败。"; fi
  if ! validate_release_archive "$bundle_file" "$tag"; then rm -rf -- "$tmpdir"; fatal "发布包归档头校验失败。"; fi
  if ! tar -xzf "$bundle_file" --same-permissions -C "$tmpdir"; then rm -rf -- "$tmpdir"; fatal "发布包解压失败。"; fi
  root_dir="${tmpdir}/mihomo-manager-${tag}"
  if [ ! -d "$root_dir" ] || [ -L "$root_dir" ]; then rm -rf -- "$tmpdir"; fatal "发布包根目录异常。"; fi
  if ! validate_project_candidate "$root_dir" "$tag"; then rm -rf -- "$tmpdir"; fatal "发布包候选校验失败。"; fi
  result=0
  if install_project_candidate "$root_dir" "$tag"; then result=0; else result=$?; fi
  rm -rf -- "$tmpdir"
  return "$result"
}
install_mihomo_core() {
  local arch asset tmpdir archive expected
  local -a urls
  arch="$(detect_arch)" || fatal "暂不支持当前 CPU 架构：$(uname -m)"
  asset="${MIHOMO_ASSET[$arch]:-}"
  expected="${MIHOMO_SHA256[$arch]:-}"
  [ -n "${asset}" ] || fatal "未配置 ${arch} 对应的 mihomo 安装包。"
  [ -n "${expected}" ] || fatal "未配置 ${arch} 对应的 mihomo 校验值。"

  # 官方源优先，官方源不可达时回退本仓库镜像（SHA256 校验不因换源放松）
  local -a urls=()
  urls+=("https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/${asset}")
  [ -n "${MIHOMO_MIRROR_BASE:-}" ] && urls+=("${MIHOMO_MIRROR_BASE}/${asset}")

  tmpdir="$(mktemp -d)"
  archive="${tmpdir}/${asset}"
  print_info "正在安装 mihomo ${MIHOMO_VERSION} (${arch})"
  if ! download_file_multi "${archive}" "${urls[@]}"; then
    rm -rf "${tmpdir}"
    fatal "下载 mihomo 失败（已尝试 ${#urls[@]} 个源）。"
  fi
  verify_sha256 "${archive}" "${expected}"
  gzip -dc "${archive}" > "${tmpdir}/mihomo"
  [ -s "${tmpdir}/mihomo" ] || fatal "安装包解压后为空（非预期 gzip 资产）。"
  install -m 0755 "${tmpdir}/mihomo" "${MIHOMO_BIN}"
  ensure_binary_runs "${MIHOMO_BIN}" "mihomo" -v
  rm -rf "${tmpdir}"
  print_ok "mihomo 已安装到 ${MIHOMO_BIN}"
}

install_cloudflared_bin() {
  local arch asset tmpfile expected version actual_version
  local -a urls=()
  arch="$(detect_arch)" || fatal "暂不支持当前 CPU 架构：$(uname -m)"
  asset="${CLOUDFLARED_ASSET[$arch]:-}"
  expected="${CLOUDFLARED_SHA256[$arch]:-}"
  version="${CLOUDFLARED_VERSION:-}"
  if [ -z "$asset" ] || [ -z "$version" ]; then fatal "cloudflared 缺少固定版本或资产信息。"; fi
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || fatal "未配置 ${arch} 对应的 cloudflared SHA256，拒绝安装。"
  urls+=("https://github.com/cloudflare/cloudflared/releases/download/${version}/${asset}")
  if [ -n "${CLOUDFLARED_MIRROR_BASE:-}" ]; then urls+=("${CLOUDFLARED_MIRROR_BASE}/${asset}"); fi
  tmpfile="$(mktemp)" || return 1
  print_info "正在安装 cloudflared ${version} (${arch})"
  if ! download_file_multi "$tmpfile" "${urls[@]}"; then rm -f -- "$tmpfile"; fatal "下载 cloudflared 失败（已尝试 ${#urls[@]} 个源）。"; fi
  if ! verify_sha256 "$tmpfile" "$expected"; then rm -f -- "$tmpfile"; return 1; fi
  chmod 0755 "$tmpfile" || { rm -f -- "$tmpfile"; return 1; }
  actual_version="$("$tmpfile" version 2>/dev/null | grep -oE '[0-9]{4}[.][0-9]+[.][0-9]+' | head -n 1 || true)"
  if [ "$actual_version" != "$version" ]; then rm -f -- "$tmpfile"; fatal "cloudflared 运行时版本校验失败：期望 ${version}，实际 ${actual_version:-无法运行}。"; fi
  if ! install -m 0755 "$tmpfile" "$CLOUDFLARED_BIN"; then rm -f -- "$tmpfile"; return 1; fi
  rm -f -- "$tmpfile"
  ensure_binary_runs "$CLOUDFLARED_BIN" "cloudflared" version
  print_ok "cloudflared 已安装到 ${CLOUDFLARED_BIN}（${version}，SHA256 已校验）"
}

install_core() {
  local acquired=false failed=0 state_snapshot="" service_attempted=false
  [ -z "${_AUTO_ROLLBACK_DIR:-}" ] || { print_err "存在未提交状态事务，拒绝安装。"; return 1; }
  ensure_dependencies || return 1
  if [ "${LOCK_HELD:-false}" != true ] || [ "${LOCK_OWNER_PID:-}" != "${BASHPID}" ]; then acquire_lock || return 1; acquired=true; fi
  sync_project_assets_from_source || failed=1
  if [ "$failed" = 0 ]; then init_storage || failed=1; fi
  # This is a committed prerequisite phase before the caller's candidate-node transaction.
  if [ "$failed" = 0 ]; then state_snapshot="$(backup_state)" || failed=1; fi
  if [ "$failed" = 0 ] && [ ! -d "$state_snapshot" ]; then failed=1; fi
  if [ "$failed" = 0 ]; then install_mihomo_core || failed=1; fi
  if [ "$failed" = 0 ] && argo_required; then install_cloudflared_bin || failed=1; fi
  if [ "$failed" = 0 ]; then ensure_low_memory_guard || failed=1; fi
  if [ "$failed" = 0 ]; then render_config || failed=1; fi
  if [ "$failed" = 0 ]; then apply_network_tune || failed=1; fi
  if [ "$failed" = 0 ]; then
    export MM_DEFER_WATCHDOG_ENABLE=1
    if systemd_available; then create_systemd_units || failed=1
    elif openrc_available; then create_openrc_units || failed=1
    fi
  fi
  if [ "$failed" = 0 ]; then service_attempted=true; start_service || failed=1; fi
  if [ "$failed" = 0 ]; then restart_all_argo_nodes || failed=1; fi
  if [ "$failed" = 0 ]; then sanitize_permissions || failed=1; fi
  unset MM_DEFER_WATCHDOG_ENABLE
  if [ "$failed" = 0 ]; then ensure_watchdog_enabled || failed=1; fi
  if [ "$failed" != 0 ]; then
    unset MM_DEFER_WATCHDOG_ENABLE
    install_stop_watchdog || true
    stop_all_argo_nodes || true
    if [ "$service_attempted" = true ]; then stop_service || true; fi
    if [ -n "$state_snapshot" ]; then restore_state_backup "$state_snapshot" || print_err "核心准备失败且状态恢复未完成：$state_snapshot"; fi
  fi
  [ "$acquired" != true ] || release_lock
  [ "$failed" = 0 ]
}

latest_release_tag() {
  local remote="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"
  command_exists git || return 1
  git ls-remote --tags --refs "$remote" 'refs/tags/v[0-9]*' 2>/dev/null |
    awk '$2 ~ /^refs\/tags\/v[0-9]+\.[0-9]+\.[0-9]+$/ {sub("refs/tags/", "", $2); print $2}' |
    LC_ALL=C sort -Vu | tail -n 1
}

update_script() {
  local latest_tag
  latest_tag="$(latest_release_tag)" || fatal "无法通过 Git tags 获取版本。"
  [[ "$latest_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fatal "没有找到有效的语义版本 tag。"
  install_release_bundle "$latest_tag" || fatal "升级失败；旧版本已回滚或保留。"
  print_ok "项目文件已更新到 ${latest_tag}"
}

install_restore_systemd_unit_state() {
  local unit="$1" was_active="$2" was_enabled="$3"
  if [ "$was_active" = true ]; then systemctl start "$unit" >/dev/null 2>&1 || return 1
  else systemctl stop "$unit" >/dev/null 2>&1 || return 1
  fi
  if [ "$was_enabled" = true ]; then systemctl enable "$unit" >/dev/null 2>&1 || return 1
  else systemctl disable "$unit" >/dev/null 2>&1 || return 1
  fi
}

uninstall_project() {
  local tag tags="" acquired=false failed=0 txn="" recovery_failed=0
  local service_active=false service_enabled=false watchdog_service_active=false watchdog_service_enabled=false watchdog_timer_active=false watchdog_timer_enabled=false
  [ -z "${_AUTO_ROLLBACK_DIR:-}" ] || { print_err "存在未提交状态事务，拒绝卸载。"; return 1; }
  if ! confirm_yes "这将卸载 ${PROJECT_NAME}，是否继续？"; then print_info "已取消卸载。"; return 1; fi
  if [ "${LOCK_HELD:-false}" != true ] || [ "${LOCK_OWNER_PID:-}" != "${BASHPID}" ]; then acquire_lock || return 1; acquired=true; fi
  # Record runtime state before stopping any component; the stable lock remains held to the end.
  if systemd_available; then
    if systemctl is-active --quiet "$SERVICE_NAME"; then service_active=true; fi
    if systemctl is-enabled --quiet "$SERVICE_NAME"; then service_enabled=true; fi
    if systemctl is-active --quiet "$WATCHDOG_SERVICE_NAME"; then watchdog_service_active=true; fi
    if systemctl is-enabled --quiet "$WATCHDOG_SERVICE_NAME"; then watchdog_service_enabled=true; fi
    if systemctl is-active --quiet "$WATCHDOG_TIMER_NAME"; then watchdog_timer_active=true; fi
    if systemctl is-enabled --quiet "$WATCHDOG_TIMER_NAME"; then watchdog_timer_enabled=true; fi
  fi
  if declare -F stop_all_argo_nodes >/dev/null 2>&1; then
    stop_all_argo_nodes || failed=1
  else
    tags="$(iter_node_tags)" || failed=1
    if [ "$failed" = 0 ]; then
      while IFS= read -r tag; do [ -z "$tag" ] || stop_argo_node "$tag" || failed=1; done <<<"$tags"
    fi
  fi
  stop_service || failed=1
  sub_stop || failed=1
  socks5_whitelist_cleanup || failed=1
  if [ "$failed" != 0 ]; then
    # No watchdog or cron mutation has happened; restore only service activity if it was stopped.
    if [ "$service_active" = true ]; then systemctl is-active --quiet "$SERVICE_NAME" || systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || recovery_failed=1; fi
    print_err "停止本实例资源失败，保留安装文件。"
    [ "$acquired" != true ] || release_lock
    return 1
  fi
  txn="$(mktemp -d "${LOCK_ROOT}/.uninstall.XXXXXX")" || { [ "$service_active" != true ] || systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true; [ "$acquired" != true ] || release_lock; return 1; }
  if ! install_snapshot_paths "$txn"; then
    rm -rf -- "$txn"
    [ "$service_active" != true ] || systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true
    [ "$acquired" != true ] || release_lock
    return 1
  fi
  if install_stop_watchdog; then
    if systemd_available; then
      systemctl disable --now "$WATCHDOG_TIMER_NAME" >/dev/null 2>&1 || failed=1
      systemctl disable --now "$WATCHDOG_SERVICE_NAME" >/dev/null 2>&1 || failed=1
      systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || failed=1
      if [ "$failed" = 0 ]; then
        rm -f -- "$SYSTEMD_SERVICE_FILE" "$SYSTEMD_WATCHDOG_SERVICE_FILE" "$SYSTEMD_WATCHDOG_TIMER_FILE" || failed=1
        systemctl daemon-reload >/dev/null 2>&1 || failed=1
      fi
    elif openrc_available; then
      if [ -f "$OPENRC_SERVICE_FILE" ]; then rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || failed=1; fi
      if [ "$failed" = 0 ]; then rm -f -- "$OPENRC_SERVICE_FILE" || failed=1; fi
    fi
  else
    failed=1
  fi
  if [ "$failed" != 0 ]; then
    if ! install_restore_paths "$txn"; then recovery_failed=1; fi
    if systemd_available; then
      install_restore_systemd_unit_state "$SERVICE_NAME" "$service_active" "$service_enabled" || recovery_failed=1
      install_restore_systemd_unit_state "$WATCHDOG_SERVICE_NAME" "$watchdog_service_active" "$watchdog_service_enabled" || recovery_failed=1
      install_restore_systemd_unit_state "$WATCHDOG_TIMER_NAME" "$watchdog_timer_active" "$watchdog_timer_enabled" || recovery_failed=1
    fi
    if [ "$recovery_failed" = 0 ]; then rm -rf -- "$txn"; else print_err "卸载未能恢复服务单元状态；保留恢复资料：$txn"; fi
    [ "$acquired" != true ] || release_lock
    return 1
  fi
  rm -rf -- "$txn"
  if declare -F remove_net_tune >/dev/null 2>&1; then remove_net_tune || print_warn "保留无法确认归属的 sysctl 文件。"; fi
  # Independent MTProto and shared cloudflared artifacts are intentionally preserved.
  rm -rf -- "$BASE_DIR" "$LIB_DIR" || failed=1
  rm -f -- "$INSTALL_BIN" "$MIHOMO_BIN" || failed=1
  [ "$acquired" != true ] || release_lock
  [ "$failed" = 0 ] || return 1
  print_ok "项目已卸载；保留独立 MTProxy 和可能共用的 cloudflared。"
}
