#!/usr/bin/env bash
set -eEuo pipefail

umask 077

# Linux /proc birth time rejects stale PID records, including zombies. The comm
# field may contain spaces and parentheses, so remove it before counting fields.
managed_proc_birth() {
  local pid="$1" stat
  local -a fields
  [[ "${pid}" =~ ^[1-9][0-9]{0,9}$ ]] && [ "${pid}" -gt 1 ] || return 1
  IFS= read -r stat 2>/dev/null <"/proc/${pid}/stat" || return 1
  read -r -a fields <<<"${stat##*) }"
  case "${fields[0]:-}" in '' | Z | X | x) return 1 ;; esac
  [[ "${fields[19]:-}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "${fields[19]}"
}

managed_proc_exe() {
  local pid="$1" binary="$2" actual canonical
  actual="$(readlink "/proc/${pid}/exe" 2>/dev/null)" || return 1
  actual="${actual% (deleted)}"
  canonical="$(readlink -f -- "${binary}" 2>/dev/null)" || canonical="${binary}"
  [ "${actual}" = "${canonical}" ] || [ "${actual}" = "${binary}" ]
}

managed_proc_binary_name() {
  local pid="$1" actual
  actual="$(readlink "/proc/${pid}/exe" 2>/dev/null)" || return 1
  actual="${actual% (deleted)}"
  printf '%s' "${actual##*/}"
}

# Dynamically scoped output array. Preserve each NUL-separated argument.
managed_proc_argv() {
  local pid="$1" arg
  proc_argv=()
  while IFS= read -r -d '' arg; do proc_argv+=("${arg}"); done 2>/dev/null <"/proc/${pid}/cmdline"
  [ "${#proc_argv[@]}" -gt 0 ]
}

managed_proc_log() {
  local pid="$1" log="$2" output canonical
  output="$(readlink "/proc/${pid}/fd/1" 2>/dev/null)" || return 1
  canonical="$(readlink -f -- "${log}" 2>/dev/null)" || canonical="${log}"
  [ "${output% (deleted)}" = "${canonical}" ] || [[ "${output% (deleted)}" == "${canonical}".[0-9]* ]]
}

# Current records include the birth time. A v1.2.7 numeric-only record is
# accepted only if its binary and role-specific argv also match.
managed_pid_read() {
  local file="$1" verify="$2" pid recorded extra birth
  shift 2
  [ -f "${file}" ] && [ ! -L "${file}" ] || return 1
  read -r pid recorded extra <"${file}" || return 1
  [ -z "${extra}" ] || return 1
  birth="$(managed_proc_birth "${pid}")" || return 1
  [ -z "${recorded}" ] || [ "${recorded}" = "${birth}" ] || return 1
  "${verify}" "${pid}" "$@" && [ "$(managed_proc_birth "${pid}")" = "${birth}" ] || return 1
  printf '%s %s\n' "${pid}" "${birth}"
}

managed_pid_stop() {
  local pid="$1" birth="$2" i
  [ "$(managed_proc_birth "${pid}")" = "${birth}" ] || return 0
  kill -TERM "${pid}" 2>/dev/null || [ "$(managed_proc_birth "${pid}")" != "${birth}" ] || return 1
  for ((i = 0; i < 20; i++)); do
    [ "$(managed_proc_birth "${pid}")" = "${birth}" ] || return 0
    sleep 0.1
  done
  kill -KILL "${pid}" 2>/dev/null || [ "$(managed_proc_birth "${pid}")" != "${birth}" ] || return 1
  for ((i = 0; i < 20; i++)); do
    [ "$(managed_proc_birth "${pid}")" = "${birth}" ] || return 0
    sleep 0.1
  done
  return 1
}

managed_pid_stop_file() {
  local file="$1" pid birth identity
  if identity="$(managed_pid_read "$@")"; then
    read -r pid birth <<<"${identity}"
    managed_pid_stop "${pid}" "${birth}" || return 1
  fi
  rm -f -- "${file}"
}

# Launch without inheriting the manager flock or the caller's stdout pipe.
# Record the child as PID + birth before waiting for exec/readiness.
managed_spawn() {
  local file="$1" log="$2" pid birth tmp
  shift 2
  tmp="$(mktemp "${file}.XXXXXX")" || return 1
  (
    local_lock_fd="${LOCK_FD:-}"
    if [[ "${local_lock_fd}" =~ ^[0-9]+$ ]]; then exec {local_lock_fd}>&-; fi
    trap '' HUP
    exec "$@"
  ) </dev/null >>"${log}" 2>&1 &
  pid=$!
  if ! birth="$(managed_proc_birth "${pid}")"; then
    rm -f -- "${tmp}"
    return 1
  fi
  if ! printf '%s %s\n' "${pid}" "${birth}" >"${tmp}" || ! mv -fT -- "${tmp}" "${file}"; then
    managed_pid_stop "${pid}" "${birth}" || true
    rm -f -- "${tmp}"
    return 1
  fi
}

managed_wait_exec() {
  local file="$1" i pid birth
  read -r pid birth <"${file}" || return 1
  for ((i = 0; i < 20; i++)); do
    [ "$(managed_proc_birth "${pid}")" = "${birth}" ] || return 1
    managed_pid_read "$@" >/dev/null && return 0
    sleep 0.1
  done
  managed_pid_stop "${pid}" "${birth}" || true
  return 1
}

argo_required() {
  [ "$(env_var "argo")" = "vlpt" ] && return 0
  [ -f "${NODES_FILE}" ] && grep -q '"protocol"[[:space:]]*:[[:space:]]*"vless-argo"' "${NODES_FILE}" 2>/dev/null
}

parse_trycloudflare_domain() {
  local log_file="$1"
  grep -aoE '[a-z0-9-]+\.trycloudflare\.com' "$log_file" 2>/dev/null | tail -n 1
}

wait_for_trycloudflare_domain() {
  local log_file="$1"
  local timeout="${2:-60}"
  local interval="${3:-2}"
  # 3.2:可传 cloudflared pid：进程假死/提前退出时立即失败，不等满 timeout（快速失败）
  local pid="${4:-}" birth="${5:-}"
  if [ -n "${pid}" ] && [ -z "${birth}" ]; then birth="$(managed_proc_birth "${pid}")" || return 1; fi
  local elapsed=0
  local domain=""

  while [ "${elapsed}" -lt "${timeout}" ]; do
    if [ -n "${pid}" ] && [ "$(managed_proc_birth "${pid}")" != "${birth}" ]; then
      print_warn "cloudflared 进程（pid ${pid}）已退出，停止等待临时域名。"
      return 1
    fi
    domain="$(parse_trycloudflare_domain "$log_file" || true)"
    if [ -n "$domain" ]; then
      [ -z "${pid}" ] || [ "$(managed_proc_birth "${pid}")" = "${birth}" ] || return 1
      printf '%s' "$domain"
      return 0
    fi
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  return 1
}

argo_domain_resolvable() {
  local domain="$1"
  [ -n "${domain}" ] || return 1

  # 快路径：本机解析成功即可确认（getent/host 退出码可靠）
  if command_exists getent; then
    if getent ahosts "${domain}" >/dev/null 2>&1; then
      return 0
    fi
  elif command_exists host; then
    if host "${domain}" >/dev/null 2>&1; then
      return 0
    fi
  fi

  # 本地解析不可用或未命中：查公共 DoH 记录（1.1.1.1 / dns.google 双源，绕开本机负缓存）。
  # A 与 AAAA 都查：TryCloudflare 域名可能只发布 IPv6（AAAA），仅看 A 会漏判；
  # 任一类型有记录即视为已发布。
  # 语义区分：
  #   DoH 应答"无记录"（确认未发布）           -> 返回失败，调用方重试
  #   DoH 网络不可达（无法核验，如墙内环境）   -> fail-open 放行并告警，
  #     因为 cloudflared 日志已出现域名即代表边缘注册成功，此时拒绝会让
  #     弱网机器的临时隧道永远写不进域名（v0.2.19 前的故障面）
  if command_exists curl && command_exists jq; then
    # A2：2 源 × A/AAAA 四路并发核验（原串行最坏 4×6s→并行 ≈6s），
    # 语义与原实现一致：任一有记录→已发布；有应答但不含记录→未发布；
    # 全部不可达→fail-open（隧道日志已出现域名即放行，弱网不回滚）。
    local probe_tmp _f raw cnt _i=0 _any_ok=0 _any_rec=0 _pid
    local base_url record_type
    local -a probe_pids=()
    probe_tmp="$(mktemp -d "${BASE_DIR}/.argodoh.XXXXXX" 2>/dev/null || true)"
    [ -n "${probe_tmp}" ] || probe_tmp="$(mktemp -d)" || return 1
    for base_url in "https://1.1.1.1/dns-query?name=${domain}." "https://dns.google/resolve?name=${domain}."; do
      for record_type in A AAAA; do
        (
          cnt="$(curl -q -fsS --max-time 6 -H 'accept: application/dns-json' "${base_url}&type=${record_type}" 2>/dev/null | jq -r '[.Answer[]? | select(.type == 1 or .type == 28)] | length' 2>/dev/null || true)"
          if [[ "${cnt}" =~ ^[0-9]+$ ]]; then
            printf 'R%s' "${cnt}"
          else
            printf 'E'
          fi
        ) >"${probe_tmp}/${_i}" &
        probe_pids+=("$!")
        _i=$((_i + 1))
      done
    done
    for _pid in "${probe_pids[@]}"; do
      wait "${_pid}" 2>/dev/null || true
    done
    for _f in "${probe_tmp}"/*; do
      [ -f "${_f}" ] || continue
      raw="$(tr -d '\r\n' <"${_f}" 2>/dev/null || true)"
      case "${raw}" in
      R*)
        _any_ok=1
        if [ "${raw#R}" -gt 0 ] 2>/dev/null; then
          _any_rec=1
        fi
        ;;
      esac
    done
    rm -rf "${probe_tmp}"
    if [ "${_any_rec}" = "1" ]; then
      return 0
    fi
    if [ "${_any_ok}" = "1" ]; then
      return 1
    fi
    print_warn "公共 DoH 均不可达，无法核验 ${domain} 的 DNS 发布，按隧道注册结果放行。"
    return 0
  fi

  return 1
}

wait_for_trycloudflare_domain_verified() {
  local log_file="$1"
  local timeout="${2:-60}"
  local retry="${3:-1}"
  local pid="${4:-}" birth="${5:-}"
  if [ -n "${pid}" ] && [ -z "${birth}" ]; then birth="$(managed_proc_birth "${pid}")" || return 1; fi
  local domain attempt

  for attempt in 0 1 2; do
    [ "${attempt}" -le "${retry}" ] || break
    domain="$(wait_for_trycloudflare_domain "${log_file}" "${timeout}" 2 "${pid}" "${birth}" || true)"
    [ -z "${pid}" ] || [ "$(managed_proc_birth "${pid}")" = "${birth}" ] || return 1
    [ -n "${domain}" ] || continue
    if [ "${MM_ARGO_SKIP_DNS_VERIFY:-0}" = "1" ] || argo_domain_resolvable "${domain}"; then
      [ -z "${pid}" ] || [ "$(managed_proc_birth "${pid}")" = "${birth}" ] || return 1
      printf '%s' "${domain}"
      return 0
    fi
    print_warn "临时域名 ${domain} 尚未进入公共 DNS，等待发布后重试..."
    sleep 5
  done

  return 1
}

argo_backoff_delay() {
  local fail_count="$1"
  local delay=1 i
  for ((i = 1; i < fail_count && delay < 1800; i++)); do
    delay=$((delay * 2))
  done
  [ "${delay}" -gt 1800 ] && delay=1800
  printf '%s' "${delay}"
}

argo_edge_ip_version() {
  local has4 has6
  # 边缘 IP 族选择：双栈环境交给 cloudflared --edge-ip-version auto（3.2）；
  # 单栈环境先探测 Cloudflare 同族边缘可达性；探测失败时只在本机实际具备的
  # IP 族内判断，绝不可翻转到本机没有的族（IPv4-only 主机回退 IPv6 必现
  # "network is unreachable"，v1.5.8 实测根因）。
  has4=false
  has6=false
  has_public_ipv4 && has4=true
  has_public_ipv6 && has6=true

  if [ "${has4}" = "true" ] && [ "${has6}" = "true" ]; then
    printf 'auto'
    return 0
  fi
  if [ "${has4}" = "true" ]; then
    if probe_edge_family "4"; then
      printf '4'
    else
      print_warn "IPv4 边缘（region1.v2.argotunnel.com）不可达，本机无 IPv6，保持 IPv4 边缘。"
      printf '4'
    fi
    return 0
  fi
  if [ "${has6}" = "true" ]; then
    if probe_edge_family "6"; then
      printf '6'
    else
      print_warn "IPv6 边缘（region1.v2.argotunnel.com）不可达，本机无 IPv4，保持 IPv6 边缘。"
      printf '6'
    fi
    return 0
  fi
  printf 'auto'
}

# 探测 Cloudflare 边缘注册服务（region1.v2.argotunnel.com:443）在指定 IP 族的可达性。
# 该端点并非 HTTP 站点：curl -f 对待 TLS 握手失败会误判为不可达（HTTPS GET 语义错误，
# 实际 TCP/TLS 均可达，属正常拒绝）。改为协议无关的 TCP 层连接测试：按目标族解析出
# 地址后直接建立 TCP 连接。优先解析族内地址 + bash /dev/tcp（不依赖 nc 的 -4/-6，BusyBox
# nc 不支持族参数）；getent 无族参数（部分 busybox）时以 curl 双保险回退。
probe_edge_family() {
  local fam="$1" ip
  case "${fam}" in 4 | 6) ;; *) return 1 ;; esac
  ip="$(getent "ahostsv${fam}" region1.v2.argotunnel.com 2>/dev/null | awk 'NR==1{print $1}' || true)"
  if [ -n "${ip}" ] && command_exists timeout; then
    timeout 4 bash -c 'exec 3<>"/dev/tcp/$1/443"' bash "${ip}" >/dev/null 2>&1
    return $?
  fi
  if [ -n "${ip}" ] && command_exists nc; then
    nc -z -w 3 "${ip}" 443 >/dev/null 2>&1
    return $?
  fi
  command_exists curl && curl -q -fsS "-${fam}" --connect-timeout 3 --max-time 4 "https://region1.v2.argotunnel.com" >/dev/null 2>&1
}

cloudflared_installed_version() {
  local out
  out="$("${CLOUDFLARED_BIN}" version 2>/dev/null | head -n 1 || true)"
  printf '%s' "${out#cloudflared version }"
}

# Require the installed executable and the command line emitted by this
# manager. The stdout log associates otherwise identical token tunnels with
# the right node (and distinguishes subscription tunnels from node tunnels).
argo_proc_matches() {
  local pid="$1" log="$2" mode="${3:-}" url="${4:-}" end=5
  local -a proc_argv
  managed_proc_exe "${pid}" "${CLOUDFLARED_BIN}" && managed_proc_log "${pid}" "${log}" && managed_proc_argv "${pid}" || return 1
  [ "${proc_argv[1]:-}" = tunnel ] && [ "${proc_argv[2]:-}" = --no-autoupdate ] &&
    [ "${proc_argv[3]:-}" = --protocol ] && [ "${proc_argv[4]:-}" = http2 ] || return 1
  if [ "${proc_argv[5]:-}" = --edge-ip-version ]; then
    case "${proc_argv[6]:-}" in 4 | 6 | auto) ;; *) return 1 ;; esac
    end=7
  fi
  case "${proc_argv[end]:-}" in
  run)
    [ -z "${mode}" ] || [ "${mode}" = token ] || return 1
    [ "${#proc_argv[@]}" -eq "$((end + 1))" ]
    ;;
  --url)
    [ "${mode}" != token ] && [ "${#proc_argv[@]}" -eq "$((end + 2))" ] || return 1
    [[ "${proc_argv[end + 1]}" =~ ^http://127\.0\.0\.1:[0-9]{1,5}$ ]] || return 1
    [ -z "${url}" ] || [ "${proc_argv[end + 1]}" = "${url}" ]
    ;;
  *) return 1 ;;
  esac
}

argo_spawn() {
  local file="$1" log="$2" mem
  shift 2
  mem="${GOMEMLIMIT:-}"
  if [ -z "${mem}" ]; then mem="$(go_mem_limit_value)" || return 1; fi
  if [ -n "${mem}" ]; then
    GOMEMLIMIT="${mem}" managed_spawn "${file}" "${log}" "${CLOUDFLARED_BIN}" "$@"
  else
    managed_spawn "${file}" "${log}" "${CLOUDFLARED_BIN}" "$@"
  fi
}

argo_node_running() {
  local tag="$1" port mode url=""
  [[ "${tag}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || return 1
  mode="$(node_value "${tag}" argo_mode)" || return 1
  if [ "${mode}" != token ]; then
    port="$(node_value "${tag}" port)" || return 1
    url="http://127.0.0.1:${port}"
  fi
  managed_pid_read "${RUNTIME_DIR}/${tag}.pid" argo_proc_matches "${LOG_DIR}/${tag}.cloudflared.log" "${mode}" "${url}" >/dev/null
}

stop_argo_node() {
  local tag="$1"
  [[ "${tag}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || return 1
  managed_pid_stop_file "${RUNTIME_DIR}/${tag}.pid" argo_proc_matches "${LOG_DIR}/${tag}.cloudflared.log"
}

# Mutating callers hold the global lock throughout stop, spawn, and domain
# publication. Watchdog uses this same path and never installs dependencies.

stop_all_argo_nodes() {
  local pid_file tag log identity pid birth failed=0
  [ ! -L "${RUNTIME_DIR}" ] || return 1
  [ -d "${RUNTIME_DIR}" ] || return 0
  for pid_file in "${RUNTIME_DIR}"/*.pid; do
    [ -e "${pid_file}" ] || continue
    [ -f "${pid_file}" ] && [ ! -L "${pid_file}" ] || continue
    tag="${pid_file##*/}"; tag="${tag%.pid}"
    [[ "${tag}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || continue
    log="${LOG_DIR}/${tag}.cloudflared.log"
    [ ! -L "${log}" ] || continue
    if identity="$(managed_pid_read "${pid_file}" argo_proc_matches "${log}" "" "" 2>/dev/null)"; then
      read -r pid birth <<<"${identity}"
      if ! managed_pid_stop "${pid}" "${birth}"; then failed=1; continue; fi
      rm -f -- "${pid_file}" || failed=1
    fi
  done
  return "${failed}"
}
start_argo_node() {
  local tag="$1" mode port token log_file pid_file domain edge_ip pid birth origin=""
  local -a args
  [[ "${tag}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || return 1
  [ "$(node_value "${tag}" protocol)" = vless-argo ] || return 1
  mode="$(node_value "${tag}" argo_mode)" || return 1
  port="$(node_value "${tag}" port)" || return 1
  if [ "${mode}" != token ]; then
    [[ "${port}" =~ ^[0-9]{1,5}$ ]] && [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ] || return 1
    origin="http://127.0.0.1:${port}"
  fi
  if argo_node_running "${tag}"; then
    if [ "${mode}" = token ] || [ -n "$(node_value "${tag}" endpoint_domain)" ]; then return 0; fi
  fi
  if [ ! -x "${CLOUDFLARED_BIN}" ]; then
    print_err '缺少 cloudflared，请先安装项目依赖。'
    return 1
  fi
  log_file="${LOG_DIR}/${tag}.cloudflared.log"
  pid_file="${RUNTIME_DIR}/${tag}.pid"
  stop_argo_node "${tag}" || return 1
  [ ! -L "${log_file}" ] && : >"${log_file}" || return 1
  if [ "${mode}" != token ]; then
    json_set_field "${NODES_FILE}" "${tag}" endpoint_domain '' || return 1
  fi
  edge_ip="$(argo_edge_ip_version)" || return 1
  args=(tunnel --no-autoupdate --protocol http2 --edge-ip-version "${edge_ip}")
  if [ "${mode}" = token ]; then
    token="$(secret_value "${tag}" argo_token)" && [ -n "${token}" ] || return 1
    # cloudflared consumes TUNNEL_TOKEN from the environment, never from argv.
    TUNNEL_TOKEN="${token}" argo_spawn "${pid_file}" "${log_file}" "${args[@]}" run || return 1
  else
    argo_spawn "${pid_file}" "${log_file}" "${args[@]}" --url "${origin}" || return 1
  fi
  if ! managed_wait_exec "${pid_file}" argo_proc_matches "${log_file}" "${mode}" "${origin}"; then
    stop_argo_node "${tag}" || true
    print_err "Argo 进程启动失败，请检查 ${log_file}。"
    return 1
  fi
  if [ "${mode}" = token ]; then
    return 0
  fi
  if read -r pid birth <"${pid_file}" &&
    domain="$(wait_for_trycloudflare_domain_verified "${log_file}" 60 1 "${pid}" "${birth}")" &&
    [ "$(node_value "${tag}" protocol)" = vless-argo ] && [ "$(node_value "${tag}" port)" = "${port}" ] &&
    [ "$(node_value "${tag}" argo_mode)" = "${mode}" ] &&
    argo_node_running "${tag}" && json_set_field "${NODES_FILE}" "${tag}" endpoint_domain "${domain}"; then
    return 0
  fi
  stop_argo_node "${tag}" || true
  print_err "无法发布 ${tag} 的临时 Argo 域名。"
  return 1
}

restart_all_argo_nodes() {
  local tag tags failed=0
  tags="$(jq -er 'to_entries | map(select(.value.protocol == "vless-argo") | .key) | .[]?' "${NODES_FILE}")" || {
    # jq -e reports no matches as failure; distinguish valid empty input.
    jq -e 'type == "object" and all(.[]; type == "object")' "${NODES_FILE}" >/dev/null || return 1
    [ -z "${tags}" ] || return 1
  }
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    if ! start_argo_node "${tag}"; then print_warn "Argo 隧道 ${tag} 启动失败。"; failed=1; fi
  done <<<"${tags}"
  return "${failed}"
}
