#!/usr/bin/env bash
# MM-16: isolated validation/templates + real Linux argv/PID lifecycle; no host service installation.
# Mocked commands are called indirectly by sourced mtp.sh; malicious strings must stay literal.
# shellcheck disable=SC1091,SC2016,SC2034,SC2317
set -eEuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MTP_TEST_MODE=1
# shellcheck source=../mtp.sh
source "${ROOT_DIR}/mtp.sh"
TEST_DIR="$(mktemp -d /tmp/mm-audit-mtp.XXXXXX)"
PASS=0
CLEANUP_PIDS=()
cleanup() {
  local pid
  for pid in "${CLEANUP_PIDS[@]}"; do kill "${pid}" 2>/dev/null || true; wait "${pid}" 2>/dev/null || true; done
  rm -rf "${TEST_DIR}"
}
trap cleanup EXIT
ok() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "${PASS}" "$*"; }
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected <$1>, got <$2>"; ok "$3"; }
reject() { if "$@" >/dev/null 2>&1; then fail "must reject: $*"; fi; }
MTP_WORKDIR="${TEST_DIR}/mtproxy"
MTP_BIN_DIR="${MTP_WORKDIR}/bin"
MTP_CONF="${MTP_WORKDIR}/go.conf"
MTP_LOG="${MTP_WORKDIR}/mtp.log"
MTP_SYSTEMD_DIR="${TEST_DIR}/systemd"
MTP_OPENRC_DIR="${TEST_DIR}/openrc"
MTP_OPENRC_PIDFILE="${TEST_DIR}/openrc-legacy.pid"
mkdir -p "${MTP_SYSTEMD_DIR}" "${MTP_OPENRC_DIR}"
SECRET=0123456789abcdef0123456789abcdef
DOMAIN=www.apple.com
FULL="ee${SECRET}$(mtp_domain_hex "${DOMAIN}")"
write_conf() {
  local secret="${SECRET}" domain="${DOMAIN}" mode=v4
  mtp_atomic_write "${MTP_CONF}" <<EOF
PORT=28443
SECRET=ee${secret}$(mtp_domain_hex "${domain}")
DOMAIN=${domain}
IP_MODE=${mode}
EOF
}
require_root() { :; }
detect_init_system() { :; }
for val in "${SECRET}" 0123456789ABCDEF0123456789ABCDEF; do mtp_valid_secret "${val}" || fail secret; done
for val in '' abcd "${SECRET}0" '$(touch bad)' "${SECRET};id" $'0123456789abcdef0123456789abcdef\n'; do reject mtp_valid_secret "${val}"; done
ok 'secret accepts exactly 32 hex characters'
for val in a.example.com www.apple.com xn--fiqs8s.example A-B.Example; do mtp_valid_domain "${val}" || fail "domain ${val}"; done
for val in '' localhost .example.com example.com. a..example.com -a.example.com a-.example.com 'a_b.example.com' 'a.com;id' 'https://a.com' '1.2.3.4' $'a.com\nExecStart=id' 'a\x2ecom'; do reject mtp_valid_domain "${val}"; done
long_label="$(printf '%064d' 0)"
reject mtp_valid_domain "${long_label}.example.com"
reject mtp_valid_domain "${long_label:1}.${long_label:1}.${long_label:1}.${long_label:1}.com"
ok 'domain validates label lengths and rejects shell/unit syntax'
for val in 1 65535 0080; do valid_port "${val}" || fail port; done
for val in 0 65536 999999999999999999999 1a '-1'; do reject valid_port "${val}"; done
ok 'port uses bounded decimal parsing including leading zeros'
assert_eq '7gAAAAAAAAAAAAAAAAAAAABhcHBsZS5jb20' "$(mtp_tg_secret 00000000000000000000000000000000 apple.com)" 'Telegram secret byte encoding'
reject mtp_tg_secret "${SECRET}" 'a\x2ecom'
(
  date() { fail 'random_domain must not need GNU date'; }
  for ((i=0; i<25; i++)); do mtp_valid_domain "$(random_domain)" || exit 1; done
) || fail random_domain
ok 'random_domain works without GNU date %N'
mtp_prepare_dirs
assert_eq 700 "$(stat -c %a "${MTP_WORKDIR}")" 'private work directory'
for mode in v4 v6 dual; do
  mtp_build_argv 28443 "${FULL}" "${mode}" || fail argv
  assert_eq 13 "${#MTP_ARGV[@]}" "${mode} exact argv count"
  assert_eq "${FULL}" "${MTP_ARGV[12]}" "${mode} secret is one argument"
