#!/usr/bin/env bash
# Offline installer audit. All candidates and service/unit effects are temporary.
# shellcheck disable=SC1091,SC2015,SC2016,SC2153,SC2317
set -eEuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf -- "${TEMP}"' EXIT
export BASE_DIR="${TEMP}/etc" LIB_DIR="${TEMP}/lib" INSTALL_BIN="${TEMP}/bin/mm"
export MIHOMO_BIN="${TEMP}/bin/mihomo" MTP_BIN="${TEMP}/bin/mtp" CLOUDFLARED_BIN="${TEMP}/bin/cloudflared"
export LOCK_ROOT="${TEMP}/locks" LOCK_FILE="${TEMP}/locks/mm.lock" LOCK_TIMEOUT=0
export CONFIG_FILE="${BASE_DIR}/config.yaml" NODES_FILE="${BASE_DIR}/nodes.json"
export SECRETS_FILE="${BASE_DIR}/secrets.json" SETTING_FILE="${BASE_DIR}/settings.json"
export CERT_DIR="${BASE_DIR}/certs" UPSTREAM_ENV="${LIB_DIR}/upstream.env"
export WATCHDOG_TARGET="${BASE_DIR}/watchdog.sh" MM_TEST_MODE=1
mkdir -p "${BASE_DIR}" "${LIB_DIR}" "${TEMP}/bin" "${LOCK_ROOT}"
# shellcheck source=../mm.sh
. "${ROOT}/mm.sh"
# Redirect every unit path before invoking production transaction functions.
SYSTEMD_SERVICE_FILE="${TEMP}/units/mm.service"
SYSTEMD_WATCHDOG_SERVICE_FILE="${TEMP}/units/watchdog.service"
SYSTEMD_WATCHDOG_TIMER_FILE="${TEMP}/units/watchdog.timer"
export OPENRC_SERVICE_FILE="${TEMP}/units/openrc-mm"
N=0
fail_test() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { N=$((N + 1)); printf 'ok %s - %s\n' "${N}" "$*"; }
reject() { local label="$1"; shift; if "$@" >"${TEMP}/rejected.out" 2>"${TEMP}/rejected.err"; then fail_test "unexpected success: ${label}"; fi; ok "${label}"; }
assert_file() { [ -f "$1" ] || fail_test "missing expected file: $1"; }
assert_text() { [ "$(<"$1")" = "$2" ] || fail_test "unexpected contents: $1"; }
make_candidate() {
  local root="$1" version="$2" path digest
  rm -rf -- "$root"; mkdir -p "$root/lib" "$root/metadata" "$root/scripts"
  chmod 0755 "$root" "$root/lib" "$root/metadata" "$root/scripts"
  printf 'v%s\n' "$version" >"$root/VERSION"
  printf '# temporary candidate %s\n' "$version" >"$root/README.md"
  printf '#!/usr/bin/env bash\nSCRIPT_VERSION="%s"\nREPO_OWNER="famintt"\n' "$version" >"$root/mm.sh"
  printf '#!/usr/bin/env bash\nSCRIPT_VERSION="%s"\n' "$version" >"$root/mtp.sh"
  printf '#!/usr/bin/env bash\n: watchdog %s\n' "$version" >"$root/scripts/watchdog.sh"
  printf '#!/usr/bin/env bash\nMM_MODULES=(env)\n' >"$root/lib/env.sh"
  printf 'REPO_OWNER="famintt"\n' >"$root/metadata/upstream.env"
  chmod 0755 "$root/mm.sh" "$root/mtp.sh" "$root/scripts/watchdog.sh"
  chmod 0644 "$root/README.md" "$root/VERSION" "$root/lib/env.sh" "$root/metadata/upstream.env"
  : >"$root/MANIFEST.sha256"
  while IFS= read -r path; do digest="$(sha256sum "$root/$path" | awk '{print $1}')"; printf '%s  %s\n' "$digest" "$path" >>"$root/MANIFEST.sha256"; done < <(candidate_payload_paths "$root" | LC_ALL=C sort)
  chmod 0644 "$root/MANIFEST.sha256"
}
make_manifest() {
  local root="$1" path digest
  : >"$root/MANIFEST.sha256"
  while IFS= read -r path; do digest="$(sha256sum "$root/$path" | awk '{print $1}')"; printf '%s  %s\n' "$digest" "$path" >>"$root/MANIFEST.sha256"; done < <(candidate_payload_paths "$root" | LC_ALL=C sort)
  chmod 0644 "$root/MANIFEST.sha256"
}
make_candidate "${TEMP}/candidate" 2.0.0
CANDIDATE="${TEMP}/candidate"
validate_project_candidate "$CANDIDATE" v2.0.0 >/dev/null 2>&1 || fail_test 'valid candidate rejected'
ok 'complete candidate passes inventory, syntax, modes, and exact manifest'
printf 'if then\n' >>"$CANDIDATE/lib/env.sh"; make_manifest "$CANDIDATE"
reject 'syntax error is rejected even with recomputed matching manifest' validate_project_candidate "$CANDIDATE" v2.0.0
make_candidate "$CANDIDATE" 2.0.0
find_failure() ( find() { return 71; }; validate_project_candidate "$CANDIDATE" v2.0.0 )
reject 'failed find enumeration cannot masquerade as an empty valid inventory' find_failure
# Create tar headers locally. The validator runs before extraction, and no extraction is performed here.
python3 - "${CANDIDATE}" "${TEMP}" <<'PY'
import io,sys,tarfile
from pathlib import Path
src=Path(sys.argv[1]); out=Path(sys.argv[2]); root='mihomo-manager-v2.0.0'
def pack(path,attack=None):
    with tarfile.open(path,'w:gz') as tf:
        d=tarfile.TarInfo(root+'/'); d.type=tarfile.DIRTYPE; d.mode=0o755; tf.addfile(d)
        for name in ['lib','metadata','scripts']:
            d=tarfile.TarInfo(root+'/'+name+'/'); d.type=tarfile.DIRTYPE; d.mode=0o755; tf.addfile(d)
            for p in sorted((src/name).iterdir()):
                b=p.read_bytes(); x=tarfile.TarInfo(root+'/'+name+'/'+p.name); x.mode=p.stat().st_mode&0o777; x.size=len(b); tf.addfile(x,io.BytesIO(b))
        for name in ['VERSION','README.md','mm.sh','mtp.sh','MANIFEST.sha256']:
            p=src/name; b=p.read_bytes(); x=tarfile.TarInfo(root+'/'+name); x.mode=p.stat().st_mode&0o777; x.size=len(b); tf.addfile(x,io.BytesIO(b))
        if attack=='traversal':
            x=tarfile.TarInfo(root+'/../escaped'); b=b'x'; x.size=1; x.mode=0o644; tf.addfile(x,io.BytesIO(b))
        elif attack=='symlink':
            x=tarfile.TarInfo(root+'/lib/evil.sh'); x.type=tarfile.SYMTYPE; x.linkname='/tmp/mm-audit-escape'; x.mode=0o777; tf.addfile(x)
