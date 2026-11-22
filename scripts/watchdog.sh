#!/usr/bin/env bash
# SOURCE_ROOT 由 mm_load_all 的 mm_module_path 消费。
# shellcheck disable=SC2034
set -eEuo pipefail
umask 077

BASE_DIR="${BASE_DIR:-/usr/local/etc/mihomo-manager}"
LIB_DIR="${LIB_DIR:-/usr/local/lib/mihomo-manager}"
MIHOMO_BIN="${MIHOMO_BIN:-/usr/local/bin/mihomo}"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-/usr/local/bin/cloudflared}"
INSTALL_BIN="${INSTALL_BIN:-/usr/local/bin/mm}"
WATCHDOG_TARGET="${WATCHDOG_TARGET:-${BASE_DIR}/watchdog.sh}"
UPSTREAM_ENV="${UPSTREAM_ENV:-${LIB_DIR}/upstream.env}"
SERVICE_NAME="${SERVICE_NAME:-mihomo-manager}"
WATCHDOG_SERVICE_NAME="${WATCHDOG_SERVICE_NAME:-mihomo-manager-watchdog}"
WATCHDOG_TIMER_NAME="${WATCHDOG_TIMER_NAME:-mihomo-manager-watchdog.timer}"
SYSTEMD_SERVICE_FILE="${SYSTEMD_SERVICE_FILE:-/etc/systemd/system/${SERVICE_NAME}.service}"
SYSTEMD_WATCHDOG_SERVICE_FILE="${SYSTEMD_WATCHDOG_SERVICE_FILE:-/etc/systemd/system/${WATCHDOG_SERVICE_NAME}.service}"
SYSTEMD_WATCHDOG_TIMER_FILE="${SYSTEMD_WATCHDOG_TIMER_FILE:-/etc/systemd/system/${WATCHDOG_TIMER_NAME}}"
OPENRC_SERVICE_FILE="${OPENRC_SERVICE_FILE:-/etc/init.d/${SERVICE_NAME}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT=""
if [ -f "${SCRIPT_DIR}/../lib/env.sh" ]; then
  SOURCE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
  # shellcheck source=../lib/env.sh
  . "${SCRIPT_DIR}/../lib/env.sh"
elif [ -f "${LIB_DIR}/env.sh" ]; then
  # shellcheck source=/usr/local/lib/mihomo-manager/env.sh
  . "${LIB_DIR}/env.sh"
else
  echo "未找到 env.sh。" >&2
  exit 1
fi

if [ -n "${SOURCE_ROOT}" ] && [ -f "${SOURCE_ROOT}/metadata/upstream.env" ]; then
  # shellcheck source=../metadata/upstream.env
  . "${SOURCE_ROOT}/metadata/upstream.env"
elif [ -f "${UPSTREAM_ENV}" ]; then
  # shellcheck source=/usr/local/lib/mihomo-manager/upstream.env
  . "${UPSTREAM_ENV}"
else
  echo "未找到 upstream.env。" >&2
  exit 1
fi

if ! mm_load_all; then
  exit 1
fi
PID_FILE="${PID_FILE:-${RUNTIME_DIR}/mihomo.pid}"
require_bash4

start_non_systemd_singbox() {
  [ -x "${MIHOMO_BIN}" ] && [ -f "${CONFIG_FILE}" ] || return 1
  service_data_permissions || return 1
  mihomo_validate "${CONFIG_FILE}" || { print_err "配置校验失败，拒绝启动 mihomo。"; return 1; }
  stop_mihomo_pid_file || return 1
  socks5_whitelist_apply || return 1
  local data safe pid launch_birth
  data="$(mihomo_data_dir)" || return 1
  safe="$(mihomo_safe_paths)" || return 1
  rotate_log_file "${LOG_DIR}/mihomo.log" || return 1
  (
    if [[ "${LOCK_FD:-}" =~ ^[0-9]+$ ]]; then exec {LOCK_FD}>&-; fi
    trap '' HUP
    mihomo_exec_as_user "${safe}" "${MIHOMO_BIN}" -d "${data}" -f "${CONFIG_FILE}"
  ) </dev/null >>"${LOG_DIR}/mihomo.log" 2>&1 &
  pid=$!
  launch_birth="$(managed_proc_birth "${pid}" 2>/dev/null)" || { print_err "无法确认 watchdog 候选 mihomo 进程身份。"; return 1; }
  if ! write_mihomo_pid_file "${pid}"; then
    stop_mihomo_candidate "${pid}" "${launch_birth}" || print_err "无法确认 watchdog 候选 mihomo 已停止。"
    return 1
  fi
}

ensure_log_rotation() {
  local logs lf
  rotate_log_file "${LOG_DIR}/mihomo.log" || return 1
  logs="$(find "${LOG_DIR}" -type f -name '*.cloudflared.log' -print 2>/dev/null)" || return 1
  while IFS= read -r lf; do
    [ -n "${lf}" ] || continue
    rotate_log_file "${lf}" || return 1
  done <<< "${logs}"
  # cache.db belongs to the live Mihomo data directory; never unlink it here.
}

