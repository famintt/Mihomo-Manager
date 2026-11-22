#!/usr/bin/env bash
# openrc 模板内的 PID_FILE 为模板变量（定义于 mm.sh），按要求豁免 SC2153。
# shellcheck disable=SC2153
set -eEuo pipefail

umask 077

MIHOMO_SERVICE_USER="${MIHOMO_SERVICE_USER:-mihomo}"
MIHOMO_SERVICE_GROUP="${MIHOMO_SERVICE_GROUP:-mihomo}"
MIHOMO_DATA_DIR="${MIHOMO_DATA_DIR:-${BASE_DIR}/data}"
MM_CLI="${MM_CLI:-${INSTALL_BIN:-/usr/local/bin/mm}}"

mihomo_data_dir() {
  local dir="${MIHOMO_DATA_DIR}" base="${BASE_DIR%/}" current="" part
  [[ "${base}" = /* ]] || { print_err "BASE_DIR 必须为绝对路径。"; return 1; }
  case "${base}${dir}" in
    *:* | *[[:space:]]* | *$'\n'* | *$'\r'* | *'\\'*) print_err "mihomo 数据路径含不安全字符。"; return 1 ;;
  esac
  [ "${dir}" = "${base}/data" ] || { print_err "mihomo 数据目录只能是 BASE_DIR/data。"; return 1; }
  local -a parts=()
  IFS='/' read -r -a parts <<< "${dir#/}"
  for part in "${parts[@]}"; do
    [ -n "${part}" ] || continue
    [ "${part}" != . ] && [ "${part}" != .. ] || return 1
    current="${current}/${part}"
    [ ! -L "${current}" ] || { print_err "拒绝符号链接路径组件：${current}"; return 1; }
  done
  printf '%s' "${dir}"
}

mihomo_safe_paths() {
  local base cert data
  case "${BASE_DIR}${CERT_DIR}" in
    *:* | *[[:space:]]* | *$'\n'* | *$'\r'* | *'\\'*) print_err "SAFE_PATHS 路径含不安全字符。"; return 1 ;;
  esac
  [ -d "${BASE_DIR}" ] && [ ! -L "${BASE_DIR}" ] || return 1
  [ -d "${CERT_DIR}" ] && [ ! -L "${CERT_DIR}" ] || return 1
  data="$(mihomo_data_dir)" || return 1
  [ -d "${data}" ] && [ ! -L "${data}" ] || { print_err "mihomo 数据目录不存在或是符号链接。"; return 1; }
  base="$(cd -P -- "${BASE_DIR}" && pwd)" || return 1
  cert="$(cd -P -- "${CERT_DIR}" && pwd)" || return 1
  data="$(cd -P -- "${data}" && pwd)" || return 1
  [ "${base}" = "${BASE_DIR%/}" ] && [ "${cert}" = "${CERT_DIR%/}" ] && [ "${data}" = "${MIHOMO_DATA_DIR%/}" ] || { print_err "SAFE_PATHS 路径不能经过符号链接。"; return 1; }
  printf '%s:%s' "${base}" "${cert}"
}

service_config_permissions() {
  local config="${1:-${CONFIG_FILE}}" base_real config_real
  [ -f "${config}" ] && [ ! -L "${config}" ] || { print_err "配置文件不存在或是符号链接：${config}"; return 1; }
  case "${BASE_DIR}${config}" in *:* | *[[:space:]]* | *$'\n'* | *$'\r'* | *'\\'*) print_err "配置路径含不安全字符。"; return 1 ;; esac
  base_real="$(cd -P -- "${BASE_DIR}" && pwd)" || return 1
  config_real="$(cd -P -- "$(dirname -- "${config}")" && pwd)/$(basename -- "${config}")" || return 1
  case "${config_real}" in "${base_real}"/*) ;; *) print_err "配置文件必须位于 BASE_DIR 内。"; return 1 ;; esac
  [ "${MM_TEST_MODE:-0}" = 1 ] && return 0
  service_ensure_identity || return 1
  chown root:"${MIHOMO_SERVICE_GROUP}" "${config}" || return 1
  chmod 0640 "${config}"
}

mihomo_validate() {
  local config="${1:-${CONFIG_FILE}}" safe data
  service_data_permissions || return 1
  service_config_permissions "${config}" || return 1
  safe="$(mihomo_safe_paths)" || return 1
  data="$(mihomo_data_dir)" || return 1
  if [ "${MM_TEST_MODE:-0}" = 1 ]; then
    SAFE_PATHS="${safe}" "${MIHOMO_BIN}" -d "${data}" -t -f "${config}"
  else
    service_run_as_user "${safe}" "${MIHOMO_BIN}" -d "${data}" -t -f "${config}"
  fi
}

mihomo_run() {
  local config="${1:-${CONFIG_FILE}}" safe data
  service_data_permissions || return 1
  service_config_permissions "${config}" || return 1
  safe="$(mihomo_safe_paths)" || return 1
  data="$(mihomo_data_dir)" || return 1
  mihomo_exec_as_user "${safe}" "${MIHOMO_BIN}" -d "${data}" -f "${config}"
}

# 以服务用户执行所需的降权工具：BusyBox 的 setpriv 只管理能力位、不支持 uid/gid
# 切换（Alpine 精简镜像常见），所以必须先做功能探测再选择，不能只看命令是否存在。
service_shell_quote() {
  local out='' arg
  for arg in "$@"; do
    out+="'${arg//\'/\'\\\'\'}' "
  done
  printf '%s' "${out% }"
}

service_priv_drop_kind() {
  if command_exists setpriv && setpriv --reuid=0 --regid=0 --clear-groups -- true >/dev/null 2>&1; then
    printf 'setpriv'
    return 0
  fi
  if command_exists su-exec; then
    printf 'su-exec'
    return 0
  fi
  if command_exists su; then
    printf 'su'
    return 0
  fi
  return 1
}

service_run_as_user() {
  local safe="$1" kind uid gid
  shift
  if [ "${MM_TEST_MODE:-0}" = 1 ]; then
    SAFE_PATHS="${safe}" "$@"
    return $?
  fi
  service_ensure_identity || return 1
  kind="$(service_priv_drop_kind)" || {
    print_err "需要可用的 setpriv（util-linux）、su-exec 或 su 才能以专用 mihomo 用户校验配置。"
    return 1
  }
  case "${kind}" in
    setpriv)
      uid="$(id -u "${MIHOMO_SERVICE_USER}")" || return 1
      gid="$(id -g "${MIHOMO_SERVICE_USER}")" || return 1
      setpriv --reuid="${uid}" --regid="${gid}" --clear-groups -- env "SAFE_PATHS=${safe}" "$@"
      ;;
    su-exec)
      su-exec "${MIHOMO_SERVICE_USER}:${MIHOMO_SERVICE_GROUP}" env "SAFE_PATHS=${safe}" "$@"
      ;;
    su)
      su -s /bin/sh -c "$(service_shell_quote env "SAFE_PATHS=${safe}" "$@")" "${MIHOMO_SERVICE_USER}"
      ;;
  esac
}

mihomo_exec_as_user() {
  local safe="$1" kind uid gid
  shift
  if [ "${MM_TEST_MODE:-0}" = 1 ]; then
    exec env "SAFE_PATHS=${safe}" "$@"
  fi
  service_ensure_identity || return 1
  kind="$(service_priv_drop_kind)" || {
    print_err "需要可用的 setpriv（util-linux）、su-exec 或 su 才能以专用 mihomo 用户运行。"
    return 1
  }
  case "${kind}" in
    setpriv)
      uid="$(id -u "${MIHOMO_SERVICE_USER}")" || return 1
      gid="$(id -g "${MIHOMO_SERVICE_USER}")" || return 1
      exec setpriv --reuid="${uid}" --regid="${gid}" --clear-groups \
        --inh-caps=+net_bind_service,+net_raw --ambient-caps=+net_bind_service,+net_raw \
        --bounding-set=+net_bind_service,+net_raw -- env "SAFE_PATHS=${safe}" "$@"
      ;;
    su-exec)
      exec su-exec "${MIHOMO_SERVICE_USER}:${MIHOMO_SERVICE_GROUP}" env "SAFE_PATHS=${safe}" "$@"
      ;;
    su)
      exec su -s /bin/sh -c "$(service_shell_quote env "SAFE_PATHS=${safe}" "$@")" "${MIHOMO_SERVICE_USER}"
      ;;
  esac
}

service_certificate_permissions() {
  local cert="${1:-}" key="${2:-}" group="${MIHOMO_SERVICE_GROUP}"
  [ "${MM_TEST_MODE:-0}" = "1" ] && return 0
  service_ensure_identity || return 1
  [ -n "${cert}" ] && [ -n "${key}" ] || return 1
  [ ! -L "${cert}" ] && [ ! -L "${key}" ] || return 1
  [ -f "${cert}" ] && [ -f "${key}" ] || return 1
  case "${cert}" in "${CERT_DIR}"/*) ;; *) print_err "证书路径超出 CERT_DIR。"; return 1 ;; esac
  case "${key}" in "${CERT_DIR}"/*) ;; *) print_err "私钥路径超出 CERT_DIR。"; return 1 ;; esac
  local cert_dir key_dir
  cert_dir="$(cd -P -- "$(dirname -- "${cert}")" && pwd)" || return 1
  key_dir="$(cd -P -- "$(dirname -- "${key}")" && pwd)" || return 1
  [ "${cert_dir}" = "${CERT_DIR%/}" ] && [ "${key_dir}" = "${CERT_DIR%/}" ] || { print_err "证书路径不能经过符号链接目录。"; return 1; }
  chown root:"${group}" "${cert}" "${key}" || return 1
  chmod 0640 "${cert}" "${key}"
}

service_ensure_identity() {
  local nologin="/usr/sbin/nologin"
  [ "${MM_TEST_MODE:-0}" = "1" ] && return 0
  if ! getent group "${MIHOMO_SERVICE_GROUP}" >/dev/null 2>&1; then
    if command_exists groupadd; then
      groupadd --system "${MIHOMO_SERVICE_GROUP}" || return 1
    elif command_exists addgroup; then
      addgroup -S "${MIHOMO_SERVICE_GROUP}" || return 1
    else
      print_err "缺少 groupadd/addgroup，无法建立 mihomo 组。"; return 1
    fi
  fi
  if ! getent passwd "${MIHOMO_SERVICE_USER}" >/dev/null 2>&1; then
    [ -x "${nologin}" ] || nologin="/sbin/nologin"
    if command_exists useradd; then
      useradd --system --no-create-home --gid "${MIHOMO_SERVICE_GROUP}" --shell "${nologin}" "${MIHOMO_SERVICE_USER}" || return 1
    elif command_exists adduser; then
      adduser -S -D -H -G "${MIHOMO_SERVICE_GROUP}" -s "${nologin}" "${MIHOMO_SERVICE_USER}" || return 1
    else
      print_err "缺少 useradd/adduser，无法建立 mihomo 用户。"; return 1
    fi
  fi
  local passwd_entry group_entry uid primary_gid group_gid
  passwd_entry="$(getent passwd "${MIHOMO_SERVICE_USER}")" || return 1
  group_entry="$(getent group "${MIHOMO_SERVICE_GROUP}")" || return 1
  uid="$(printf '%s\n' "${passwd_entry}" | awk -F: '{print $3}')"
  primary_gid="$(printf '%s\n' "${passwd_entry}" | awk -F: '{print $4}')"
  group_gid="$(printf '%s\n' "${group_entry}" | awk -F: '{print $3}')"
  [[ "${uid}" =~ ^[1-9][0-9]*$ ]] || { print_err "mihomo 用户不能是 root 或无效 UID。"; return 1; }
  [ "${primary_gid}" = "${group_gid}" ] || { print_err "mihomo 用户必须以 mihomo 组为主组。"; return 1; }
}

# mihomo 以服务用户身份读取 BASE_DIR 下的配置，因此 BASE_DIR 的每一级父目录都必须
# 允许该用户穿越。发行版默认 /usr/local/etc 是 0755，但有的机器被其他程序建成了
# 0700，核心就会报 “open .../config.yaml: permission denied”。这里只补“其他用户
# 可穿越”一位（0700→0711），不放开读权限；配置本身仍是 root:mihomo 0640。
service_ensure_parent_traversal() {
  local dir parent mode
  [ -n "${BASE_DIR:-}" ] || return 1
  dir="${BASE_DIR}"
  while :; do
    parent="$(dirname "${dir}")"
    [ "${parent}" != "${dir}" ] || break
    dir="${parent}"
    [ "${dir}" != "/" ] || break
    [ -d "${dir}" ] || { print_err "父目录不存在：${dir}"; return 1; }
    mode="$(stat -c '%a' "${dir}" 2>/dev/null)" || { print_err "无法读取目录权限：${dir}"; return 1; }
    case "${mode: -1}" in
    1 | 3 | 5 | 7) continue ;;
    esac
    print_warn "父目录 ${dir} 权限 ${mode} 阻止服务用户穿越，已改为 $(printf '%o' "$((8#${mode} | 1))")。"
    chmod o+x "${dir}" || { print_err "无法为服务用户放开父目录穿越：${dir}"; return 1; }
  done
}

service_data_permissions() {
  local data cert_links
  [ "${MM_TEST_MODE:-0}" = "1" ] && return 0
  service_ensure_identity || return 1
  service_ensure_parent_traversal || return 1
  data="$(mihomo_data_dir)" || return 1
  [ ! -L "${BASE_DIR}" ] && [ ! -L "${CERT_DIR}" ] || return 1
  install -d -o root -g "${MIHOMO_SERVICE_GROUP}" -m 0710 "${BASE_DIR}" "${CERT_DIR}" || return 1
  install -d -o "${MIHOMO_SERVICE_USER}" -g "${MIHOMO_SERVICE_GROUP}" -m 0700 "${data}" || return 1
  install -d -o root -g root -m 0700 "${LOG_DIR}" "${RUNTIME_DIR}" || return 1
  [ ! -L "${CONFIG_FILE}" ] || return 1
  [ ! -f "${CONFIG_FILE}" ] || { chown root:"${MIHOMO_SERVICE_GROUP}" "${CONFIG_FILE}" && chmod 0640 "${CONFIG_FILE}"; } || return 1
  cert_links="$(find "${CERT_DIR}" -type l -print -quit 2>/dev/null)" || return 1
  [ -z "${cert_links}" ] || { print_err "CERT_DIR 中不允许符号链接：${cert_links}"; return 1; }
  find "${CERT_DIR}" -type d -exec chown root:"${MIHOMO_SERVICE_GROUP}" {} + -exec chmod 0710 {} + || return 1
  find "${CERT_DIR}" -type f -exec chown root:"${MIHOMO_SERVICE_GROUP}" {} + -exec chmod 0640 {} + || return 1
  chmod 0710 "${BASE_DIR}" "${CERT_DIR}" || return 1
  chmod 0700 "${LOG_DIR}" "${RUNTIME_DIR}" || return 1
}

read_restart_count() {
  local tag="$1"
  local file="${RUNTIME_DIR}/${tag}.restart_count"
  [ -f "${file}" ] || {
    printf '0'
    return 0
  }
  tr -dc '0-9' <"${file}" 2>/dev/null | grep -E '^[0-9]+$' || printf '0'
}

bump_restart_count() {
  local tag="$1"
  local file="${RUNTIME_DIR}/${tag}.restart_count"
  local current
  current="$(read_restart_count "$tag")"
  printf '%s' "$((current + 1))" >"${file}.tmp" && chmod 600 "${file}.tmp" && mv "${file}.tmp" "${file}"
}

reset_restart_count() {
  local tag="$1"
  rm -f "${RUNTIME_DIR}/${tag}.restart_count"
}

write_pid_file() {
  local pid_file="$1"
  local pid="$2"
  printf '%s\n' "$pid" >"$pid_file"
  chmod 600 "$pid_file"
}

read_pid_file() {
  local pid_file="$1" content
  [ -f "$pid_file" ] && [ ! -L "$pid_file" ] || return 1
  content="$(tr -d ' \r\n' <"$pid_file")" || return 1
  [[ "$content" =~ ^[1-9][0-9]*$ ]] || return 1
  printf "%s" "$content"
}

read_mihomo_pid_file() {
  local identity pid birth
  identity="$(managed_pid_read "${PID_FILE}" mihomo_process_matches)" || return 1
  read -r pid birth <<<"${identity}"
  printf '%s' "${pid}"
}

pid_is_zombie() {
  [ -r "/proc/$1/stat" ] || return 1
  [ "$(awk '{print $3}' /proc/$1/stat 2>/dev/null)" = Z ]
}

pid_matches_binary() {
  local pid="$1" binary="$2" exe
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ -n "$binary" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  pid_is_zombie "$pid" && return 1
  exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
  [ "$exe" = "$binary" ] || [ "$exe" = "$binary (deleted)" ]
}

pid_matches_binary_or_alive() { pid_matches_binary "$1" "$2"; }

mihomo_process_matches() {
  local pid="${1:-}" birth_before birth_after data
  local -a proc_argv=()
  [[ "${pid}" =~ ^[1-9][0-9]*$ ]] && [ "${pid}" -gt 1 ] || return 1
  birth_before="$(managed_proc_birth "${pid}")" || return 1
  managed_proc_exe "${pid}" "${MIHOMO_BIN}" || return 1
  managed_proc_argv "${pid}" || return 1
  [ "${#proc_argv[@]}" -eq 5 ] || return 1
  data="$(mihomo_data_dir)" || return 1
  [ "${proc_argv[1]}" = -d ] || return 1
  [ "${proc_argv[2]}" = "${data}" ] || [ "${proc_argv[2]}" = "${BASE_DIR}" ] || return 1
  [ "${proc_argv[3]}" = -f ] && [ "${proc_argv[4]}" = "${CONFIG_FILE}" ] || return 1
  birth_after="$(managed_proc_birth "${pid}")" || return 1
  [ "${birth_before}" = "${birth_after}" ]
}

write_mihomo_pid_file() {
  local pid="${1:-}" birth tmp i
  [[ "${pid}" =~ ^[1-9][0-9]*$ ]] && [ "${pid}" -gt 1 ] || return 1
  birth="$(managed_proc_birth "${pid}")" || return 1
  for ((i=0; i<50; i++)); do
    mihomo_process_matches "${pid}" && break
    [ "$(managed_proc_birth "${pid}" 2>/dev/null || true)" = "${birth}" ] || { print_err "mihomo 启动进程提前退出或 PID 已复用。"; return 1; }
    sleep 0.1
  done
  [ "${i}" -lt 50 ] || { print_err "mihomo 未能在限定时间内执行目标二进制。"; return 1; }
  [ "$(managed_proc_birth "${pid}")" = "${birth}" ] || return 1
  [ ! -L "${PID_FILE}" ] || return 1
  tmp="$(mktemp "${PID_FILE}.tmp.XXXXXX")" || return 1
  if ! printf '%s %s\n' "${pid}" "${birth}" >"${tmp}" || ! chmod 0600 "${tmp}" || ! mv -f -- "${tmp}" "${PID_FILE}"; then
    rm -f -- "${tmp}"
    return 1
  fi
}

stop_mihomo_candidate() {
  local pid="${1:-}" birth="${2:-}"
  [[ "${pid}" =~ ^[1-9][0-9]*$ ]] && [ "${pid}" -gt 1 ] && [[ "${birth}" =~ ^[0-9]+$ ]] || return 1
  # Only freshly spawned candidates use this path; they may still be before exec.
  # The recorded birth prevents a recycled PID from being signalled.
  managed_pid_stop "${pid}" "${birth}"
}

stop_mihomo_pid_file() {
  local pid birth identity _recorded
  [ -e "${PID_FILE}" ] || return 0
  [ -f "${PID_FILE}" ] && [ ! -L "${PID_FILE}" ] || { print_err "mihomo PID 文件不是普通文件；拒绝停止。"; return 1; }
  read -r pid _recorded <"${PID_FILE}" || return 1
  [[ "${pid}" =~ ^[1-9][0-9]*$ ]] && [ "${pid}" -gt 1 ] || { print_err "mihomo PID 文件格式无效；保留文件。"; return 1; }
  if ! kill -0 "${pid}" 2>/dev/null || pid_is_zombie "${pid}"; then rm -f -- "${PID_FILE}"; return 0; fi
  identity="$(managed_pid_read "${PID_FILE}" mihomo_process_matches)" || { print_err "mihomo PID 身份或进程出生时间不匹配；拒绝误杀并保留 PID 文件。"; return 1; }
  read -r pid birth <<<"${identity}"
  managed_pid_stop "${pid}" "${birth}" || { print_err "无法确认 mihomo 进程已停止；保留 PID 文件。"; return 1; }
  rm -f -- "${PID_FILE}"
}

kill_pid_file() {
  local pid_file="$1" expect="$2" pid n
  pid="$(read_pid_file "$pid_file" 2>/dev/null || true)"
  [ -n "$pid" ] || { rm -f -- "$pid_file"; return 0; }
  if [ -n "$expect" ] && ! pid_matches_binary "$pid" "$expect"; then
    if kill -0 "$pid" 2>/dev/null && ! pid_is_zombie "$pid"; then print_warn "PID $pid 不属于预期程序 $expect；拒绝误杀。"; return 1; fi
    rm -f -- "$pid_file"; return 0
  fi
  kill -TERM "$pid" >/dev/null 2>&1 || { kill -0 "$pid" 2>/dev/null && return 1; }
  for n in 1 2 3 4 5; do
    if ! kill -0 "$pid" 2>/dev/null || pid_is_zombie "$pid"; then rm -f -- "$pid_file"; return 0; fi
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null && ! pid_is_zombie "$pid"; then
    kill -KILL "$pid" >/dev/null 2>&1 || return 1
    for n in 1 2 3 4 5; do
      if ! kill -0 "$pid" 2>/dev/null || pid_is_zombie "$pid"; then rm -f -- "$pid_file"; return 0; fi
      sleep 1
    done
    print_err "PID $pid 收到 KILL 后仍存活，保留 PID 文件。"; return 1
  fi
  rm -f -- "$pid_file"
}

compute_go_mem_limit_mb() {
  local pct="${MM_GOMEM_LIMIT_PCT:-45}"
  local floor_mb="${MM_GOMEM_FLOOR_MB:-32}"
  local total_kb limit_mb v

  total_kb="$(awk '/^(MemTotal|MemTotal:)/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)"
  [ -n "${total_kb}" ] || total_kb=0

  local f
  for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.high; do
    [ -r "${f}" ] || continue
    v="$(tr -d ' \r\n' <"${f}" 2>/dev/null || true)"
    [ -n "${v}" ] || continue
    [ "${v}" = "max" ] && continue
    [[ "${v}" =~ ^[0-9]+$ ]] || continue
    [ "${v}" -le 0 ] && continue
    if [ "${total_kb}" -le 0 ] || [ "$((v / 1024))" -lt "${total_kb}" ]; then
      total_kb=$((v / 1024))
    fi
  done

  if [ "${total_kb}" -le 0 ]; then
    return 1
  fi

  limit_mb=$((total_kb * 1024 * pct / 100 / 1024 / 1024))
  if [ "${limit_mb}" -lt "${floor_mb}" ]; then
    limit_mb="${floor_mb}"
  fi
  printf '%s' "${limit_mb}"
}

go_mem_limit_value() {
  local mb
  mb="$(compute_go_mem_limit_mb 2>/dev/null || true)"
  [ -n "${mb}" ] || return 0
  printf '%sMiB' "${mb}"
}

systemd_available() {
  command_exists systemctl && [ -d /run/systemd/system ]
}

openrc_available() {
  command_exists rc-service && [ -x /sbin/openrc-run ]
}

systemd_timer_active() {
  local line
  line="$(systemctl list-timers --all --no-legend "${WATCHDOG_TIMER_NAME}" 2>/dev/null | head -n 1 || true)"
  [ -n "${line}" ] || return 1
  [[ "${line}" == n/a* ]] && return 1
  return 0
}

create_systemd_units() {
  local mem_line="" mem_limit gogc_line memory_high_line memory_max_line nofile_line
  local mem_high mem_max safe data
  service_data_permissions || return 1
  safe="$(mihomo_safe_paths)" || return 1
  data="$(mihomo_data_dir)" || return 1
  mem_limit="$(go_mem_limit_value)" || return 1
  [ -z "${mem_limit}" ] || mem_line="Environment=GOMEMLIMIT=${mem_limit}"
  gogc_line=""
  if go_gc_requested; then gogc_line="Environment=GOGC=off"; fi
  mem_high="$(manager_env_or_setting "mem_high_mb")" || return 1
  mem_max="$(manager_env_or_setting "mem_max_mb")" || return 1
  memory_high_line=""; memory_max_line=""
  if [ -n "${mem_high}" ] && [[ "${mem_high}" =~ ^[0-9]+$ ]] && [ "${mem_high}" -gt 0 ]; then memory_high_line="MemoryHigh=${mem_high}M"; fi
  if [ -n "${mem_max}" ] && [[ "${mem_max}" =~ ^[0-9]+$ ]] && [ "${mem_max}" -gt 0 ]; then memory_max_line="MemoryMax=${mem_max}M"; fi
  nofile_line="LimitNOFILE=1048576"
  cat >"${SYSTEMD_SERVICE_FILE}" <<EOF || return 1
[Unit]
Description=Mihomo Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${MIHOMO_SERVICE_USER}
Group=${MIHOMO_SERVICE_GROUP}
WorkingDirectory=${data}
Environment=SAFE_PATHS=${safe}
ExecStartPre=+${MM_CLI} fw protect
ExecStartPre=${MIHOMO_BIN} -d ${data} -t -f ${CONFIG_FILE}
${mem_line}
${gogc_line}
${memory_high_line}
${memory_max_line}
${nofile_line}
ExecStart=${MIHOMO_BIN} -d ${data} -f ${CONFIG_FILE}
Restart=on-failure
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectProc=invisible
ProcSubset=pid
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
SystemCallFilter=@system-service
SystemCallFilter=~@chown
SystemCallFilter=~@privileged
SystemCallErrorNumber=EPERM
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
OOMPolicy=kill
OOMScoreAdjust=-100
RestartSteps=10
RestartSec=3
MemorySwapMax=0
ReadOnlyPaths=${BASE_DIR} ${CERT_DIR}
ReadWritePaths=${data}

[Install]
WantedBy=multi-user.target
EOF
  [ -s "${SYSTEMD_SERVICE_FILE}" ] || return 1
  chmod 0644 "${SYSTEMD_SERVICE_FILE}" || return 1
  cat >"${SYSTEMD_WATCHDOG_SERVICE_FILE}" <<EOF || return 1
[Unit]
Description=Mihomo Manager Watchdog
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${WATCHDOG_TARGET}
KillMode=process
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectProc=invisible
ProcSubset=pid
ReadWritePaths=${BASE_DIR} ${LOCK_ROOT}
EOF
  [ -s "${SYSTEMD_WATCHDOG_SERVICE_FILE}" ] || return 1
  chmod 0644 "${SYSTEMD_WATCHDOG_SERVICE_FILE}" || return 1
  cat >"${SYSTEMD_WATCHDOG_TIMER_FILE}" <<EOF || return 1
[Unit]
Description=Run Mihomo Manager Watchdog Every Minute

[Timer]
OnBootSec=30
OnUnitActiveSec=60
Unit=${WATCHDOG_SERVICE_NAME}.service

[Install]
WantedBy=timers.target
EOF
  [ -s "${SYSTEMD_WATCHDOG_TIMER_FILE}" ] || return 1
  chmod 0644 "${SYSTEMD_WATCHDOG_TIMER_FILE}" || return 1
  systemctl daemon-reload || return 1
  systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || return 1
  if [ "${MM_DEFER_WATCHDOG_ENABLE:-0}" != 1 ]; then ensure_watchdog_enabled || return 1; fi
}

create_openrc_units() {
  local mem_line="" gogc_line="" mem_limit safe data
  service_data_permissions || return 1
  safe="$(mihomo_safe_paths)" || return 1
  data="$(mihomo_data_dir)" || return 1
  mem_limit="$(go_mem_limit_value)" || return 1
  [ -z "${mem_limit}" ] || mem_line="export GOMEMLIMIT=${mem_limit}"
  if go_gc_requested; then gogc_line="export GOGC=off"; fi
  cat >"${OPENRC_SERVICE_FILE}" <<EOF || return 1
#!/sbin/openrc-run
name="${SERVICE_NAME}"
description="Mihomo Manager"
command="${MIHOMO_BIN}"
command_args="-d ${data} -f ${CONFIG_FILE}"
command_background=true
command_user="${MIHOMO_SERVICE_USER}:${MIHOMO_SERVICE_GROUP}"
pidfile="${PID_FILE}"
export SAFE_PATHS="${safe}"

 depend() {
  need net
}

start_pre() {
  install -d -o ${MIHOMO_SERVICE_USER} -g ${MIHOMO_SERVICE_GROUP} -m 0700 ${data} || return 1
  ${MM_CLI} fw protect || return 1
  ${MIHOMO_BIN} -d ${data} -t -f ${CONFIG_FILE} >/dev/null || return 1
  ${mem_line}
  ${gogc_line}
}
EOF
  [ -s "${OPENRC_SERVICE_FILE}" ] || return 1
  chmod 0755 "${OPENRC_SERVICE_FILE}" || return 1
  rc-update add "${SERVICE_NAME}" default >/dev/null 2>&1 || return 1
  if [ "${MM_DEFER_WATCHDOG_ENABLE:-0}" != 1 ]; then ensure_watchdog_enabled || return 1; fi
}

ensure_watchdog_enabled() {
  if systemd_available; then
    systemctl enable --now "${WATCHDOG_TIMER_NAME}" >/dev/null 2>&1 || return 1
    return 0
  fi
  if openrc_available && command_exists rc-service && [ -x /etc/init.d/crond ]; then
    rc-update add crond default >/dev/null 2>&1 || return 1
    rc-service crond start >/dev/null 2>&1 || return 1
  fi
  create_cron_watchdog
}

create_cron_watchdog() {
  if ! command_exists crontab; then
    print_warn "未找到 crontab，已跳过 watchdog 的 cron 创建。"
    return 0
  fi

  (
    crontab -l 2>/dev/null | grep -Fv "${WATCHDOG_TARGET}" | grep -Fv "no crontab for" || true
    echo "* * * * * ${WATCHDOG_TARGET} >/dev/null 2>&1"
  ) | crontab -
}

service_state() {
  if systemd_available; then
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
      printf '运行中'
    else
      printf '已停止'
    fi
    return 0
  fi

  if openrc_available; then
    if rc-service "${SERVICE_NAME}" status >/dev/null 2>&1; then
      printf '运行中'
    else
      printf '已停止'
    fi
    return 0
  fi

  local pid
  pid="$(read_mihomo_pid_file 2>/dev/null || true)"
  # 存活且确为 mihomo 实例才显示运行中，防止 PID 复用导致误报
  if [ -n "${pid}" ] && pid_matches_binary_or_alive "${pid}" "${MIHOMO_BIN}"; then
    printf '运行中'
  else
    printf '已停止'
  fi
}

socks5_whitelist_guard() {
  local port="$1" enabled tags tag proto node_port found=0
  [[ "$port" =~ ^[1-9][0-9]*$ ]] && [ "$port" -le 65535 ] || return 1
  enabled="$(manager_env_or_setting "socks5_wl_flag" "")" || return 1
  case "${enabled,,}" in true|1|yes|on) ;; *) return 0 ;; esac
  tags="$(iter_node_tags)" || return 1
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    proto="$(node_value "$tag" protocol)" || return 1
    [ "$proto" = socks5 ] || continue
    node_port="$(node_value "$tag" port)" || return 1
    [[ "$node_port" =~ ^[1-9][0-9]*$ ]] && [ "$node_port" -le 65535 ] || return 1
    [ "$node_port" = "$port" ] && found=1
  done <<< "$tags"
  [ "$found" = 1 ] && return 2
  return 0
}

socks5_whitelist_remove_chain() {
  local ipt="$1" chain="$2" listing nums n rc=0
  listing="$("$ipt" -L INPUT --line-numbers -n 2>/dev/null)" || return 1
  nums="$(printf '%s\n' "$listing" | awk -v c="$chain" '$2 == c {print $1}' | sort -rn)" || return 1
  for n in $nums; do "$ipt" -D INPUT "$n" >/dev/null 2>&1 || rc=1; done
  [ "$rc" = 0 ] || return 1
  if "$ipt" -L "$chain" -n >/dev/null 2>&1; then
    "$ipt" -F "$chain" >/dev/null 2>&1 || return 1
    "$ipt" -X "$chain" >/dev/null 2>&1 || return 1
  fi
}

socks5_whitelist_cleanup() {
  local ipt chain rc=0
  for ipt in iptables ip6tables; do
    command_exists "$ipt" || continue
    for chain in MM_SOCKS5_WL_A MM_SOCKS5_WL_B MM_SOCKS5_WL; do
      socks5_whitelist_remove_chain "$ipt" "$chain" || rc=1
    done
  done
  return "$rc"
}

socks5_whitelist_apply() {
  local enabled ips token ip ipt chain old_chain tags tag proto port rules active_a active_b rc=0 item
  local -a v4=() v6=() ports=() staged=()
  enabled="$(manager_env_or_setting "socks5_wl_flag" "")" || return 1
  case "${enabled,,}" in true|1|yes|on) ;; *) socks5_whitelist_cleanup; return $? ;; esac
  ips="$(manager_env_or_setting "socks5_ips" "")" || return 1
  ips="${ips//,/ }"
  [ -n "${ips//[[:space:]]/}" ] || { print_err "白名单已启用但地址列表为空，拒绝启动。"; return 1; }
  for token in $ips; do
    [[ "$token" =~ ^[0-9A-Fa-f.:/]+$ ]] || { print_err "白名单地址格式无效：$token"; return 1; }
    if [[ "$token" == *:* ]]; then v6+=("$token"); else v4+=("$token"); fi
  done
  command_exists iptables || { print_err "白名单已启用但缺少 iptables，拒绝启动。"; return 1; }
  command_exists ip6tables || { print_err "白名单已启用但缺少 ip6tables，拒绝启动。"; return 1; }
  tags="$(iter_node_tags)" || return 1
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    proto="$(node_value "$tag" protocol)" || return 1
    [ "$proto" = socks5 ] || continue
    port="$(node_value "$tag" port)" || return 1
    [[ "$port" =~ ^[1-9][0-9]*$ ]] && [ "$port" -le 65535 ] || { print_err "SOCKS5 节点端口无效：$tag"; return 1; }
    ports+=("$port")
  done <<< "$tags"
  [ "${#ports[@]}" -gt 0 ] || { print_err "白名单已启用但没有 SOCKS5 节点。"; return 1; }
  for ipt in iptables ip6tables; do
    rules="$("$ipt" -S INPUT 2>/dev/null)" || { print_err "$ipt 无法检查 INPUT 链，拒绝启动。"; return 1; }
    active_a=0; active_b=0
    grep -Eq '^-A INPUT .* -j MM_SOCKS5_WL_A([[:space:]]|$)' <<< "$rules" && active_a=1 || true
    grep -Eq '^-A INPUT .* -j MM_SOCKS5_WL_B([[:space:]]|$)' <<< "$rules" && active_b=1 || true
    [ "$active_a" = 0 ] || [ "$active_b" = 0 ] || { print_err "$ipt 检测到多个活动白名单链，拒绝不安全重建。"; return 1; }
    if [ "$active_a" = 1 ]; then old_chain=MM_SOCKS5_WL_A; chain=MM_SOCKS5_WL_B; elif [ "$active_b" = 1 ]; then old_chain=MM_SOCKS5_WL_B; chain=MM_SOCKS5_WL_A; else old_chain=""; chain=MM_SOCKS5_WL_A; fi
    "$ipt" -N "$chain" >/dev/null 2>&1 || "$ipt" -F "$chain" >/dev/null 2>&1 || return 1
    "$ipt" -F "$chain" >/dev/null 2>&1 || return 1
    if [ "$ipt" = iptables ]; then
      for ip in "${v4[@]}"; do "$ipt" -A "$chain" -s "$ip" -j ACCEPT >/dev/null 2>&1 || { "$ipt" -F "$chain" >/dev/null 2>&1 || true; return 1; }; done
    else
      for ip in "${v6[@]}"; do "$ipt" -A "$chain" -s "$ip" -j ACCEPT >/dev/null 2>&1 || { "$ipt" -F "$chain" >/dev/null 2>&1 || true; return 1; }; done
    fi
    "$ipt" -A "$chain" -j DROP >/dev/null 2>&1 || { "$ipt" -F "$chain" >/dev/null 2>&1 || true; return 1; }
    staged+=("$ipt:$chain:$old_chain")
  done
  for item in "${staged[@]}"; do
    IFS=: read -r ipt chain old_chain <<< "$item"
    for port in "${ports[@]}"; do
      for proto in tcp udp; do
        "$ipt" -I INPUT 1 -p "$proto" --dport "$port" -m comment --comment mm_socks5_wl -j "$chain" >/dev/null 2>&1 || rc=1
      done
    done
    [ "$rc" = 0 ] || break
  done
  if [ "$rc" != 0 ]; then
    for item in "${staged[@]}"; do IFS=: read -r ipt chain old_chain <<< "$item"; socks5_whitelist_remove_chain "$ipt" "$chain" || true; done
    print_err "安装 SOCKS5 白名单规则失败，拒绝启动。"; return 1
  fi
  for item in "${staged[@]}"; do
    IFS=: read -r ipt chain old_chain <<< "$item"
    if [ -n "$old_chain" ]; then socks5_whitelist_remove_chain "$ipt" "$old_chain" || { print_err "新白名单已安装但旧规则无法清理；拒绝报告成功。"; return 1; }; fi
    socks5_whitelist_remove_chain "$ipt" MM_SOCKS5_WL || return 1
  done
  return 0
}

stop_service() {
  local log_file="${BASE_DIR}/logs/mihomo.log" reason_file="${BASE_DIR}/logs/stop_reason.log" rc=0
  if [ -s "$log_file" ]; then tail -n 50 "$log_file" >"$reason_file" 2>/dev/null || true; chmod 600 "$reason_file" 2>/dev/null || true; fi
  if systemd_available; then systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || rc=1
  elif openrc_available; then rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || rc=1; fi
  stop_mihomo_pid_file || rc=1
  if [ "$rc" = 0 ]; then socks5_whitelist_cleanup || rc=1; fi
  return "$rc"
}



ensure_low_memory_guard() {
  local total_kb avail_mb low_mb
  low_mb="${MM_LOW_MEM_MB:-200}"
  total_kb="$(awk '/^(MemTotal|MemTotal:)/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)"
  [ -n "${total_kb}" ] || return 0
  avail_mb=$((total_kb / 1024))
  if [ "${avail_mb}" -lt "${low_mb}" ]; then
    print_warn "检测到低内存环境（约 ${avail_mb}MB < ${low_mb}MB）：已为 mihomo/cloudflared 设置 GOMEMLIMIT 软上限并强制 cloudflared http2 模式。"
    print_warn "建议少开协议节点、避免同时开启多个 Argo 节点；隧道进程内存尖峰靠 Go 软上限抑制。"
  fi
}

# P1：返回正在运行的 mihomo 实例 PID（systemd 取 MainPID，其余读 PID_FILE），
# 未运行或 PID 非法时返回 1。不做二进制身份校验，交由调用方决定是否可信。
running_singbox_pid() {
  local pid
  if systemd_available; then
    pid="$(systemctl show -p MainPID --value "${SERVICE_NAME}" 2>/dev/null || true)"
    [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s' "${pid}"
    return 0
  fi
  pid="$(read_mihomo_pid_file 2>/dev/null || true)"
  [ -n "${pid}" ] || return 1
  printf '%s' "${pid}"
  return 0
}

# P1：配置重载。mihomo 官方 CLI 无热重载命令（运行中仅支持 API 级改配置），
# 因此统一为"校验通过 → stop + start（systemd 即 restart，秒级）"：
#   - 配置校验失败 → fail-closed，拒绝重载并返回 1（保留运行中的旧配置）；
#   - 服务未运行 → 直接完整启动。
#   就绪自检（P3）在非测试环境于重启后执行，端口未监听时给出明确报错。
reload_service() {
  mihomo_validate "$CONFIG_FILE" || { print_err "配置校验失败，拒绝重载。"; return 1; }
  stop_service || { print_err "停止旧服务失败，拒绝启动新配置。"; return 1; }
  start_service || { print_err "新服务启动失败。"; return 1; }
  if [ "${MM_TEST_MODE:-0}" != 1 ]; then verify_data_plane_ready || { stop_service || true; return 1; }; fi
  return 0
}



# 就绪重试次数的默认值：普通主机 10 次（每次探活 1s、间隔 1s），低内存主机
# （MemTotal < 256MB）30 次。128MB 的 NAT 小机在负载高时冷启动 mihomo 常超过 10s，
# 固定 10 次会误判“数据面就绪失败”并回滚（BR-Oracle-nat 实测连续两次）。
mm_default_readiness_retries() {
  local mem_kb=0 meminfo="${MM_MEMINFO_FILE:-/proc/meminfo}"
  if [ -r "${meminfo}" ]; then
    mem_kb="$(awk '/^MemTotal:/{print $2; exit}' "${meminfo}" 2>/dev/null || printf 0)"
  fi
  if [[ "${mem_kb}" =~ ^[0-9]+$ ]] && [ "${mem_kb}" -gt 0 ] && [ "${mem_kb}" -lt 262144 ]; then
    printf '30'
    return 0
  fi
  printf '10'
}

# P3：等待一组 TCP 端口可探活（就绪自检核心，MM_READINESS_RETRIES 次重试，
# 每次探活 1s 超时、间隔 1s）。UDP 节点不在此列（见 verify_data_plane_ready）。
await_tcp_ports() {
  local host="$1" port_list="$2" tries="${3:-${MM_READINESS_RETRIES:-$(mm_default_readiness_retries)}}"
  local attempt port all_ok
  [ -n "${port_list}" ] || return 0
  [[ "${tries}" =~ ^[1-9][0-9]*$ ]] || tries="$(mm_default_readiness_retries)"
  for ((attempt = 1; attempt <= tries; attempt++)); do
    all_ok=1
    for port in ${port_list}; do
      [[ "${port}" =~ ^[0-9]+$ ]] || continue
      if ! probe_tcp_port "${host}" "${port}" 1; then
        all_ok=0
        break
      fi
    done
    [ "${all_ok}" = 1 ] && return 0
    sleep 1
  done
  return 1
}

# P3：数据面就绪自检——render/start/reload 后逐个探活 TCP 类入站端口，
# 未监听时明确报出端口（端口冲突/绑定失败定位）；纯 UDP（hy2/tuic）节点
# 与全 UDP 部署跳过（TCP 探活不适用，进程存活由 watchdog 保证）。
verify_data_plane_ready() {
  local rows tag protocol port tcp_ports="" udp_ports="" tcp_count udp_count attempt all_ok p rc=0
  [ -f "$NODES_FILE" ] || return 0
  rows="$(node_meta_bulk)" || { print_err "无法读取节点元数据进行就绪检查。"; return 1; }
  while IFS=$'\t' read -r tag protocol port _argo; do
    [ -n "$tag" ] || continue
    [[ "$port" =~ ^[1-9][0-9]*$ ]] && [ "$port" -le 65535 ] || { print_err "节点 $tag 端口无效。"; return 1; }
    tcp_probeable_protocol "$protocol" && tcp_ports="$tcp_ports $port"
    udp_probeable_protocol "$protocol" && udp_ports="$udp_ports $port"
  done <<< "$rows"
  tcp_count="$(tcp_probeable_node_count)" || return 1
  udp_count="$(udp_node_count)" || return 1
  if [ "$tcp_count" -gt 0 ]; then await_tcp_ports 127.0.0.1 "${tcp_ports# }" "${MM_READINESS_RETRIES:-$(mm_default_readiness_retries)}" || rc=1; fi
  if [ "$udp_count" -gt 0 ]; then
    command_exists ss || command_exists netstat || { print_err "UDP 就绪检查需要 ss 或 netstat。"; return 1; }
    local retries="${MM_READINESS_RETRIES:-$(mm_default_readiness_retries)}"
    [[ "$retries" =~ ^[1-9][0-9]*$ ]] || { print_err "MM_READINESS_RETRIES 必须为正整数。"; return 1; }
    for ((attempt=1; attempt<=retries;attempt++)); do
      all_ok=1
      for p in ${udp_ports# }; do udp_port_binding_alive "$p" || { all_ok=0; break; }; done
      [ "$all_ok" = 1 ] && break
      sleep 1
    done
    [ "$all_ok" = 1 ] || rc=1
  fi
  [ "$rc" = 0 ] || { print_err "数据面就绪失败：TCP(${tcp_ports# }) UDP(${udp_ports# }) 监听未确认。"; return 1; }
  print_ok "数据面就绪：TCP $tcp_count 个，UDP $udp_count 个。"
}



start_service() {
  [ -x "$MIHOMO_BIN" ] || { print_err "尚未安装 mihomo。"; return 1; }
  service_data_permissions || return 1
  socks5_whitelist_apply || { print_err "SOCKS5 白名单安装失败，拒绝启动。"; return 1; }
  mihomo_validate "$CONFIG_FILE" || return 1
  warn_if_bindv6only || return 1
  local mem_limit data safe pid gid launch_birth
  mem_limit="$(go_mem_limit_value)" || return 1
  data="$(mihomo_data_dir)" || return 1
  safe="$(mihomo_safe_paths)" || return 1
  if systemd_available; then
    create_systemd_units || return 1
    systemctl daemon-reload || return 1
    systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || return 1
  elif openrc_available; then
    create_openrc_units || return 1
    rc-service "$SERVICE_NAME" restart >/dev/null 2>&1 || rc-service "$SERVICE_NAME" start >/dev/null 2>&1 || return 1
  else
    stop_service || return 1
    socks5_whitelist_apply || return 1
    local -a env_prefix=()
    [ -z "$mem_limit" ] || env_prefix+=("GOMEMLIMIT=$mem_limit")
    if go_gc_requested; then env_prefix+=(GOGC=off); fi
    if [ "${MM_TEST_MODE:-0}" = 1 ]; then
      ( if [[ "${LOCK_FD:-}" =~ ^[0-9]+$ ]]; then exec {LOCK_FD}>&-; fi; trap '' HUP; exec nohup env "${env_prefix[@]}" SAFE_PATHS="$safe" "$MIHOMO_BIN" -d "$data" -f "$CONFIG_FILE" ) >>"$BASE_DIR/logs/mihomo.log" 2>&1 &
    else
      service_ensure_identity || return 1
      local priv_kind uid
      priv_kind="$(service_priv_drop_kind)" || {
        print_err "独立启动需要可用的 setpriv（util-linux）、su-exec 或 su。"
        return 1
      }
      case "$priv_kind" in
        setpriv)
          uid="$(id -u "$MIHOMO_SERVICE_USER")" || return 1
          gid="$(id -g "$MIHOMO_SERVICE_USER")" || return 1
          [[ "$uid" =~ ^[0-9]+$ ]] && [[ "$gid" =~ ^[0-9]+$ ]] || return 1
          ( if [[ "${LOCK_FD:-}" =~ ^[0-9]+$ ]]; then exec {LOCK_FD}>&-; fi; trap '' HUP; exec nohup env "${env_prefix[@]}" SAFE_PATHS="$safe" setpriv --reuid="$uid" --regid="$gid" --clear-groups --inh-caps=+net_bind_service,+net_raw --ambient-caps=+net_bind_service,+net_raw --bounding-set=+net_bind_service,+net_raw -- "$MIHOMO_BIN" -d "$data" -f "$CONFIG_FILE" ) >>"$BASE_DIR/logs/mihomo.log" 2>&1 &
          ;;
        su-exec)
          ( if [[ "${LOCK_FD:-}" =~ ^[0-9]+$ ]]; then exec {LOCK_FD}>&-; fi; trap '' HUP; exec nohup env "${env_prefix[@]}" SAFE_PATHS="$safe" su-exec "$MIHOMO_SERVICE_USER:$MIHOMO_SERVICE_GROUP" "$MIHOMO_BIN" -d "$data" -f "$CONFIG_FILE" ) >>"$BASE_DIR/logs/mihomo.log" 2>&1 &
          ;;
        su)
          ( if [[ "${LOCK_FD:-}" =~ ^[0-9]+$ ]]; then exec {LOCK_FD}>&-; fi; trap '' HUP; exec nohup env "${env_prefix[@]}" SAFE_PATHS="$safe" su -s /bin/sh -c "$(service_shell_quote env "SAFE_PATHS=$safe" "$MIHOMO_BIN" -d "$data" -f "$CONFIG_FILE")" "$MIHOMO_SERVICE_USER" ) >>"$BASE_DIR/logs/mihomo.log" 2>&1 &
          ;;
      esac
    fi
    pid=$!
    launch_birth="$(managed_proc_birth "${pid}" 2>/dev/null)" || { print_err "无法确认候选 mihomo 进程身份。"; return 1; }
    if ! write_mihomo_pid_file "${pid}"; then
      stop_mihomo_candidate "${pid}" "${launch_birth}" || print_err "无法确认候选 mihomo 已停止。"
      return 1
    fi
  fi
  if [ "${MM_TEST_MODE:-0}" != 1 ]; then verify_data_plane_ready || { stop_service || true; return 1; }; fi
  if [ "${MM_DEFER_WATCHDOG_ENABLE:-0}" != 1 ] && ! ensure_watchdog_enabled; then
    stop_service || true
    print_err "无法启用 watchdog，已回滚候选 mihomo。"
    return 1
  fi
  print_ok "服务状态：$(service_state)"
}



ensure_singbox_ready() {
  init_storage || return 1
  if [ ! -x "${MIHOMO_BIN}" ]; then
    print_info "检测到 mihomo 尚未安装，开始自动安装。"
    install_core || return 1
  fi
  # F-05：systemd unit 缺失时补建（历史上 install 若中途失败/被清理会留下无 unit 状态，
  # rep/restart/update 等后续流程单独 start 即失败；这里幂等重建，存在则覆盖为同内容）。
  if systemd_available && [ ! -f "${SYSTEMD_SERVICE_FILE}" ]; then
    print_info "systemd unit 缺失，重建服务单元。"
    create_systemd_units || return 1
  fi
  # F-06：OpenRC init 脚本缺失时同样补建。与 F-05 对称：当 mihomo/cloudflared
  # 已预置（如二进制旁路安装/install_core 未走）时，ensure_singbox_ready 不会触发
  # install_core，而 create_openrc_units 只在 install_core 里调用——缺失的
  # /etc/init.d/${SERVICE_NAME} 会让 start_service 的 rc-service restart 报
  # "service does not exist" 令 rep/ins 整体回滚（Alpine/OpenRC 实测阻断）。
  if openrc_available && [ ! -f "${OPENRC_SERVICE_FILE}" ]; then
    print_info "OpenRC init 脚本缺失，重建服务单元。"
    create_openrc_units || return 1
    create_cron_watchdog || return 1
  fi
}