for name,attack in [('valid',None),('traversal','traversal'),('symlink','symlink')]: pack(out/(name+'.tgz'),attack)
PY
validate_release_archive "${TEMP}/valid.tgz" v2.0.0 || fail_test 'valid archive header rejected'
ok 'valid local archive passes pre-extraction header validation'
reject 'archive traversal is rejected before extraction' validate_release_archive "${TEMP}/traversal.tgz" v2.0.0
reject 'archive symlink is rejected before extraction' validate_release_archive "${TEMP}/symlink.tgz" v2.0.0
[ ! -e "${TEMP}/escaped" ] || fail_test 'archive validation created traversal target'
ok 'pre-extraction archive rejection created no escaped path'
# Service, state, systemd, and watchdog operations below are controlled stubs.
command_exists() { [ "$1" = crontab ] || command -v "$1" >/dev/null 2>&1; }
systemd_available() { return 0; }
openrc_available() { return 1; }
SERVICE_ACTIVE=false; SERVICE_ENABLED=false
WATCHDOG_SERVICE_ACTIVE=false; WATCHDOG_SERVICE_ENABLED=false
WATCHDOG_TIMER_ACTIVE=false; WATCHDOG_TIMER_ENABLED=false
FAIL_SYSTEMCTL_MATCH=""; FAIL_SYSTEMCTL_ONCE=false; FAIL_DAEMON_RELOAD_ONCE=false
FAIL_START_VERSION=""; FAIL_OLD_START=false; FAIL_STOP_SERVICE=false
CRONTAB_CONTENT=""; EVENTS="${TEMP}/events"
systemctl() {
  local op="${1:-}" arg unit="" args="$*"
  for arg in "$@"; do unit="$arg"; done
  printf 'systemctl %s\n' "$*" >>"$EVENTS"
  if [ -n "$FAIL_SYSTEMCTL_MATCH" ] && [ "$args" = "$FAIL_SYSTEMCTL_MATCH" ] && [ "$FAIL_SYSTEMCTL_ONCE" = true ]; then FAIL_SYSTEMCTL_ONCE=false; return 1; fi
  if [ "$op" = daemon-reload ] && [ "$FAIL_DAEMON_RELOAD_ONCE" = true ]; then FAIL_DAEMON_RELOAD_ONCE=false; return 1; fi
  case "$op" in
    is-active) case "$unit" in "$SERVICE_NAME") [ "$SERVICE_ACTIVE" = true ];; "$WATCHDOG_SERVICE_NAME") [ "$WATCHDOG_SERVICE_ACTIVE" = true ];; "$WATCHDOG_TIMER_NAME") [ "$WATCHDOG_TIMER_ACTIVE" = true ];; *) return 3;; esac;;
    is-enabled) case "$unit" in "$SERVICE_NAME") [ "$SERVICE_ENABLED" = true ];; "$WATCHDOG_SERVICE_NAME") [ "$WATCHDOG_SERVICE_ENABLED" = true ];; "$WATCHDOG_TIMER_NAME") [ "$WATCHDOG_TIMER_ENABLED" = true ];; *) return 1;; esac;;
    start) case "$unit" in "$SERVICE_NAME") SERVICE_ACTIVE=true;; "$WATCHDOG_SERVICE_NAME") WATCHDOG_SERVICE_ACTIVE=true;; "$WATCHDOG_TIMER_NAME") WATCHDOG_TIMER_ACTIVE=true;; esac;;
    stop) case "$unit" in "$SERVICE_NAME") SERVICE_ACTIVE=false;; "$WATCHDOG_SERVICE_NAME") WATCHDOG_SERVICE_ACTIVE=false;; "$WATCHDOG_TIMER_NAME") WATCHDOG_TIMER_ACTIVE=false;; esac;;
    enable) case "$unit" in "$SERVICE_NAME") SERVICE_ENABLED=true; [ "${2:-}" != --now ] || SERVICE_ACTIVE=true;; "$WATCHDOG_SERVICE_NAME") WATCHDOG_SERVICE_ENABLED=true; [ "${2:-}" != --now ] || WATCHDOG_SERVICE_ACTIVE=true;; "$WATCHDOG_TIMER_NAME") WATCHDOG_TIMER_ENABLED=true; [ "${2:-}" != --now ] || WATCHDOG_TIMER_ACTIVE=true;; esac;;
    disable) case "$unit" in "$SERVICE_NAME") SERVICE_ENABLED=false; [ "${2:-}" != --now ] || SERVICE_ACTIVE=false;; "$WATCHDOG_SERVICE_NAME") WATCHDOG_SERVICE_ENABLED=false; [ "${2:-}" != --now ] || WATCHDOG_SERVICE_ACTIVE=false;; "$WATCHDOG_TIMER_NAME") WATCHDOG_TIMER_ENABLED=false; [ "${2:-}" != --now ] || WATCHDOG_TIMER_ACTIVE=false;; esac;;
    *) return 0;;
  esac
}
crontab() {
  case "${1:-}" in
    -l) [ -n "$CRONTAB_CONTENT" ] || return 1; printf '%s\n' "$CRONTAB_CONTENT";;
    -r) CRONTAB_CONTENT="";;
    *) CRONTAB_CONTENT="$(<"$1")";;
  esac
}
stop_service() { printf 'stop-service\n' >>"$EVENTS"; SERVICE_ACTIVE=false; [ "$FAIL_STOP_SERVICE" != true ]; }
start_service() {
  printf 'start-service-%s\n' "$SCRIPT_VERSION" >>"$EVENTS"
  if [ "$SCRIPT_VERSION" = "$FAIL_START_VERSION" ] || { [ "$SCRIPT_VERSION" != 2.0.0 ] && [ "$FAIL_OLD_START" = true ]; }; then return 1; fi
  SERVICE_ACTIVE=true
  [ "$SCRIPT_VERSION" != 2.0.0 ] || printf 'new-state-%s\n' "$SCRIPT_VERSION" >"$CONFIG_FILE"
}