singbox_healthy() {
  local pid status=0
  if systemd_available; then
    pid="$(systemctl show -p MainPID --value "${SERVICE_NAME}" 2>/dev/null || true)"
    [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 1
  elif openrc_available; then
    rc-service "${SERVICE_NAME}" status >/dev/null 2>&1 || return 1
  else
    pid="$(read_mihomo_pid_file 2>/dev/null || true)"
    [ -n "${pid}" ] && mihomo_process_matches "${pid}" || return 1
  fi
  verify_data_plane_ready
}

restart_singbox() {
  if systemd_available; then
    systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || return 1
  elif openrc_available; then
    rc-service "${SERVICE_NAME}" restart >/dev/null 2>&1 || rc-service "${SERVICE_NAME}" start >/dev/null 2>&1 || return 1
  else
    start_non_systemd_singbox || return 1
  fi
  if ! verify_data_plane_ready; then
    stop_service || true
    print_err "mihomo 重启后数据面未就绪，已停止候选进程。"
    return 1
  fi
}

probe_fail_escalate() {
  local fail_file="${RUNTIME_DIR}/probe_fail_count" fails=0 limit="${MM_PROBE_FAIL_LIMIT:-3}"
  [[ "${limit}" =~ ^[1-9][0-9]*$ ]] || { print_err "MM_PROBE_FAIL_LIMIT 必须为正整数。"; return 1; }
  if [ -f "${fail_file}" ] && [ ! -L "${fail_file}" ]; then
    fails="$(tr -dc '0-9' <"${fail_file}" 2>/dev/null || true)"
    fails="${fails:-0}"
  fi
  [[ "${fails}" =~ ^[0-9]+$ ]] || fails=0
  fails=$((fails + 1))
  printf '%s\n' "${fails}" >"${fail_file}" || return 1
  chmod 0600 "${fail_file}" || return 1
  if [ "${fails}" -lt "${limit}" ]; then
    print_warn "mihomo 数据面连续失败 ${fails}/${limit} 次，暂不重启。"
    return 0
  fi
  rm -f -- "${fail_file}" || return 1
  clash_api_dump_connections || true
  restart_singbox
}

ensure_singbox() {
  [ -x "${MIHOMO_BIN}" ] && [ -f "${CONFIG_FILE}" ] || return 0
  if singbox_healthy; then
    rm -f -- "${RUNTIME_DIR}/probe_fail_count"
    return 0
  fi
  probe_fail_escalate
}

ensure_argo_nodes() {
  local rows tag protocol port mode fail=0
  [ -f "${NODES_FILE}" ] || return 0
  rows="$(node_meta_bulk)" || { print_err "无法读取 Argo 节点元数据。"; return 1; }
  while IFS=$'\t' read -r tag protocol port mode; do
    [ -n "${tag}" ] || continue
    [ "${protocol}" = vless-argo ] || continue
    if [ "${mode}" = token ] && argo_node_running "${tag}"; then
      probe_token_tunnel "${tag}" || true
    fi
    if ! start_argo_node "${tag}"; then
      print_warn "Argo 隧道 ${tag} 检查或启动失败。"
      fail=1
    fi
  done <<< "${rows}"
  return "${fail}"
}

probe_token_tunnel() {
  local tag="$1" domain fail_file fails limit="${MM_TUNNEL_PROBE_LIMIT:-2}"
  domain="$(node_value "${tag}" endpoint_domain)" || return 1
  [ -n "${domain}" ] || return 0
  if probe_tcp_port "${domain}" 443 3; then
    rm -f -- "${RUNTIME_DIR}/${tag}.tunnel_probe_fail"
    return 0
  fi
  [[ "${limit}" =~ ^[1-9][0-9]*$ ]] || return 1
  fail_file="${RUNTIME_DIR}/${tag}.tunnel_probe_fail"
  fails="$(tr -dc '0-9' <"${fail_file}" 2>/dev/null || true)"
  fails="${fails:-0}"
  [[ "${fails}" =~ ^[0-9]+$ ]] || fails=0
  fails=$((fails + 1))
  printf '%s\n' "${fails}" >"${fail_file}" || return 1
  chmod 0600 "${fail_file}" || return 1
  if [ "${fails}" -ge "${limit}" ]; then
    rm -f -- "${fail_file}" || return 1
    stop_argo_node "${tag}" || return 1
    return 1
  fi
  return 0
}

write_metrics_line() {
  local ts probe=0 file="${RUNTIME_DIR}/metrics.jsonl" size
  ts="$(date +%s 2>/dev/null || printf 0)"
  singbox_probe_status || probe=$?
  [ ! -L "${file}" ] || return 1
  printf '{"ts":%s,"probe":%s}\n' "${ts}" "${probe}" >>"${file}" || return 1
  size="$(wc -c <"${file}" 2>/dev/null | tr -d '[:space:]')" || return 1
  if [ "${size:-0}" -gt 5242880 ]; then
    rotate_log_file "${file}" || return 1
  fi
}

watchdog_main() {
  require_root || return 1
  require_bash4 || return 1
  if ! try_acquire_lock; then
    print_warn "watchdog 无法获取全局锁，本轮不做任何状态写入。"
    return 1
  fi
  setup_common_traps
  init_storage || return 1
  sanitize_permissions || return 1
  ensure_log_rotation || return 1
  reconcile_state || return 1
  ensure_singbox || return 1
  ensure_argo_nodes || return 1
  ensure_sub || return 1
  write_metrics_line || return 1
  sanitize_permissions || return 1
  release_lock
}

if [ "${MM_TEST_MODE:-0}" != 1 ]; then
  watchdog_main "$@"
fi