done
reject mtp_build_argv 28443 'eeabcd' v4
reject mtp_build_argv 28443 "${FULL};touch ${TEST_DIR}/injected" v4
reject mtp_build_argv 28443 "${FULL}" invalid
write_conf
mtp_load_config || fail config
assert_eq "${SECRET}" "${MTP_CONFIG_SECRET}" 'existing full secret parsed without shell'
assert_eq 600 "$(stat -c %a "${MTP_CONF}")" 'private config file'
# Pre-IP_MODE configurations retain the old v4 default; truncated decoded bytes are rejected.
sed '/^IP_MODE=/d' "${MTP_CONF}" >"${TEST_DIR}/legacy.conf"
mv "${TEST_DIR}/legacy.conf" "${MTP_CONF}"
mtp_load_config || fail 'legacy config without IP_MODE'
assert_eq v4 "${MTP_CONFIG_MODE}" 'legacy config defaults IP mode independently'
reject mtp_valid_full_secret "${FULL}00"
reject mtp_valid_full_secret "${FULL}0a"
reject mtp_valid_full_secret "${FULL}0"
write_conf
# Faulted atomic write retains the complete previous target and cleans its private temporary.
old_hash="$(sha256sum "${MTP_CONF}")"
(
  cat() { printf partial; return 1; }
  reject mtp_atomic_write "${MTP_CONF}" <<<bad
)
assert_eq "${old_hash}" "$(sha256sum "${MTP_CONF}")" 'failed atomic write keeps previous config'
ln -s "${TEST_DIR}/victim" "${MTP_WORKDIR}/link"
reject mtp_atomic_write "${MTP_WORKDIR}/link" <<<bad
[ ! -e "${TEST_DIR}/victim" ] || fail 'symlink target written'
ok 'atomic write refuses symlink targets'
# Native executable checks exact argv and persists as the true PID. No networking.
# Lifecycle fixture only; real mtg interoperability is verified separately with a pinned asset.
command -v cc >/dev/null || fail 'cc required for native process identity fixture'
cat >"${TEST_DIR}/fixture.c" <<'C'
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static volatile sig_atomic_t running=1;
static void stop(int sig) { (void)sig; running=0; }
int main(int argc, char **argv) {
  if(argc==2 && strcmp(argv[1],"--version")==0) { puts("audit native lifecycle fixture"); return 0; }
  if(argc!=14 || strcmp(argv[1],"simple-run") || strcmp(argv[2],"-n") || strcmp(argv[3],"1.1.1.1") || strcmp(argv[10],"-i")) return 23;
  signal(SIGTERM,stop); signal(SIGINT,stop);
  while(running) pause();
  return 0;
}
C
cc -Wall -Wextra -Werror -O2 -o "${MTP_BIN_DIR}/mtg-go" "${TEST_DIR}/fixture.c"
chmod 0700 "${MTP_BIN_DIR}/mtg-go"
# Template calls are captured, never forwarded to host init.
systemctl() { printf '%s\n' "$*" >>"${TEST_DIR}/manager.log"; }
rc-update() { printf 'rc-update %s\n' "$*" >>"${TEST_DIR}/manager.log"; }
rc-service() { printf 'rc-service %s\n' "$*" >>"${TEST_DIR}/manager.log"; }
for init in systemd openrc unknown; do
  INIT_SYSTEM="${init}"
  reject mtp_create_service 28443 "${SECRET};touch ${TEST_DIR}/injected" "${DOMAIN}" v4
  reject mtp_create_service 28443 "${SECRET}" $'a.com\nInjected=yes' v4
  [ ! -e "${TEST_DIR}/injected" ] || fail 'injection executed'