stop_all_argo_nodes() { printf 'stop-all-argo\n' >>"$EVENTS"; }
restart_all_argo_nodes() { printf 'restart-argo\n' >>"$EVENTS"; }
stop_argo_node() { printf 'stop-argo-%s\n' "$1" >>"$EVENTS"; }
sub_migrate() { printf 'sub-migrate\n' >>"$EVENTS"; }
sub_stop() { printf 'sub-stop\n' >>"$EVENTS"; }
socks5_whitelist_cleanup() { printf 'whitelist-cleanup\n' >>"$EVENTS"; }
ensure_sub() { return 0; }
sanitize_permissions() { return 0; }
create_systemd_units() { mkdir -p "${TEMP}/units"; printf 'service-%s\n' "$SCRIPT_VERSION" >"$SYSTEMD_SERVICE_FILE"; printf 'watchdog-%s\n' "$SCRIPT_VERSION" >"$SYSTEMD_WATCHDOG_SERVICE_FILE"; printf 'timer-%s\n' "$SCRIPT_VERSION" >"$SYSTEMD_WATCHDOG_TIMER_FILE"; }
ensure_watchdog_enabled() { WATCHDOG_TIMER_ENABLED=true; WATCHDOG_TIMER_ACTIVE=true; WATCHDOG_SERVICE_ENABLED=true; WATCHDOG_SERVICE_ACTIVE=true; }
backup_state() { local d="${TEMP}/backup-${BASHPID}"; mkdir -p "$d"; cp "$CONFIG_FILE" "$d/config.yaml"; printf '%s' "$d"; }
restore_state_backup() { cp "$1/config.yaml" "$CONFIG_FILE"; }
setup_live() {
  rm -rf -- "$BASE_DIR" "$LIB_DIR" "${TEMP}/units" "${LIB_DIR}.mm-stage."* "${LIB_DIR}.mm-old."*; mkdir -p "$BASE_DIR" "$LIB_DIR" "${TEMP}/units"
  printf 'MM_MODULES=(env)\n' >"$LIB_DIR/env.sh"; printf ': old-upstream\n' >"$UPSTREAM_ENV"; printf 'old-lib-version\n' >"$LIB_DIR/VERSION"
  printf 'old-mm\n' >"$INSTALL_BIN"; printf 'old-mihomo\n' >"$MIHOMO_BIN"; printf 'old-mtp\n' >"$MTP_BIN"; printf 'old-watchdog\n' >"$WATCHDOG_TARGET"
  printf 'old-service\n' >"$SYSTEMD_SERVICE_FILE"; printf 'old-watchdog-unit\n' >"$SYSTEMD_WATCHDOG_SERVICE_FILE"; printf 'old-timer\n' >"$SYSTEMD_WATCHDOG_TIMER_FILE"; printf 'stable-state\n' >"$CONFIG_FILE"
  chmod 0644 "$LIB_DIR/env.sh" "$LIB_DIR/VERSION" "$UPSTREAM_ENV"; chmod 0755 "$INSTALL_BIN" "$MIHOMO_BIN" "$MTP_BIN" "$WATCHDOG_TARGET"
  SCRIPT_VERSION=1.2.7; : >"$EVENTS"; SERVICE_ACTIVE=true; SERVICE_ENABLED=true; WATCHDOG_SERVICE_ACTIVE=true; WATCHDOG_SERVICE_ENABLED=true; WATCHDOG_TIMER_ACTIVE=true; WATCHDOG_TIMER_ENABLED=true; FAIL_START_VERSION=""; FAIL_OLD_START=false; FAIL_STOP_SERVICE=false; FAIL_SYSTEMCTL_MATCH=""; FAIL_SYSTEMCTL_ONCE=false; FAIL_DAEMON_RELOAD_ONCE=false; CRONTAB_CONTENT=$'backup-job\n*/5 * * * * '"$WATCHDOG_TARGET"; rm -rf -- "${LIB_DIR}.mm-stage."* "${LIB_DIR}.mm-old."*
}
# Fresh install publication still uses the real transaction/publish/validate helpers.
setup_live; rm -rf -- "$LIB_DIR" "$BASE_DIR" "${TEMP}/units"; mkdir -p "$BASE_DIR"
install_project_candidate "$CANDIDATE" v2.0.0 >/dev/null 2>&1 || fail_test 'isolated publication failed'
assert_text "$INSTALL_BIN" $'#!/usr/bin/env bash\nSCRIPT_VERSION="2.0.0"\nREPO_OWNER="famintt"'
assert_text "$MTP_BIN" $'#!/usr/bin/env bash\nSCRIPT_VERSION="2.0.0"'
assert_text "$WATCHDOG_TARGET" $'#!/usr/bin/env bash\n: watchdog 2.0.0'
assert_text "$UPSTREAM_ENV" 'REPO_OWNER="famintt"'
[ "$(<"$LIB_DIR/VERSION")" = v2.0.0 ] || fail_test 'published version absent'
ok 'project publication updates mm, mtp, watchdog, library, and upstream within temp roots'
# Fail new service start: every previously present project path, unit, and state file rolls back.
setup_live; FAIL_START_VERSION=2.0.0
if install_project_candidate "$CANDIDATE" v2.0.0 >"${TEMP}/rollback.out" 2>&1; then fail_test 'failing candidate unexpectedly installed'; fi
assert_text "$INSTALL_BIN" old-mm; assert_text "$MTP_BIN" old-mtp; assert_text "$WATCHDOG_TARGET" old-watchdog; assert_text "$UPSTREAM_ENV" ': old-upstream'
assert_text "$SYSTEMD_SERVICE_FILE" old-service; assert_text "$SYSTEMD_WATCHDOG_SERVICE_FILE" old-watchdog-unit; assert_text "$SYSTEMD_WATCHDOG_TIMER_FILE" old-timer; assert_text "$CONFIG_FILE" stable-state
[ "$(<"$LIB_DIR/VERSION")" = old-lib-version ] || fail_test 'old lib not restored'
[ "$SERVICE_ACTIVE" = true ] || fail_test 'previously active service not restarted'
[ "$LOCK_HELD" = false ] || fail_test 'transaction leaked owned lock'
compgen -G "${LOCK_ROOT}/.install.*" >/dev/null && fail_test 'complete rollback retained txn unexpectedly'
ok 'failed start restores code, upstream, watchdog, units, state, and prior active service'
# Failed recovery must preserve transaction evidence for manual repair.
setup_live; FAIL_START_VERSION=2.0.0; FAIL_OLD_START=true
if install_project_candidate "$CANDIDATE" v2.0.0 >"${TEMP}/recovery-fail.out" 2>&1; then fail_test 'failed recovery unexpectedly succeeded'; fi
recovery_txn="$(find "$LOCK_ROOT" -maxdepth 1 -type d -name '.install.*' -print -quit)"
[ -n "$recovery_txn" ] && [ -f "$recovery_txn/paths" ] || fail_test 'incomplete recovery evidence deleted'
ok 'incomplete rollback retains transaction directory and saved paths'
# A child process cannot replace/release the parent-held lock; same-owner call retains it.
setup_live; acquire_lock || fail_test 'could not acquire temporary lock'; lock_fd="$LOCK_FD"
( install_project_candidate "$CANDIDATE" v2.0.0 >/dev/null 2>&1 ) && fail_test 'child bypassed held lock'
if flock -n "$LOCK_FILE" true >/dev/null 2>&1; then fail_test 'child released parent-held lock'; fi
[ "$LOCK_HELD" = true ] && [ "$LOCK_FD" = "$lock_fd" ] || fail_test 'child changed parent lock state'
install_project_candidate "$CANDIDATE" v2.0.0 >/dev/null 2>&1 || fail_test 'same owner nested call failed'
[ "$LOCK_HELD" = true ] && [ "$LOCK_FD" = "$lock_fd" ] || fail_test 'nested call released caller lock'
release_lock
ok 'inherited child retains no authority to bypass/release the caller lock'
# Uninstall assertions: scoped process hooks only; failures preserve managed files.
confirm_yes() { return 0; }; remove_net_tune() { return 0; }; iter_node_tags() { printf 'alpha\nbeta\n'; }
setup_live; : >"$EVENTS"; printf 'cloudflared\n' >"$CLOUDFLARED_BIN"
uninstall_project >"${TEMP}/uninstall.out" 2>&1 || fail_test 'successful temp uninstall failed'
[ ! -e "$BASE_DIR" ] && [ ! -e "$LIB_DIR" ] && [ ! -e "$INSTALL_BIN" ] && [ ! -e "$MIHOMO_BIN" ] || fail_test 'managed files remain after uninstall'
assert_file "$MTP_BIN"; assert_file "$CLOUDFLARED_BIN"; assert_file "$LOCK_FILE"
grep -Fxq 'stop-all-argo' "$EVENTS" || fail_test 'bulk instance-scoped stop hook missing'
if grep -Eq '(^| )(killall|pkill)( |$)' "$EVENTS"; then fail_test 'global process killer observed'; fi
ok 'uninstall invokes the bulk instance-scoped stop hook; preserves independent mtp/cloudflared and external lock'
setup_live; stop_service() { printf 'stop-service\n' >>"$EVENTS"; return 1; }
if uninstall_project >"${TEMP}/uninstall-stop-fail.out" 2>&1; then fail_test 'stop failure unexpectedly uninstalled'; fi
assert_file "$INSTALL_BIN"; assert_file "$LIB_DIR/env.sh"; assert_file "$CONFIG_FILE"
ok 'service stop failure preserves installation and state files'
setup_live; unset -f stop_all_argo_nodes; iter_node_tags() { printf 'alpha\nbeta\n'; return 73; }; stop_argo_node() { fail_test 'fallback stopped a node after inventory enumeration failed'; }
if uninstall_project >"${TEMP}/uninstall-scan-fail.out" 2>&1; then fail_test 'node inventory scan failure unexpectedly uninstalled'; fi
assert_file "$INSTALL_BIN"; assert_file "$CONFIG_FILE"
ok 'node inventory scan failure preserves installation and state files'
setup_live; : >"$EVENTS"; FAIL_SYSTEMCTL_MATCH="stop $WATCHDOG_SERVICE_NAME"; FAIL_SYSTEMCTL_ONCE=true
if uninstall_project >"${TEMP}/uninstall-watchdog-stop-fail.out" 2>&1; then fail_test 'partial watchdog stop failure unexpectedly uninstalled'; fi
assert_file "$INSTALL_BIN"; assert_text "$SYSTEMD_SERVICE_FILE" old-service; assert_text "$SYSTEMD_WATCHDOG_SERVICE_FILE" old-watchdog-unit; assert_text "$SYSTEMD_WATCHDOG_TIMER_FILE" old-timer
[ "$SERVICE_ACTIVE" = true ] && [ "$SERVICE_ENABLED" = true ] && [ "$WATCHDOG_SERVICE_ACTIVE" = true ] && [ "$WATCHDOG_SERVICE_ENABLED" = true ] && [ "$WATCHDOG_TIMER_ACTIVE" = true ] && [ "$WATCHDOG_TIMER_ENABLED" = true ] || fail_test 'partial watchdog-stop failure did not restore unit activity/enabled states'
[ "$CRONTAB_CONTENT" = $'backup-job\n*/5 * * * * '"$WATCHDOG_TARGET" ] || fail_test 'partial watchdog-stop failure changed cron'
ok 'partial watchdog stop failure restores unit states, cron, and managed files'
setup_live; : >"$EVENTS"; FAIL_SYSTEMCTL_MATCH="disable --now $WATCHDOG_TIMER_NAME"; FAIL_SYSTEMCTL_ONCE=true
if uninstall_project >"${TEMP}/uninstall-disable-fail.out" 2>&1; then fail_test 'watchdog disable failure unexpectedly uninstalled'; fi
assert_file "$INSTALL_BIN"; assert_text "$SYSTEMD_SERVICE_FILE" old-service; assert_text "$SYSTEMD_WATCHDOG_SERVICE_FILE" old-watchdog-unit; assert_text "$SYSTEMD_WATCHDOG_TIMER_FILE" old-timer
[ "$SERVICE_ACTIVE" = true ] && [ "$SERVICE_ENABLED" = true ] && [ "$WATCHDOG_SERVICE_ACTIVE" = true ] && [ "$WATCHDOG_SERVICE_ENABLED" = true ] && [ "$WATCHDOG_TIMER_ACTIVE" = true ] && [ "$WATCHDOG_TIMER_ENABLED" = true ] || fail_test 'watchdog-disable failure did not restore unit states'
[ "$CRONTAB_CONTENT" = $'backup-job\n*/5 * * * * '"$WATCHDOG_TARGET" ] || fail_test 'watchdog-disable failure changed cron'
ok 'watchdog disable failure restores bytes, unit states, and cron'
setup_live; : >"$EVENTS"; FAIL_DAEMON_RELOAD_ONCE=true
if uninstall_project >"${TEMP}/uninstall-reload-fail.out" 2>&1; then fail_test 'daemon-reload failure unexpectedly uninstalled'; fi
assert_file "$INSTALL_BIN"; assert_text "$SYSTEMD_SERVICE_FILE" old-service; assert_text "$SYSTEMD_WATCHDOG_SERVICE_FILE" old-watchdog-unit; assert_text "$SYSTEMD_WATCHDOG_TIMER_FILE" old-timer
[ "$SERVICE_ACTIVE" = true ] && [ "$SERVICE_ENABLED" = true ] && [ "$WATCHDOG_SERVICE_ACTIVE" = true ] && [ "$WATCHDOG_SERVICE_ENABLED" = true ] && [ "$WATCHDOG_TIMER_ACTIVE" = true ] && [ "$WATCHDOG_TIMER_ENABLED" = true ] || fail_test 'daemon-reload failure did not restore unit states'
[ "$CRONTAB_CONTENT" = $'backup-job\n*/5 * * * * '"$WATCHDOG_TARGET" ] || fail_test 'daemon-reload failure changed cron'
ok 'daemon-reload failure restores removed units byte-for-byte, unit states, and cron'
printf 'PASS: %s isolated installer audit assertions\n' "$N"
