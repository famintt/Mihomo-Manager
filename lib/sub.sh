#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

# Subscription payloads and credentials remain outside the HTTP document root.
sub_private_dir() { printf '%s/sub-private' "${BASE_DIR}"; }
sub_public_dir() { printf '%s/sub-public' "${BASE_DIR}"; }
sub_legacy_dir() { printf '%s/sub' "${BASE_DIR}"; }
sub_url_file() { printf '%s/url' "$(sub_private_dir)"; }
sub_http_script() { printf '%s/http.py' "$(sub_private_dir)"; }
sub_http_log() { printf '%s/sub-http.log' "${LOG_DIR}"; }
sub_tunnel_log() { printf '%s/sub.cloudflared.log' "${LOG_DIR}"; }
sub_http_pid_file() { printf '%s/sub-http.pid' "${RUNTIME_DIR}"; }
sub_tunnel_pid_file() { printf '%s/sub-tunnel.pid' "${RUNTIME_DIR}"; }
sub_migration_marker() { printf '%s/sub-migration-v2' "${BASE_DIR}"; }

sub_with_lock() {
  local status
  if [ "${LOCK_HELD:-false}" = true ] && [ "${LOCK_OWNER_PID:-}" = "${BASHPID}" ]; then
    "$@"
    return $?
  fi
  acquire_lock || return 1
  if "$@"; then status=0; else status=$?; fi
  release_lock || return 1
  return "${status}"
}

sub_enabled() {
  local configured
  configured="$(manager_env_or_setting "sub" "")" || return 2
  case "${configured}" in
  1 | on | yes | true) return 0 ;;
  esac
  configured="$(get_setting "sub_enabled" "0")" || return 2
  [ "${configured}" = "1" ]
}

sub_mode() {
  local mode
  if [ "${sub_mode+x}" = x ]; then mode="${sub_mode}"; else mode="$(get_setting sub_mode temp)" || return 1; fi
  case "${mode}" in
  worker | temp) printf '%s' "${mode}" ;;
  *) print_err '订阅模式无效：仅允许 temp 或 worker。'; return 1 ;;
  esac
}

# Do not use manager_env_or_setting here: it silently trims/re-writes raw
# credentials. Invalid explicit environment values must fail closed.
sub_setting_value() {
  local name="$1" value
  case "${name}" in
  sub_domain) if [ "${sub_domain+x}" = x ]; then value="${sub_domain}"; else value="$(get_setting sub_domain "")" || return 1; fi ;;
  sub_machine) if [ "${sub_machine+x}" = x ]; then value="${sub_machine}"; else value="$(get_setting sub_machine "")" || return 1; fi ;;
  sub_read_token) if [ "${sub_read_token+x}" = x ]; then value="${sub_read_token}"; else value="$(get_setting sub_read_token "")" || return 1; fi ;;
  sub_report_token) if [ "${sub_report_token+x}" = x ]; then value="${sub_report_token}"; else value="$(get_setting sub_report_token "")" || return 1; fi ;;
  *) return 1 ;;
  esac
  printf '%s' "${value}"
}