done
ok 'all init create paths reject injected values before template/start'
for init in systemd openrc unknown; do
  INIT_SYSTEM="${init}"
  write_conf
  printf 'SECRET=ee%s\n' "${SECRET};touch ${TEST_DIR}/injected" >>"${MTP_CONF}"
  before="$(sha256sum "${MTP_CONF}")"
  reject mtp_restart
  assert_eq "${before}" "$(sha256sum "${MTP_CONF}")" "${init} restart rejects duplicate/malicious existing secret"
  reject mtp_config_argv
  reject mtp_run_service
  reject mtp_start_process
  write_conf
  printf 'DOMAIN=a.com;id\n' >>"${MTP_CONF}"
  reject mtp_restart
done
ok 'all init restart and native startup validate existing configuration'
for mode in v4 v6 dual; do
  INIT_SYSTEM=unknown
  mtp_create_service 28443 "${SECRET}" "${DOMAIN}" "${mode}" || fail 'start native fixture'
  read -r pid started <"${MTP_WORKDIR}/mtp.pid"
  CLEANUP_PIDS+=("${pid}")
  mtp_pid_matches "${pid}" "${started}" || fail 'true PID/executable/argv identity'
  assert_eq "$(readlink -f "${MTP_BIN_DIR}/mtg-go")" "$(readlink "/proc/${pid}/exe")" "${mode} pid belongs to native executable"
  assert_eq 600 "$(stat -c %a "${MTP_WORKDIR}/mtp.pid")" "${mode} private pidfile"
  assert_eq 600 "$(stat -c %a "${MTP_LOG}")" "${mode} private logfile"
  reject mtp_pid_matches "${pid}" "$((started + 1))"
  # One-number pidfiles can migrate only after full executable + argv validation.
  printf '%s\n' "${pid}" >"${MTP_WORKDIR}/mtp.pid"
  mtp_stop_process || fail 'legacy PID migration'
  wait "${pid}" || true
done
ok 'direct argv startup, PID start-time defense and exact stop across all IP modes'
# systemd's foreground helper must exec, so its job PID becomes the native executable PID.
mtp_run_service >"${TEST_DIR}/foreground.log" 2>&1 & foreground=$!
CLEANUP_PIDS+=("${foreground}")
for ((i=0; i<20; i++)); do
  if mtp_pid_matches "${foreground}"; then break; fi
  sleep 0.05
done
mtp_pid_matches "${foreground}" || fail 'foreground helper did not exec native binary'
kill "${foreground}"; wait "${foreground}" || true
ok 'systemd foreground helper execs native binary at its own PID'
sleep 60 & unrelated=$!; CLEANUP_PIDS+=("${unrelated}")
printf '%s %s\n' "${unrelated}" "$(mtp_pid_start_time "${unrelated}")" >"${MTP_WORKDIR}/mtp.pid"
reject mtp_stop_process
kill -0 "${unrelated}" || fail 'unrelated process killed'
printf '%s\n' -1 >"${MTP_WORKDIR}/mtp.pid"
reject mtp_stop_process
rm "${MTP_WORKDIR}/mtp.pid"
ok 'forged, negative and unrelated PIDs are rejected'
# Even a genuine mtg executable with different valid settings is not this managed instance.
mtp_build_argv 28444 "${FULL}" v4
"${MTP_BIN_DIR}/mtg-go" "${MTP_ARGV[@]}" & other_mtg=$!
CLEANUP_PIDS+=("${other_mtg}")
printf '%s %s\n' "${other_mtg}" "$(mtp_pid_start_time "${other_mtg}")" >"${MTP_WORKDIR}/mtp.pid"
reject mtp_stop_process
kill -0 "${other_mtg}" || fail 'unrelated mtg instance killed'
kill "${other_mtg}"; wait "${other_mtg}" || true
rm "${MTP_WORKDIR}/mtp.pid"
ok 'forged PID of same native executable with different settings is rejected'
# Reproduce the baseline sh -c wrapper: the fixture must remain alive until the child is stopped.
# The legacy shell string is only a test fixture; production never executes such a string.
mtp_config_argv
legacy_command="${MTP_BIN_DIR}/mtg-go ${MTP_ARGV[*]} >>${MTP_LOG} 2>&1"
sh -c "${legacy_command}" & wrapper=$!; CLEANUP_PIDS+=("${wrapper}")
for ((i=0; i<20; i++)); do
  if child="$(mtp_legacy_child "${wrapper}" 2>/dev/null)"; then break; fi
  sleep 0.05
