#!/usr/bin/env bash
# Loopback-only subscription tests; Worker HTTP is replaced with a local curl stub.
# shellcheck disable=SC1091,SC2015,SC2016,SC2034,SC2231,SC2317,SC2329
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
PASS=0
CLEANUP_PIDS=()
HTTP_PID_FILE=""; HTTP_PORT=""
cleanup() {
  local pid
  for pid in "${CLEANUP_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
  if [ -n "$HTTP_PID_FILE" ] && [ -f "$HTTP_PID_FILE" ]; then managed_pid_stop_file "$HTTP_PID_FILE" sub_http_matches "$HTTP_PORT" >/dev/null 2>&1 || true; fi
  if [ "${AUDIT_KEEP:-0}" = 1 ]; then printf 'AUDIT_ROOT=%s\n' "$TEST_ROOT" >&2; else rm -rf -- "$TEST_ROOT"; fi
}
trap cleanup EXIT
source "$ROOT_DIR/lib/fmt.sh"
source "$ROOT_DIR/lib/io.sh"
source "$ROOT_DIR/lib/storage.sh"
source "$ROOT_DIR/lib/argo.sh"
source "$ROOT_DIR/lib/sub.sh"
BASE_DIR="$TEST_ROOT/base"; LOG_DIR="$TEST_ROOT/log"; RUNTIME_DIR="$TEST_ROOT/run"; SETTING_FILE="$TEST_ROOT/settings.json"
mkdir -p "$BASE_DIR" "$LOG_DIR" "$RUNTIME_DIR"; printf '{}\n' >"$SETTING_FILE"
CLOUDFLARED_BIN="$TEST_ROOT/missing-cloudflared"
declare -Ag SETTINGS=()
SETTINGS[sub_port]="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
SETTINGS[sub_domain]='worker.example.test'; SETTINGS[sub_machine]='audit-node'
SETTINGS[sub_read_token]='READ_TOKEN_0123456789abcdefghijkl'
SETTINGS[sub_report_token]='REPORT_TOKEN_0123456789abcdefghijk'
SETTINGS[sub_token]='legacy-shared-token-should-never-be-used'
SETTINGS[sub_temp_domain]=''; SETTINGS[sub_url]=''; SETTINGS[sub_hash]='old'; SETTINGS[sub_links_hash]='old'
SETTINGS[name]='audit-node'; SETTINGS[direct_host]='127.0.0.1'; SETTINGS[server_ip]=''
get_setting() { local key="$1" default="${2:-}"; [ "${FAIL_GET_SETTING:-}" = "$key" ] && return 71; printf '%s' "${SETTINGS[$key]:-$default}"; }
set_setting() { [ "${FAIL_SET_SETTING:-}" = "$1" ] && return 72; SETTINGS[$1]="$2"; }
manager_env_or_setting() { get_setting "$1" "${2:-}"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
print_err() { printf '%s\n' "$*" >&2; }; print_warn() { :; }; print_ok() { :; }
ok() { PASS=$((PASS+1)); printf 'ok %d - %s\n' "$PASS" "$*"; }
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected <$1>, got <$2>"; ok "$3"; }
reject() { if "$@" >/dev/null 2>&1; then fail "must reject: $*"; fi; }

[ "$(sub_private_dir)" = "$BASE_DIR/sub-private" ] && [ "$(sub_public_dir)" = "$BASE_DIR/sub-public" ] && [ "$(sub_migration_marker)" = "$BASE_DIR/sub-migration-v2" ] || fail 'subscription roots are not BASE_DIR siblings'
[[ "$(sub_private_dir)" != "$BASE_DIR/data"/* && "$(sub_public_dir)" != "$BASE_DIR/data"/* ]] || fail 'roots are inside data'
sub_prepare_dirs || fail 'sub_prepare_dirs'
[ "$(stat -c %a "$(sub_private_dir)")" = 700 ] && [ "$(stat -c %a "$(sub_public_dir)")" = 755 ] || fail 'directory modes'
ok 'private/public siblings are outside data and correctly permissioned'

sub_mode=temp; sub_read_token=''; sub_report_token=''; sub_token="${SETTINGS[sub_token]}"
unset sub_mode; FAIL_GET_SETTING=sub_mode; reject sub_mode; unset FAIL_GET_SETTING; sub_mode=invalid; reject sub_mode; sub_mode=temp; ok 'mode read errors and invalid modes fail closed'
iter_node_tags() { printf 'alpha\nbeta\n'; }
build_share_link() { printf 'vless://%s' "$1"; }
sub_build_file || fail 'sub_build_file'
token="$(sub_temp_token)"; public_file="$(sub_public_dir)/$token.txt"
[ -s "$public_file" ] && [ "$(stat -c %a "$public_file")" = 644 ] || fail 'public payload missing/mode wrong'
[ "$(stat -c %a "$(sub_file)")" = 600 ] || fail 'private payload mode wrong'
old_public="$(<"$public_file")"
iter_node_tags() { printf 'alpha\n'; return 71; }
reject sub_build_file
assert_eq "$old_public" "$(<"$public_file")" 'iterator error preserves public content'
iter_node_tags() { printf 'alpha\nbeta\n'; }
build_share_link() { [ "$1" = beta ] && return 72; printf 'vless://%s' "$1"; }
reject sub_build_file
assert_eq "$old_public" "$(<"$public_file")" 'link error preserves public content'
build_share_link() { printf 'vless://%s' "$1"; }
ok 'publication aborts on iterator and link failures'

# Generated HTTP implementation, bound only to 127.0.0.1.
sub_http_start || { cat "$(sub_http_log)" >&2; fail 'sub_http_start'; }
HTTP_PID_FILE="$(sub_http_pid_file)"; HTTP_PORT="$(sub_local_port)"
port="$(sub_local_port)"
status="$(curl -q -sS --max-time 3 -o "$TEST_ROOT/body" -w '%{http_code}' "http://127.0.0.1:$port/$token.txt")"
assert_eq 200 "$status" 'exact randomized path serves payload'
[ "$(<"$TEST_ROOT/body")" = "$(<"$public_file")" ] || fail 'served payload mismatch'
# darkhttpd rejects ENOTDIR with 500 and encoded traversal with 400; the
# Python backend uses 404. Neither rejection may disclose the token payload.
for path in / /no.txt /old-token.txt /payload.txt /links.txt /$token.txt/extra /%2e%2e/$token.txt; do
  status="$(curl -q --path-as-is -sS --max-time 3 -o "$TEST_ROOT/rejected-body" -w '%{http_code}' "http://127.0.0.1:$port$path")"
  if command -v darkhttpd >/dev/null 2>&1; then
    case "$path:$status" in
      "/%2e%2e/$token.txt:400"|"/$token.txt/extra:500"|*:404) ;;
      *) fail "unexpected darkhttpd rejection $path: $status" ;;
    esac
  else
    [ "$status" = 404 ] || fail "unexpected endpoint response $path: $status"
  fi
  [[ "$(<"$TEST_ROOT/rejected-body")" != *"$old_public"* ]] || fail "rejected path disclosed payload: $path"
done
status="$(curl -q --path-as-is -sS --max-time 3 -o "$TEST_ROOT/query-body" -w '%{http_code}' "http://127.0.0.1:$port/$token.txt?x=1")"
if command -v darkhttpd >/dev/null 2>&1; then
  [ "$status" = 200 ] && cmp -s "$TEST_ROOT/query-body" "$public_file" || fail 'darkhttpd token path with query must serve exactly public payload'
else
  [ "$status" = 404 ] || fail 'Python exact request target must reject query'
  [[ "$(<"$TEST_ROOT/query-body")" != *"$old_public"* ]] || fail 'query rejection disclosed payload'
fi
ok 'backend-specific rejection codes preserve token-path and payload boundaries'
headers="$(curl -q -sS -I --max-time 3 "http://127.0.0.1:$port/$token.txt")"
[[ "$headers" == *'Content-Length:'* && "$headers" == *'Cache-Control: no-store'* ]] || fail 'HTTP headers incomplete'
if command -v darkhttpd >/dev/null 2>&1; then
  [[ "$headers" == *'Content-Type: text/plain'* ]] || fail 'darkhttpd content type must be plain text'
else
  [[ "$headers" == *'Content-Type: text/plain; charset=utf-8'* ]] || fail 'Python content type must include UTF-8 charset'
fi
ok 'loopback server serves exact token path and rejects listing/traversal'

# Exercise the Python fallback even on hosts where darkhttpd is installed.
public="$(sub_public_dir)"
python_port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
MM_SUB_HTTP_TOKEN="$token" python3 -c "$(sub_http_python_code)" "$python_port" "$public" >>"$TEST_ROOT/python-http.log" 2>&1 & python_pid=$!; CLEANUP_PIDS+=("$python_pid")
python_ready=0
for _ in {1..30}; do
  if curl -q -fsS --max-time 1 -o "$TEST_ROOT/python-body" "http://127.0.0.1:$python_port/$token.txt"; then python_ready=1; break; fi
  kill -0 "$python_pid" 2>/dev/null || break
  sleep .1
done
[ "$python_ready" = 1 ] || { cat "$TEST_ROOT/python-http.log" >&2; fail 'Python fallback readiness'; }
for _ in 1 2 3; do
  status="$(curl -q -sS --max-time 2 -o "$TEST_ROOT/python-body" -w '%{http_code}' "http://127.0.0.1:$python_port/$token.txt")"
  assert_eq 200 "$status" 'Python fallback survives repeated real requests'
  cmp -s "$TEST_ROOT/python-body" "$public_file" || fail 'Python fallback response mismatch'
done
# Keep an accepted peer open without sending HTTP bytes; the server must time it out.
python3 -c 'import socket,sys,time;s=socket.create_connection(("127.0.0.1",int(sys.argv[1])));time.sleep(7);s.close()' "$python_port" & stalled_pid=$!; CLEANUP_PIDS+=("$stalled_pid")
sleep 5.2
status="$(curl -q -sS --max-time 2 -o "$TEST_ROOT/python-recovered" -w '%{http_code}' "http://127.0.0.1:$python_port/$token.txt")"
assert_eq 200 "$status" 'Python fallback recovers after timed-out stalled connection'
cmp -s "$TEST_ROOT/python-recovered" "$public_file" || fail 'Python fallback recovery payload mismatch'
wait "$stalled_pid" || fail 'stalled test client did not finish within its bound'
ok 'synchronous Python fallback times out stalled clients and resumes serving'

# Refuse a symlinked public root and token payload, without following the latter.
public="$(sub_public_dir)"; /bin/mv "$public" "$TEST_ROOT/public-real"; ln -s "$TEST_ROOT/public-real" "$public"
reject sub_prepare_dirs
rm "$public"; /bin/mv "$TEST_ROOT/public-real" "$public"
rm -f "$public_file"; printf 'outside\n' >"$TEST_ROOT/outside"; ln -s "$TEST_ROOT/outside" "$public_file"
reject sub_build_file
assert_eq outside "$(<"$TEST_ROOT/outside")" 'symlink target remains untouched'
rm -f "$public_file"; sub_build_file || fail 'rebuild after symlink test'
ok 'symlinked root/payload rejected without following target'
managed_pid_stop_file "$HTTP_PID_FILE" sub_http_matches "$HTTP_PORT" || fail 'stop initial HTTP server'
HTTP_PID_FILE=""; HTTP_PORT=""

# Legacy migration: actual old python listener is stopped only when fully identified.
legacy="$TEST_ROOT/legacy"; mkdir -p "$legacy/sub" "$legacy/run"; printf 'legacy\n' >"$legacy/sub/index.html"
BASE_DIR="$legacy"; RUNTIME_DIR="$legacy/run"; LOG_DIR="$legacy/log"; mkdir -p "$LOG_DIR"
SETTINGS[sub_port]="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
SETTINGS[sub_domain]='legacy.trycloudflare.com'; SETTINGS[sub_temp_domain]=''
python3 -m http.server "${SETTINGS[sub_port]}" --bind 127.0.0.1 --directory "$BASE_DIR/sub" >>"$(sub_http_log)" 2>&1 & legacy_pid=$!; CLEANUP_PIDS+=("$legacy_pid")
for _ in {1..50}; do kill -0 "$legacy_pid" 2>/dev/null && curl -q -fsS --max-time 1 "http://127.0.0.1:${SETTINGS[sub_port]}/" >/dev/null 2>&1 && break; sleep .05; done
LOCK_HELD=true; LOCK_OWNER_PID="$BASHPID"; sub_migrate || fail 'legacy migration'
[ ! -e "$BASE_DIR/sub" ] || fail 'old document root remains'
for _ in {1..50}; do kill -0 "$legacy_pid" 2>/dev/null || break; sleep .05; done
kill -0 "$legacy_pid" 2>/dev/null && fail 'verified legacy server still alive'
assert_eq legacy.trycloudflare.com "${SETTINGS[sub_temp_domain]}" 'old tunnel domain retained for temp mode'
assert_eq '' "${SETTINGS[sub_domain]}" 'old tunnel domain removed from Worker setting'
first_token="$(sub_temp_token)"; mkdir -p "$BASE_DIR/sub"; printf keep >"$BASE_DIR/sub/sentinel"
sub_migrate || fail 'repeat migration'
assert_eq "$first_token" "$(sub_temp_token)" 'repeat does not rotate token'
[ -f "$BASE_DIR/sub/sentinel" ] || fail 'repeat migration touched old path'
ok 'migration terminates verified listener and is idempotent'

worker="$TEST_ROOT/worker"; mkdir -p "$worker"; BASE_DIR="$worker"; RUNTIME_DIR="$TEST_ROOT/worker-run"; mkdir -p "$RUNTIME_DIR"; LOG_DIR="$TEST_ROOT"
SETTINGS[sub_domain]='https://worker.example.test'; SETTINGS[sub_temp_domain]=''; LOCK_HELD=true; LOCK_OWNER_PID="$BASHPID"
sub_migrate || fail 'Worker domain migration'
assert_eq 'https://worker.example.test' "${SETTINGS[sub_domain]}" 'custom Worker domain preserved'
ok 'migration preserves custom Worker domain'

sub_mode=worker; sub_domain='worker.example.test'; sub_machine='audit-node'
sub_read_token='READ_TOKEN_0123456789abcdefghijkl'; sub_report_token='REPORT_TOKEN_0123456789abcdefghijk'
sub_token='legacy-shared-token-should-never-be-used'
assert_eq 'https://worker.example.test/sub/audit-node/READ_TOKEN_0123456789abcdefghijkl' "$(sub_worker_url)" 'read URL uses https and dedicated read token'
for bad in 'http://worker.example.test' 'https://worker.example.test/path' 'https://user@worker.example.test' 'https://worker.example.test?x=1' 'https://worker.example.test#frag' 'https://worker.example.test:0' 'https://worker..example.test'; do reject sub_domain_valid "$bad"; done
sub_report_token='legacy-shared-token-should-never-be-used'; reject sub_report_token
sub_report_token='READ_TOKEN_0123456789abcdefghijkl'; reject sub_report_token
sub_report_token='REPORT_TOKEN_0123456789abcdefghijk'; sub_domain='http://worker.example.test'; reject sub_worker_url
sub_domain='worker.example.test'
ok 'Worker URL validates HTTPS origin and rejects legacy/shared credentials'

# A curl function records only its config and returns a fake HTTP 200; never egress.
BASE_DIR="$TEST_ROOT/report"; RUNTIME_DIR="$TEST_ROOT/report-run"; LOG_DIR="$TEST_ROOT"; mkdir -p "$RUNTIME_DIR"; sub_prepare_dirs
printf 'vless://test\n' >"$(sub_file)"; printf 'vless://test\n' >"$(sub_links_file)"; chmod 600 "$(sub_file)" "$(sub_links_file)"
CURL_CALLS_FILE="$TEST_ROOT/curl-calls"; printf 0 >"$CURL_CALLS_FILE"
curl() {
  local output='' cfg='' prev='' arg
  for arg in "$@"; do
    if [ "$prev" = --output ]; then output="$arg"; fi
    if [ "$prev" = --config ]; then cfg="$arg"; fi
    prev="$arg"
  done
  [ -n "$output" ] && [ -n "$cfg" ] && [ "$(stat -c %a "$cfg")" = 600 ] || return 90
  grep -F 'url = "https://worker.example.test/api/v1/report/audit-node"' "$cfg" >/dev/null || return 91
  grep -Fx 'request = "POST"' "$cfg" >/dev/null || return 92
  grep -F "Authorization: Bearer ${sub_report_token}" "$cfg" >/dev/null || return 93
  ! grep -F "$sub_read_token" "$cfg" >/dev/null || return 94
  ! grep -F "$sub_token" "$cfg" >/dev/null || return 95
  case " $* " in *' --proto =https '*) ;; *) return 96 ;; esac
  printf ok >"$output"; printf 200; printf '%s\n' "$(( $(<"$CURL_CALLS_FILE") + 1 ))" >"$CURL_CALLS_FILE"
}
sub_report || fail 'stubbed Worker report'
assert_eq 1 "$(<"$CURL_CALLS_FILE")" 'valid report invoked local curl stub once'
assert_eq 'https://worker.example.test/sub/audit-node/READ_TOKEN_0123456789abcdefghijkl' "$(<"$(sub_url_file)")" 'stored URL contains read token only'
[ -z "$(find "$(sub_private_dir)" -maxdepth 1 -type f \( -name '.curl.*' -o -name '.response.*' \) -print -quit)" ] || fail 'temporary config/response remains'
[ "${SETTINGS[sub_hash]}" != old ] && [ "${SETTINGS[sub_links_hash]}" != old ] || fail 'successful report hashes not stored'
ok 'report credentials remain in private config and are cleaned'

sub_read_token='legacy-shared-token-should-never-be-used'; reject sub_report; assert_eq 1 "$(<"$CURL_CALLS_FILE")" 'legacy read token rejected before curl'
sub_read_token='READ_TOKEN_0123456789abcdefghijkl'; sub_report_token='READ_TOKEN_0123456789abcdefghijkl'; reject sub_report; assert_eq 1 "$(<"$CURL_CALLS_FILE")" 'equal tokens rejected before curl'
sub_report_token='REPORT_TOKEN_0123456789abcdefghijk'; sub_domain='http://worker.example.test'; reject sub_report; assert_eq 1 "$(<"$CURL_CALLS_FILE")" 'HTTP origin rejected before curl'
ok 'invalid Worker settings never contact external services'

# Migration failures use independent roots so a valid prior marker cannot mask them.
new_migration() {
  local name="$1"
  BASE_DIR="$TEST_ROOT/$name"; LOG_DIR="$TEST_ROOT/$name-log"; RUNTIME_DIR="$TEST_ROOT/$name-run"
  mkdir -p "$BASE_DIR/sub" "$LOG_DIR" "$RUNTIME_DIR"
  SETTINGS[sub_domain]="worker.example.test"; SETTINGS[sub_temp_domain]=""
  LOCK_HELD=true; LOCK_OWNER_PID="$BASHPID"
}
new_migration migration-log-error
rmdir "$LOG_DIR"; printf blocked >"$LOG_DIR"
reject sub_migrate
[ -d "$BASE_DIR/sub" ] && [ ! -e "$(sub_migration_marker)" ] || fail "log directory error changed legacy state"
ok "migration directory preparation errors fail before deleting legacy data"
new_migration migration-setting-read
FAIL_GET_SETTING=sub_domain; reject sub_migrate; unset FAIL_GET_SETTING
[ ! -e "$(sub_migration_marker)" ] || fail "setting read error marked migration complete"
ok "migration setting read errors do not mark completion"
new_migration migration-setting-write
FAIL_SET_SETTING=sub_url; reject sub_migrate; unset FAIL_SET_SETTING
[ ! -e "$(sub_migration_marker)" ] || fail "setting write error marked migration complete"
ok "migration setting write errors do not mark completion"
new_migration migration-marker-error
mv() { local target; for target; do :; done; [ "$target" = "$(sub_migration_marker)" ] && return 73; command mv "$@"; }
reject sub_migrate
unset -f mv
[ ! -e "$(sub_migration_marker)" ] && [ -z "$(find "$BASE_DIR" -maxdepth 1 -name '.sub-migration.*' -print -quit)" ] || fail "marker error left false completion or staging"
ok "migration marker rename failure cleans staging and returns failure"
new_migration migration-marker-symlink
printf keep >"$TEST_ROOT/marker-target"; ln -s "$TEST_ROOT/marker-target" "$(sub_migration_marker)"
reject sub_migrate
[ "$(<"$TEST_ROOT/marker-target")" = keep ] && [ -d "$BASE_DIR/sub" ] || fail "marker symlink target or legacy data modified"
ok "migration refuses symlink completion marker"

# A real unrelated listener on the configured port must survive both migration and failed startup.
unset -f curl
new_migration migration-unrelated
unrelated="$TEST_ROOT/unrelated"; mkdir -p "$unrelated"; printf "unrelated\n" >"$unrelated/index.html"
SETTINGS[sub_port]="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
python3 -m http.server "${SETTINGS[sub_port]}" --bind 127.0.0.1 --directory "$unrelated" >>"$(sub_http_log)" 2>&1 & unrelated_pid=$!; CLEANUP_PIDS+=("$unrelated_pid")
for _ in {1..50}; do curl -q -fsS --max-time 1 "http://127.0.0.1:${SETTINGS[sub_port]}/" >/dev/null 2>&1 && break; sleep .05; done
printf "%s\n" "$unrelated_pid" >"$(sub_http_pid_file)"
sub_migrate || fail "migration with unrelated listener"
kill -0 "$unrelated_pid" 2>/dev/null || fail "migration stopped unrelated listener"
sub_mode=temp; sub_build_file || fail "build for occupied-port test"
reject sub_http_start
kill -0 "$unrelated_pid" 2>/dev/null || fail "failed startup stopped unrelated listener"
assert_eq unrelated "$(curl -q -fsS --max-time 2 "http://127.0.0.1:${SETTINGS[sub_port]}/")" "unmatched listener survives migration and occupied-port startup"
ok "occupied port fails readiness without signalling unrelated process"
printf '1..%d\nPASS %d subscription audit groups\n' "$PASS" "$PASS"