sub_domain_valid() {
  local input="$1" host port label
  [[ "${input}" != *[$'\r\n\t '?]* && "${input}" != *'?'* && "${input}" != *'#'* && "${input}" != *'@'* ]] || return 1
  [[ "${input}" =~ ^https://([^/]+)$ ]] && host="${BASH_REMATCH[1]}" || host="${input}"
  [[ "${host}" != *'/'* && "${host}" != *'\\'* ]] || return 1
  if [[ "${host}" == *:* ]]; then
    port="${host##*:}"
    host="${host%:*}"
    [[ "${port}" =~ ^[0-9]{1,5}$ ]] && [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ] || return 1
  fi
  [[ "${host}" =~ ^[A-Za-z0-9.-]+$ && "${host}" != .* && "${host}" != *. && "${host}" != *..* ]] || return 1
  [[ "${host}" == *.* ]] || return 1
  local -a labels
  IFS=. read -r -a labels <<<"${host}"
  for label in "${labels[@]}"; do
    [[ "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
  done
}

sub_worker_base() {
  local base
  base="$(sub_setting_value sub_domain)" || return 1
  [ -n "${base}" ] || return 1
  base="${base%/}"
  if [[ "${base}" != https://* ]]; then base="https://${base}"; fi
  sub_domain_valid "${base}" || return 1
  printf '%s' "${base}"
}

sub_machine() {
  local machine
  if [ "${sub_machine+x}" = x ]; then machine="${sub_machine}"; else machine="$(get_setting sub_machine "")" || return 1; fi
  if [ -z "${machine}" ]; then
    machine="$(get_setting name "")" || return 1
    [ -n "${machine}" ] || machine="$(hostname 2>/dev/null || printf node)"
    machine="$(printf '%s' "${machine}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
    machine="${machine:0:64}"; [ -n "${machine}" ] || machine=node
  fi
  [[ "${machine}" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || return 1
  printf '%s' "${machine}"
}

sub_read_token() {
  local token old
  token="$(sub_setting_value sub_read_token)" || return 1
  old="$(get_setting sub_token '')" || return 1
  [[ "${token}" =~ ^[A-Za-z0-9_-]{22,}$ ]] || return 1
  [ -z "${old}" ] || [ "${token}" != "${old}" ] || return 1
  if [ "${sub_token+x}" = x ]; then [ "${token}" != "${sub_token}" ] || return 1; fi
  printf '%s' "${token}"
}

sub_report_token() {
  local token old read_token
  token="$(sub_setting_value sub_report_token)" || return 1
  old="$(get_setting sub_token '')" || return 1
  read_token="$(sub_read_token)" || return 1
  [[ "${token}" =~ ^[A-Za-z0-9_-]{22,}$ ]] || return 1
  [ "${token}" != "${read_token}" ] && [ "${token}" != "${old}" ] || return 1
  if [ "${sub_token+x}" = x ]; then [ "${token}" != "${sub_token}" ] || return 1; fi
  printf '%s' "${token}"
}

sub_content_hash() {
  local file="$1"
  command_exists sha256sum && { sha256sum "${file}" | awk '{print $1}'; return; }
  command_exists shasum && { shasum -a 256 "${file}" | awk '{print $1}'; return; }
  openssl dgst -sha256 "${file}" | awk '{print $NF}'
}

sub_temp_token() {
  local file token
  file="$(sub_private_dir)/temp.token"
  [ ! -L "${file}" ] || return 1
  if [ -s "${file}" ]; then token="$(<"${file}")"; else token=""; fi
  if ! [[ "${token}" =~ ^[0-9a-f]{32}$ ]]; then
    token="$(generate_hex 16)" || return 1
    [[ "${token}" =~ ^[0-9a-f]{32}$ ]] || return 1
    printf '%s\n' "${token}" >"${file}" || return 1
    chmod 600 "${file}"
  fi
  printf '%s' "${token}"
}

sub_file() { printf '%s/payload.txt' "$(sub_private_dir)"; }
sub_links_file() { printf '%s/links.txt' "$(sub_private_dir)"; }

sub_prepare_dirs() {
  local private public
  private="$(sub_private_dir)"
  public="$(sub_public_dir)"
  [ ! -L "${BASE_DIR}" ] && [ ! -L "${private}" ] && [ ! -L "${public}" ] || return 1
  ensure_dir_mode "${private}" 700 || return 1
  ensure_dir_mode "${public}" 755 || return 1
  ensure_dir_mode "${LOG_DIR}" 700 || return 1
  ensure_dir_mode "${RUNTIME_DIR}" 700 || return 1
}

# Static read-only Python fallback; runtime startup executes it directly and never writes scripts.
sub_http_python_code() {
  cat <<'PYTHON'
import http.server
import os
import pwd
import re
import stat
import sys
port = int(sys.argv[1])
root = os.path.realpath(sys.argv[2])
token = os.environ.get("MM_SUB_HTTP_TOKEN", "")
if not (1 <= port <= 65535 and re.fullmatch(r"[0-9a-f]{32}", token)):
    raise SystemExit(2)
name = token + ".txt"
path = os.path.join(root, name)
if os.path.islink(root) or not os.path.isdir(root):
    raise SystemExit(2)
class Handler(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self): self._serve(True)
    def do_GET(self): self._serve(False)
    def _serve(self, head):
        if self.path != "/" + name:
            self.send_error(404)
            return
        try:
            fd = os.open("/" + name if chrooted else path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):
                os.close(fd)
                self.send_error(404)
                return
            with os.fdopen(fd, "rb") as payload: body = payload.read()
        except OSError:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if not head: self.wfile.write(body)
    def log_message(self, fmt, *args): sys.stderr.write("subscription-http: " + (fmt % args) + "\n")
# Avoid worker threads after chroot: older Python/glibc may need libgcc_s to cancel them.
class Server(http.server.HTTPServer):
    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(5)
        return connection, address
server = Server(("127.0.0.1", port), Handler)
chrooted = False
if os.geteuid() == 0:
    account = pwd.getpwnam("nobody")
    os.chroot(root)
    os.chdir("/")
    chrooted = True
    os.setgroups([])
    os.setgid(account.pw_gid)
    os.setuid(account.pw_uid)
server.serve_forever()
PYTHON
}

sub_build_file() {
  local private public token tmp links_tmp tags_tmp public_tmp public_file public_ip tag link entry mode
  private="$(sub_private_dir)"
  public="$(sub_public_dir)"
  sub_prepare_dirs || return 1
  mode="$(sub_mode)" || return 1
  if [ "${mode}" = worker ]; then token="$(sub_read_token)" || { print_err 'Worker 订阅读取密钥无效或缺失。'; return 1; }
  else token="$(sub_temp_token)" || return 1; fi
  if [ -n "$(manager_env_or_setting direct_host '')" ] || [ -n "$(manager_env_or_setting server_ip '')" ]; then public_ip="";
  else public_ip="$(MM_IP_PROBE_PARALLEL=0 get_public_ip 2>/dev/null || true)"; fi
  tmp="$(mktemp "${private}/.payload.XXXXXX")" || return 1
  links_tmp="$(mktemp "${private}/.links.XXXXXX")" || { rm -f "${tmp}"; return 1; }
  tags_tmp="$(mktemp "${private}/.tags.XXXXXX")" || { rm -f "${tmp}" "${links_tmp}"; return 1; }
  if ! iter_node_tags >"${tags_tmp}"; then rm -f "${tmp}" "${links_tmp}" "${tags_tmp}"; return 1; fi
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    link="$(build_share_link "${tag}" "${public_ip}" 2>/dev/null)" || { rm -f "${tmp}" "${links_tmp}" "${tags_tmp}"; return 1; }
    [ -n "${link}" ] || { rm -f "${tmp}" "${links_tmp}" "${tags_tmp}"; return 1; }
    printf '%s\n' "${link}" >>"${links_tmp}" || { rm -f "${tmp}" "${links_tmp}" "${tags_tmp}"; return 1; }
  done <"${tags_tmp}"
  rm -f -- "${tags_tmp}"
  if [ ! -s "${links_tmp}" ]; then rm -f "${tmp}" "${links_tmp}"; print_warn '当前没有可写入订阅的节点。'; return 1; fi
  base64 <"${links_tmp}" | tr -d '\n' >"${tmp}" || { rm -f "${tmp}" "${links_tmp}"; return 1; }
  printf '\n' >>"${tmp}"
  chmod 600 "${tmp}" "${links_tmp}"
  mv -fT -- "${links_tmp}" "$(sub_links_file)" || { rm -f "${tmp}"; return 1; }
  mv -fT -- "${tmp}" "$(sub_file)" || return 1
  chmod 600 "$(sub_links_file)" "$(sub_file)"
  if [ "${mode}" = temp ]; then
    public_file="${public}/${token}.txt"
    [ ! -L "${public_file}" ] || { rm -f "${public_tmp:-}"; return 1; }
    for entry in "${public}"/* "${public}"/.[!.]* "${public}"/..?*; do
      [ -e "${entry}" ] || [ -L "${entry}" ] || continue
      [ "${entry}" = "${public_file}" ] && continue
      [ ! -L "${entry}" ] && [ -f "${entry}" ] && [[ "${entry##*/}" =~ ^[0-9a-f]{32}\.txt$ ]] || { rm -f "${tmp:-}" "${links_tmp:-}"; return 1; }
    done
    public_tmp="$(mktemp "${private}/.publish.XXXXXX")" || return 1
    cp -- "$(sub_file)" "${public_tmp}" && chmod 644 "${public_tmp}" && mv -fT -- "${public_tmp}" "${public_file}" || { rm -f "${public_tmp}"; return 1; }
    for entry in "${public}"/* "${public}"/.[!.]* "${public}"/..?*; do
      [ -e "${entry}" ] || [ -L "${entry}" ] || continue
      [ "${entry}" = "${public_file}" ] && continue
      rm -f -- "${entry}" || return 1
    done
  fi
}

sub_worker_url() {
  local base machine token
  base="$(sub_worker_base)" || { print_err 'Worker sub_domain 必须是 HTTPS origin 或 DNS 主机名。'; return 1; }
  machine="$(sub_machine)" || { print_err 'sub_machine 无效或缺失。'; return 1; }
  token="$(sub_read_token)" || { print_err 'Worker sub_read_token 无效或缺失，禁止回退到旧 sub_token。'; return 1; }
  printf '%s/sub/%s/%s' "${base}" "${machine}" "${token}"
}

# Credentials are written only to a private temporary curl config (0600); no
# token is placed in curl's argv or saved in sub_url/settings.
sub_report() {
  local base machine report_token read_url payload links_hash hash cfg response status url url_file
  base="$(sub_worker_base)" || { print_err 'Worker sub_domain 必须是 HTTPS origin 或 DNS 主机名。'; return 1; }
  machine="$(sub_machine)" || { print_err 'sub_machine 无效或缺失。'; return 1; }
  report_token="$(sub_report_token)" || { print_err 'Worker sub_report_token 无效、缺失或与 read token 重用。'; return 1; }
  read_url="$(sub_worker_url)" || return 1
  payload="$(sub_file)"
  [ -s "${payload}" ] && [ ! -L "${payload}" ] || { print_err '订阅内容不存在。'; return 1; }
  command_exists curl || { print_err '订阅上报需要 curl。'; return 1; }
  cfg="$(mktemp "$(sub_private_dir)/.curl.XXXXXX")" || return 1
  response="$(mktemp "$(sub_private_dir)/.response.XXXXXX")" || { rm -f "${cfg}"; return 1; }
  chmod 600 "${cfg}" "${response}"
  printf 'url = "%s/api/v1/report/%s"\nrequest = "POST"\nheader = "Authorization: Bearer %s"\nheader = "Content-Type: text/plain"\n' \
    "${base}" "${machine}" "${report_token}" >"${cfg}" || { rm -f "${cfg}" "${response}"; return 1; }
  status="$(curl -q --proto '=https' --config "${cfg}" --data-binary "@${payload}" --connect-timeout 10 --max-time 30 --output "${response}" --write-out '%{http_code}' 2>/dev/null || true)"
  if [ "${status}" != 200 ]; then
    print_err "订阅上报失败（HTTP ${status:-000}）。"
    rm -f -- "${cfg}" "${response}"
    return 1
  fi
  links_hash="$(sub_content_hash "$(sub_links_file)")" || { rm -f "${cfg}" "${response}"; return 1; }
  hash="$(sub_content_hash "${payload}")" || { rm -f "${cfg}" "${response}"; return 1; }
  url_file="$(sub_url_file)"
  printf '%s\n' "${read_url}" >"${url_file}.tmp"
  chmod 600 "${url_file}.tmp" && mv -fT -- "${url_file}.tmp" "${url_file}" || { rm -f "${cfg}" "${response}" "${url_file}.tmp"; return 1; }
  set_setting sub_hash "${hash}" || { rm -f "${cfg}" "${response}"; return 1; }
  set_setting sub_links_hash "${links_hash}" || { rm -f "${cfg}" "${response}"; return 1; }
  rm -f -- "${cfg}" "${response}"
  print_ok "订阅已通过 Worker 上报：${read_url}"
}

sub_local_port() {
  local port
  port="$(manager_env_or_setting sub_port 18080)"
  [[ "${port}" =~ ^[0-9]{1,5}$ ]] && [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ] || port=18080
  printf '%s' "${port}"
}

sub_http_matches() {
  local pid="$1" port="$2" public python dark
  local -a proc_argv
  public="$(sub_public_dir)"
  managed_proc_log "${pid}" "$(sub_http_log)" && managed_proc_argv "${pid}" || return 1
  if [ "${proc_argv[1]:-}" = -c ]; then
    python="$(command -v python3 2>/dev/null || true)"
    [ -n "${python}" ] && managed_proc_exe "${pid}" "${python}" || return 1
    [ "${#proc_argv[@]}" -eq 5 ] && [ "${proc_argv[2]}" = "$(sub_http_python_code)" ] && [ "${proc_argv[3]}" = "${port}" ] && [ "${proc_argv[4]}" = "${public}" ]
    return $?
  fi
  dark="$(command -v darkhttpd 2>/dev/null || true)"
  [ -n "${dark}" ] && managed_proc_exe "${pid}" "${dark}" || return 1
  [ "${#proc_argv[@]}" -eq 14 ] && [ "${proc_argv[1]}" = "${public}" ] &&
    [ "${proc_argv[2]}" = --port ] && [ "${proc_argv[3]}" = "${port}" ] &&
    [ "${proc_argv[4]}" = --addr ] && [ "${proc_argv[5]}" = 127.0.0.1 ] &&
    [ "${proc_argv[6]}" = --chroot ] && [ "${proc_argv[7]}" = --no-listing ] &&
    [ "${proc_argv[8]}" = --uid ] && [ "${proc_argv[9]}" = nobody ] &&
    [ "${proc_argv[10]}" = --gid ] && [ "${proc_argv[11]}" = nogroup ] &&
    [ "${proc_argv[12]}" = --header ] && [ "${proc_argv[13]}" = 'Cache-Control: no-store' ]
}

sub_http_start() {
  local public port log pid_file token python dark identity
  public="$(sub_public_dir)" || return 1
  port="$(sub_local_port)" || return 1
  log="$(sub_http_log)" || return 1
  pid_file="$(sub_http_pid_file)" || return 1
  sub_prepare_dirs || return 1
  token="$(sub_temp_token)" || return 1
  [ -f "${public}/${token}.txt" ] && [ ! -L "${public}/${token}.txt" ] || return 1
  if identity="$(managed_pid_read "${pid_file}" sub_http_matches "${port}" 2>/dev/null)"; then return 0; fi
  managed_pid_stop_file "${pid_file}" sub_http_matches "${port}" || return 1
  [ ! -L "${log}" ] || return 1
  : >"${log}"; chmod 600 "${log}"
  dark="$(command -v darkhttpd 2>/dev/null || true)"
  if [ -n "${dark}" ]; then
    managed_spawn "${pid_file}" "${log}" "${dark}" "${public}" --port "${port}" --addr 127.0.0.1 --chroot --no-listing --uid nobody --gid nogroup --header "Cache-Control: no-store" || return 1
  elif command_exists python3; then
    python="$(command -v python3)"
    MM_SUB_HTTP_TOKEN="${token}" managed_spawn "${pid_file}" "${log}" "${python}" -c "$(sub_http_python_code)" "${port}" "${public}" || return 1
  else
    print_err '订阅服务需要 darkhttpd 或 python3。'; return 1
  fi
  managed_wait_exec "${pid_file}" sub_http_matches "${port}" || { managed_pid_stop_file "${pid_file}" sub_http_matches "${port}" || true; return 1; }
  local attempts=10
  while ((attempts > 0)); do
    if curl -q -fsS --max-time 3 "http://127.0.0.1:${port}/$(sub_temp_token).txt" >/dev/null 2>&1; then return 0; fi
    attempts=$((attempts - 1))
    sleep 0.2
  done
  managed_pid_stop_file "${pid_file}" sub_http_matches "${port}" || true
  print_err '订阅 HTTP 服务未通过本机读取验证。'; return 1
}

sub_tunnel_matches() {
  local pid="$1" port log
  port="$(sub_local_port)" || return 1
  log="$(sub_tunnel_log)" || return 1
  argo_proc_matches "${pid}" "${log}" url "http://127.0.0.1:${port}"
}

sub_tunnel_start() {
  local port log pid_file token url domain pid birth identity
  port="$(sub_local_port)" || return 1
  log="$(sub_tunnel_log)" || return 1
  pid_file="$(sub_tunnel_pid_file)" || return 1
  token="$(sub_temp_token)" || return 1
  if identity="$(managed_pid_read "${pid_file}" sub_tunnel_matches 2>/dev/null)"; then
    domain="$(get_setting sub_temp_domain '')"
    if [[ "${domain}" =~ ^[a-z0-9-]+\.trycloudflare\.com$ ]]; then
      url="https://${domain}/${token}.txt"
      printf '%s\n' "${url}" >"$(sub_url_file).tmp" && chmod 600 "$(sub_url_file).tmp" && mv -fT "$(sub_url_file).tmp" "$(sub_url_file)" && return 0
    fi
  fi
  managed_pid_stop_file "${pid_file}" sub_tunnel_matches || return 1
  [ -x "${CLOUDFLARED_BIN}" ] || { print_err '缺少 cloudflared；请先安装项目依赖。'; return 1; }
  [ ! -L "${log}" ] || return 1
  : >"${log}"; chmod 600 "${log}"
  local -a args=(tunnel --no-autoupdate --protocol http2 --url "http://127.0.0.1:${port}")
  argo_spawn "${pid_file}" "${log}" "${args[@]}" || return 1
  managed_wait_exec "${pid_file}" sub_tunnel_matches || { managed_pid_stop_file "${pid_file}" sub_tunnel_matches || true; return 1; }
  read -r pid birth <"${pid_file}" || return 1
  domain="$(MM_ARGO_SKIP_DNS_VERIFY=1 wait_for_trycloudflare_domain_verified "${log}" 60 1 "${pid}" "${birth}" || true)"
  if [ -z "${domain}" ] || ! sub_tunnel_matches "${pid}"; then managed_pid_stop_file "${pid_file}" sub_tunnel_matches || true; return 1; fi
  url="https://${domain}/${token}.txt"
  printf '%s\n' "${url}" >"$(sub_url_file).tmp" && chmod 600 "$(sub_url_file).tmp" && mv -fT "$(sub_url_file).tmp" "$(sub_url_file)" || return 1
  set_setting sub_temp_domain "${domain}" || return 1
  print_ok "订阅临时域名：${url}"
}

sub_start_impl() {
  local mode entry private public
  mode="$(sub_mode)" || return 1
  if [ "${mode}" = worker ]; then
    sub_stop_impl || return 1
    private="$(sub_private_dir)" || return 1
    public="$(sub_public_dir)" || return 1
    rm -f -- "${private}/temp.token" "${private}/url" || return 1
    for entry in "${public}"/* "${public}"/.[!.]* "${public}"/..?*; do
      [ -e "${entry}" ] || [ -L "${entry}" ] || continue
      [ ! -L "${entry}" ] && [ -f "${entry}" ] && [[ "${entry##*/}" =~ ^[0-9a-f]{32}\.txt$ ]] || return 1
      rm -f -- "${entry}" || return 1
    done
  fi
  sub_build_file || return 1
  if [ "${mode}" = worker ]; then sub_report; return $?; fi
  sub_http_start || return 1
  sub_tunnel_start || return 1
  [ ! -s "$(sub_url_file)" ] || print_ok "订阅链接：$(<"$(sub_url_file)")"
}

sub_start() { sub_with_lock sub_start_impl "$@"; }

# Called only by an upgrade orchestrator holding the global lock, after old
# watchdog and ingress are stopped and before the new ingress is started.
sub_legacy_http_matches() {
  local pid="$1" port="$2" old
  old="$(sub_legacy_dir)" || return 1
  local -a proc_argv
  managed_proc_log "${pid}" "$(sub_http_log)" && managed_proc_argv "${pid}" || return 1
  if [ "${proc_argv[1]:-}" = -m ] && [ "${proc_argv[2]:-}" = http.server ]; then
    local python
    python="$(command -v python3 2>/dev/null || true)"
    [ -n "${python}" ] && managed_proc_exe "${pid}" "${python}" || return 1
    [ "${#proc_argv[@]}" -eq 8 ] && [[ "${proc_argv[3]}" =~ ^[0-9]{1,5}$ ]] &&
      { [ -z "${port}" ] || [ "${proc_argv[3]}" = "${port}" ]; } &&
      [ "${proc_argv[4]}" = --bind ] && [ "${proc_argv[5]}" = 127.0.0.1 ] &&
      [ "${proc_argv[6]}" = --directory ] && [ "${proc_argv[7]}" = "${old}" ]
    return $?
  fi
  local dark
  dark="$(command -v darkhttpd 2>/dev/null || true)"
  [ -n "${dark}" ] && managed_proc_exe "${pid}" "${dark}" || return 1
  [ "${#proc_argv[@]}" -eq 6 ] && [ "${proc_argv[1]}" = "${old}" ] &&
    [ "${proc_argv[2]}" = --port ] && [[ "${proc_argv[3]}" =~ ^[0-9]{1,5}$ ]] &&
    { [ -z "${port}" ] || [ "${proc_argv[3]}" = "${port}" ]; } &&
    [ "${proc_argv[4]}" = --addr ] && [ "${proc_argv[5]}" = 127.0.0.1 ]
}

sub_legacy_tunnel_matches() {
  local pid="$1" log
  log="$(sub_tunnel_log)" || return 1
  argo_proc_matches "${pid}" "${log}" url ""
}

sub_migrate() {
  local marker old http_pid tunnel_pid pid birth identity stored_domain
  [[ "${LOCK_HELD:-false}" = true && "${LOCK_OWNER_PID:-}" = "${BASHPID}" ]] || { print_err 'sub_migrate 必须在持有全局锁时调用。'; return 1; }
  marker="$(sub_migration_marker)"; old="$(sub_legacy_dir)"
  [ ! -L "${BASE_DIR}" ] && [ ! -L "${BASE_DIR}/data" ] &&
    [ ! -L "$(sub_private_dir)" ] && [ ! -L "$(sub_public_dir)" ] &&
    [ ! -L "${LOG_DIR}" ] && [ ! -L "${RUNTIME_DIR}" ] && [ ! -L "${marker}" ] || return 1
  if [ -e "${marker}" ]; then
    [ -f "${marker}" ] && [ ! -L "${marker}" ] || return 1
    return 0
  fi
  http_pid="$(sub_http_pid_file)"; tunnel_pid="$(sub_tunnel_pid_file)"
  ensure_dir_mode "${LOG_DIR}" 700 || return 1
  ensure_dir_mode "${RUNTIME_DIR}" 700 || return 1
  if [ -d "${old}" ] || [ -L "${old}" ]; then
    [ -d "${old}" ] && [ ! -L "${old}" ] || { print_err '拒绝迁移符号链接旧订阅目录。'; return 1; }
    # Stop only old processes whose executable, complete argv and log descriptor
    # all prove ownership. A stale or unrelated PID is never signalled.
    if [ -L "${http_pid}" ] || [ -L "${tunnel_pid}" ]; then print_err '拒绝迁移符号链接 PID 文件。'; return 1; fi
    if [ -e "${http_pid}" ]; then
      [ -f "${http_pid}" ] || return 1
      if read -r pid <"${http_pid}" && [[ "${pid}" =~ ^[1-9][0-9]*$ ]]; then
        local port
        port="$(sub_local_port)"
        if identity="$(managed_pid_read "${http_pid}" sub_legacy_http_matches "${port}" 2>/dev/null)"; then read -r pid birth <<<"${identity}"; managed_pid_stop "${pid}" "${birth}" || return 1; fi
      fi
    fi
    if [ -e "${tunnel_pid}" ]; then
      [ -f "${tunnel_pid}" ] || return 1
      if read -r pid <"${tunnel_pid}" && [[ "${pid}" =~ ^[1-9][0-9]*$ ]]; then
        local port
        port="$(sub_local_port)"
        if identity="$(managed_pid_read "${tunnel_pid}" sub_legacy_tunnel_matches 2>/dev/null)"; then read -r pid birth <<<"${identity}"; managed_pid_stop "${pid}" "${birth}" || return 1; fi
      fi
    fi
    for old_pid_path in /proc/[0-9]*; do
      [ -d "${old_pid_path}" ] || continue
      pid="${old_pid_path##*/}"
      if sub_legacy_http_matches "${pid}" ""; then birth="$(managed_proc_birth "${pid}")" || return 1; managed_pid_stop "${pid}" "${birth}" || return 1; fi
      if sub_legacy_tunnel_matches "${pid}"; then birth="$(managed_proc_birth "${pid}")" || return 1; managed_pid_stop "${pid}" "${birth}" || return 1; fi
    done
    if [ -f "${http_pid}" ] && [ ! -L "${http_pid}" ]; then rm -f "${http_pid}"; fi
    if [ -f "${tunnel_pid}" ] && [ ! -L "${tunnel_pid}" ]; then rm -f "${tunnel_pid}"; fi
    rm -rf -- "${old}" || return 1
  fi
  [ ! -L "$(sub_url_file)" ] || return 1
  rm -f -- "$(sub_url_file)" "$(sub_private_dir)/temp.token"
  stored_domain="$(get_setting sub_domain '')" || return 1
  if [[ "${stored_domain}" =~ ^https?://([a-z0-9-]+\.trycloudflare\.com)(/)?$ ]]; then stored_domain="${BASH_REMATCH[1]}"; fi
  if [[ "${stored_domain}" =~ ^[a-z0-9-]+\.trycloudflare\.com$ ]]; then
    set_setting sub_temp_domain "${stored_domain}" || return 1
    set_setting sub_domain '' || return 1
  fi
  set_setting sub_url '' || return 1
  set_setting sub_token '' || return 1
  set_setting sub_hash '' || return 1
  set_setting sub_links_hash '' || return 1
  sub_prepare_dirs || return 1
  sub_temp_token >/dev/null || return 1
  local marker_tmp
  marker_tmp="$(mktemp "${BASE_DIR}/.sub-migration.XXXXXX")" || return 1
  if ! printf '%s\n' '2' >"${marker_tmp}" || ! chmod 600 "${marker_tmp}" || ! mv -fT -- "${marker_tmp}" "${marker}"; then rm -f -- "${marker_tmp}"; return 1; fi
}

sub_stop_impl() {
  local tunnel_pid http_pid port url
  tunnel_pid="$(sub_tunnel_pid_file)" || return 1
  http_pid="$(sub_http_pid_file)" || return 1
  port="$(sub_local_port)" || return 1
  url="$(sub_url_file)" || return 1
  managed_pid_stop_file "${tunnel_pid}" sub_tunnel_matches || return 1
  managed_pid_stop_file "${http_pid}" sub_http_matches "${port}" || return 1
  [ ! -L "${url}" ] || return 1
  rm -f -- "${url}"
}

sub_stop() { sub_with_lock sub_stop_impl "$@"; }

sub_url_impl() {
  local mode url
  mode="$(sub_mode)" || return 1
  if [ "${mode}" = worker ]; then url="$(sub_worker_url)" || return 1; printf '%s\n' "${url}"; return 0; fi
  if [ ! -s "$(sub_url_file)" ] || ! sub_tunnel_matches "$(read -r p _ <"$(sub_tunnel_pid_file)" 2>/dev/null; printf '%s' "${p:-}")"; then
    sub_start_impl >/dev/null || return 1
  fi
  [ -f "$(sub_url_file)" ] && [ ! -L "$(sub_url_file)" ] || return 1
  cat -- "$(sub_url_file)"
}

sub_url() { sub_with_lock sub_url_impl "$@"; }

sub_status() {
  local mode url
  mode="$(sub_mode)" || return 1
  url="$(cat "$(sub_url_file)" 2>/dev/null || true)"
  echo "订阅服务：$(sub_enabled && echo 已启用 || echo 未启用)"
  echo "订阅模式：${mode}"
  if [ "${mode}" = worker ]; then
    echo "Worker 域名：$(sub_worker_base 2>/dev/null || echo 未配置)"
    echo "订阅机器：$(sub_machine 2>/dev/null || echo 无效)"
  else
    echo "HTTP 端口：127.0.0.1:$(sub_local_port)"
    echo "HTTP 进程：$(managed_pid_read "$(sub_http_pid_file)" sub_http_matches "$(sub_local_port)" >/dev/null 2>&1 && echo running || echo stopped)"
    echo "隧道进程：$(managed_pid_read "$(sub_tunnel_pid_file)" sub_tunnel_matches >/dev/null 2>&1 && echo running || echo stopped)"
    echo "临时域名：$(get_setting sub_temp_domain '未生成')"
  fi
  echo "订阅链接：${url:-未生成}"
}

ensure_sub_impl() {
  if sub_enabled; then :; else
    local enabled_status=$?
    [ "${enabled_status}" -eq 1 ] && return 0
    return "${enabled_status}"
  fi
  local mode links_hash
  mode="$(sub_mode)" || return 1
  if [ "${mode}" = worker ]; then sub_start_impl; return $?; fi
  sub_build_file || { print_warn '订阅内容生成失败（可能暂无节点）。'; return 1; }
  sub_http_start || return 1
  sub_tunnel_start
}

ensure_sub() { sub_with_lock ensure_sub_impl "$@"; }