done
# ash can exec the final native command instead of retaining a shell child.
if mtp_pid_matches "$wrapper"; then
  printf 'FIXTURE_META legacy directexec pid=%s exe=%s\n' "$wrapper" "$(readlink "/proc/$wrapper/exe")"
  printf '%s\n' "$wrapper" >"${MTP_WORKDIR}/mtp.pid"
  mtp_stop_process || fail 'optimized legacy direct-exec stop'
  wait "$wrapper" || true
  ok 'optimized legacy command stops only after exact native identity validation'
  printf 'SKIP: retained shell-wrapper migration (shell optimized direct exec)\n'
else
[ -n "${child:-}" ] || fail 'legacy child cannot be located'
CLEANUP_PIDS+=("${child}")
printf '%s\n' "${wrapper}" >"${MTP_WORKDIR}/mtp.pid"
mtp_stop_process || fail 'legacy shell wrapper migration'
wait "${wrapper}" || true
ok 'baseline sh wrapper migrates only after exact command and child identity checks'
fi
# Baseline OpenRC stores a real daemon PID in /run/mtp.pid, outside MTP_WORKDIR.
# Redirect that legacy location too, and confirm restart migrates without invoking the old init script.
mtp_config_argv
"${MTP_BIN_DIR}/mtg-go" "${MTP_ARGV[@]}" & old_openrc=$!
CLEANUP_PIDS+=("${old_openrc}")
printf '%s\n' "${old_openrc}" >"${MTP_OPENRC_PIDFILE}"
INIT_SYSTEM=openrc
mtp_restart || fail 'legacy OpenRC PID migration'
wait "${old_openrc}" || true
[ ! -e "${MTP_OPENRC_PIDFILE}" ] || fail 'legacy OpenRC pidfile remains'
ok 'OpenRC migration stops validated legacy run-directory PID before rewriting template'
write_conf
INIT_SYSTEM=systemd
mtp_restart || fail systemd
assert_eq 600 "$(stat -c %a "${MTP_SYSTEMD_DIR}/mtp.service")" 'systemd unit private from creation'
grep -q '^NoNewPrivileges=true$' "${MTP_SYSTEMD_DIR}/mtp.service" || fail systemd_sandbox
grep -q '^ExecStart=.* run-service$' "${MTP_SYSTEMD_DIR}/mtp.service" || fail validated_entrypoint
if grep -q "${SECRET}" "${MTP_SYSTEMD_DIR}/mtp.service"; then fail 'unit embeds secret'; fi
if command -v systemd-analyze >/dev/null; then
  SYSTEMD_UNIT_PATH="${MTP_SYSTEMD_DIR}:/lib/systemd/system" systemd-analyze verify "${MTP_SYSTEMD_DIR}/mtp.service" || fail systemd_verify
fi
ok 'systemd restart migrates unit to validated foreground exec with sandbox'
INIT_SYSTEM=openrc
mtp_restart || fail openrc
assert_eq 700 "$(stat -c %a "${MTP_OPENRC_DIR}/mtp")" 'OpenRC script private and executable'
sh -n "${MTP_OPENRC_DIR}/mtp"
grep -q 'start-service' "${MTP_OPENRC_DIR}/mtp" || fail openrc_start
if grep -q "${SECRET}" "${MTP_OPENRC_DIR}/mtp"; then fail 'OpenRC embeds secret'; fi
ok 'OpenRC restart migrates to validated entrypoint without shell command_args'
{
  mtp_install_binary() { :; }
  mtp_create_service() { printf '%s\n' "$@" >"${TEST_DIR}/upgrade.args"; }
  mtp_status() { :; }
  mtp_show_info() { :; }
  INIT_SYSTEM=unknown
  mtpt=28443 mtp_domain=www.microsoft.com mtp_secret="" mtp_ip_mode="" mtp_install
  mapfile -t args <"${TEST_DIR}/upgrade.args"
  assert_eq "${SECRET}" "${args[1]}" 'domain-only upgrade preserves secret'
  assert_eq www.microsoft.com "${args[2]}" 'domain-only upgrade applies domain'
  mtpt=28443 mtp_domain="" mtp_secret=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa mtp_ip_mode="" mtp_install
  mapfile -t args <"${TEST_DIR}/upgrade.args"
  assert_eq "${DOMAIN}" "${args[2]}" 'secret-only upgrade preserves domain'
  assert_eq aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "${args[1]}" 'secret-only upgrade applies secret'
}
ok 'upgrade merges independently supplied fields'
# Opt-in integration: the caller supplies a downloaded asset, never a URL or an unpinned fixture.
# Hash verification precedes chmod/execution. This starts only temporary high-port processes.
if [ -n "${MTP_AUDIT_REAL_BIN:-}" ]; then
  real_hash="$(mtp_sha256 "${MTP_AUDIT_REAL_BIN}")"
  assert_eq "${MTP_SHA256[amd64]}" "${real_hash}" 'real amd64 asset matches repository-pinned SHA256'
  cp "${MTP_AUDIT_REAL_BIN}" "${MTP_BIN_DIR}/mtg-go"
  chmod 0700 "${MTP_BIN_DIR}/mtg-go"
  "${MTP_BIN_DIR}/mtg-go" --version
  for mode in v4 v6 dual; do
    # The fixture/template block above stubs install; the service entrypoints remain real.
    mtp_atomic_write "${MTP_CONF}" <<EOF
PORT=38443
SECRET=${FULL}
DOMAIN=${DOMAIN}
IP_MODE=${mode}
EOF
    mtp_start_process || fail "real mtg ${mode} startup"
    read -r pid started <"${MTP_WORKDIR}/mtp.pid"
    CLEANUP_PIDS+=("${pid}")
    mtp_pid_matches "${pid}" "${started}" || fail 'real mtg PID identity'
    # Check the process actually owns the listener, not merely that it survived argument parsing.
    listening=false
    for ((i=0; i<30; i++)); do
      if ss -H -ltnp 'sport = :38443' | grep -Fq "pid=${pid},"; then listening=true; break; fi
      kill -0 "${pid}" 2>/dev/null || break
      sleep 0.1
    done
    [ "${listening}" = true ] || { cat "${MTP_LOG}" >&2; fail "real mtg ${mode} listener"; }
    mtp_stop_process || fail "real mtg ${mode} stop"
    wait "${pid}" || true
    ok "pinned real mtg ${mode} argv, PID, listener and bounded stop"
  done
else
  printf '%s\n' 'SKIP: real mtg integration (set MTP_AUDIT_REAL_BIN to the pinned amd64 asset)'
fi
[ ! -e "${TEST_DIR}/injected" ] || fail 'injection executed'
printf 'PASS: %d audit assertions (no host services installed)\n' "${PASS}"
