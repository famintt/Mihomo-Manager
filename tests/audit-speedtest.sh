#!/usr/bin/env bash
# Isolated fixtures only: no real speedtest, sysctl changes, services or downloads.
# Indirect sourced calls and literal hostile paths are intentional.
# shellcheck disable=SC1091,SC2016,SC2034,SC2317
set -eEuo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'chmod -R u+w "${TMP}"; rm -rf "${TMP}"' EXIT
BASE_DIR="${TMP}/base"
SYSCTL_D_DIR="${TMP}/sysctl.d"
export CALLS="${TMP}/calls" ARGUMENTS="${TMP}/args" SYSCTL_STATE="${TMP}/sysctl-state"
mkdir -p "${BASE_DIR}/bin" "${SYSCTL_D_DIR}" "${SYSCTL_STATE}"
: >"${CALLS}"
command_exists() { command -v "$1" >/dev/null 2>&1; }
print_warn() { printf '%s\n' "$*" >&2; }
print_info() { printf '%s\n' "$*" >&2; }
print_ok() { printf '%s\n' "$*" >&2; }
. "${ROOT}/lib/speedtest.sh"
. "${ROOT}/lib/tune.sh"
N=0
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
ok() { N=$((N+1)); printf 'ok %s - %s\n' "${N}" "$*"; }
eq() { [ "$2" = "$3" ] || fail "$1: expected [$2], got [$3]"; ok "$1"; }
reject() { if "$@" >"${TMP}/reject.out" 2>"${TMP}/reject.err"; then fail "unexpected success: $*"; fi; }

# The exact path includes spaces, quotes and command substitution characters.
odd_dir="${TMP}/path with 'quote;\$(touch PWNED)'"
mkdir -p "${odd_dir}"
BIN="${odd_dir}/speedtest"
cat >"${BIN}" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf '%s\n' 'Speedtest by Ookla 1.2.0'; exit 0; fi
printf 'measure\n' >>"${CALLS}"
printf '%s\0' "$@" >"${ARGUMENTS}"
case "${FIXTURE_MODE:-json}" in
json) printf '%s\n' '{"type":"result","upload":{"bandwidth":12500000},"ping":{"latency":12.75}}' ;;
zero) printf '%s\n' '{"upload":{"bandwidth":0},"ping":{"latency":12}}' ;;
multi) printf '%s\n' '{"upload":{"bandwidth":12500000}}' '{"upload":{"bandwidth":12500000}}' ;;
slow) exec sleep 20 ;;
failed) printf '%s\n' '{"upload":{"bandwidth":12500000}}'; exit 42 ;;
text) printf '%s\n' 'Speedtest by Ookla 1.1.0' 'Upload: 200.50 Mbit/s' 'Latency: 21.34 ms' ;;
wrongunit) printf '%s\n' 'Upload: 200.50 Kbit/s' ;;
invalid) printf '%s\n' '{"upload":{"bandwidth":"12500000"}}' ;;
*) exit 3 ;;
esac
EOF
chmod 0755 "${BIN}"
eq '12500000 bytes/s converts to 100 Mbps' 100 "$(run_speedtest "${BIN}")"
eq 'JSON metrics include integer latency' '100 12' "$(run_speedtest_metrics "${BIN}")"
mapfile -d '' -t args <"${ARGUMENTS}"
eq 'native argv contains exactly three flags' 3 "${#args[@]}"
eq 'pinned JSON contract uses --format=json' --format=json "${args[2]}"
[ ! -e PWNED ] || fail 'path shell injection'
ok 'hostile executable path remains one argument'
eq 'legacy text is parsed from the same single invocation' '200 21' "$(FIXTURE_MODE=text run_speedtest_metrics "${BIN}")"
for mode in failed invalid zero wrongunit multi; do
  : >"${CALLS}"
  reject env FIXTURE_MODE="${mode}" bash -c 'source "$1"; command_exists() { command -v "$1" >/dev/null 2>&1; }; run_speedtest_metrics "$2"' _ "${ROOT}/lib/speedtest.sh" "${BIN}"
  eq "${mode} does not cause a second network invocation" 1 "$(wc -l <"${CALLS}")"
done
for seconds in '' 0 -1 1.5 01 3601 999999999999999999999 '1;touch PWNED' '2s'; do
  : >"${CALLS}"
  if NET_TUNE_SPEEDTEST_TIMEOUT="${seconds}" run_speedtest "${BIN}" >/dev/null 2>&1; then fail "timeout accepted: [${seconds}]"; fi
  [ ! -s "${CALLS}" ] || fail 'invalid timeout ran binary'
done
ok 'timeout rejects empty, zero, negative, fractional, huge and injected values before exec'
: >"${CALLS}"
reject env FIXTURE_MODE=slow NET_TUNE_SPEEDTEST_TIMEOUT=1 bash -c 'source "$1"; command_exists() { command -v "$1" >/dev/null 2>&1; }; run_speedtest_metrics "$2"' _ "${ROOT}/lib/speedtest.sh" "${BIN}"
eq 'bounded timeout causes one invocation' 1 "$(wc -l <"${CALLS}")"
cp "${BIN}" "${BASE_DIR}/bin/speedtest"
eq 'existing local binary located as an absolute path' "${BASE_DIR}/bin/speedtest" "$(find_ookla_speedtest)"
: >"${CALLS}"
reject measure_net_metrics
reject probe_net_tune </dev/null
[ ! -s "${CALLS}" ] || fail 'default noninteractive measurement occurred'
ok 'noninteractive/default entrypoints skip networking without explicit consent'
eq 'explicit opt-in permits metrics' '100 12' "$(NET_TUNE_ALLOW_SPEEDTEST=1 measure_net_metrics)"
: >"${CALLS}"
if LOCK_HELD=true NET_TUNE_ALLOW_SPEEDTEST=1 measure_net_metrics >/dev/null 2>&1; then fail 'measurement under global lock'; fi
if LOCK_HELD=true NET_TUNE_ALLOW_SPEEDTEST=1 probe_net_tune >/dev/null 2>&1; then fail 'probe under global lock'; fi
[ ! -s "${CALLS}" ] || fail 'locked measurement executed'
ok 'all measurement entrypoints reject inherited global lock'

# Use a local prebuilt tar fixture; curl/wget are fail-safe shell stubs.
OOKLA_SPEEDTEST_VERSION=1.2.0
declare -A OOKLA_SHA256=()
uname() { printf '%s\n' "${TEST_ARCH:-x86_64}"; }
export ARCHIVE="${TMP}/archive.tgz" DOWNLOAD_LOG="${TMP}/downloads"
: >"${DOWNLOAD_LOG}"
curl() {
  local arg dest=''
  printf 'download\n' >>"${DOWNLOAD_LOG}"
  while [ "$#" -gt 0 ]; do arg="$1"; shift; if [ "${arg}" = -o ]; then dest="$1"; shift; fi; done
  [ -n "${dest}" ] || return 1
  cp "${ARCHIVE}" "${dest}"
}
wget() { fail 'unexpected wget'; }
NET_TUNE_ALLOW_SPEEDTEST=1
reject ensure_ookla_speedtest
TEST_ARCH=mips64 reject ensure_ookla_speedtest
[ ! -s "${DOWNLOAD_LOG}" ] || fail 'download before pin/architecture validation'
ok 'unsupported architecture and absent digest reject before any download'
OOKLA_SHA256[x86_64]=invalid
reject ensure_ookla_speedtest
[ ! -s "${DOWNLOAD_LOG}" ] || fail 'malformed digest downloaded'
ok 'malformed digest rejects before download'
if (command_exists() { case "$1" in timeout) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }; measure_net_metrics); then fail 'missing timeout accepted'; fi
[ ! -s "${DOWNLOAD_LOG}" ] || fail 'missing timeout downloaded'
ok 'absent timeout fails closed before execution or download'
mkdir "${TMP}/archive"
cp "${BIN}" "${TMP}/archive/speedtest"
printf 'do not extract\n' >"${TMP}/archive/unrelated"
tar -czf "${ARCHIVE}" -C "${TMP}/archive" speedtest unrelated
archive_digest="$(sha256sum "${ARCHIVE}")"; archive_digest="${archive_digest%% *}"
OOKLA_SHA256[x86_64]="${archive_digest}"
ensure_ookla_speedtest || fail 'verified install'
eq 'verified candidate installed' '100 12' "$(run_speedtest_metrics "${BASE_DIR}/bin/speedtest")"
[ ! -e "${BASE_DIR}/bin/unrelated" ] || fail 'unrelated tar member extracted'
ok 'archive extraction limited to speedtest member'
old="$(sha256sum "${BASE_DIR}/bin/speedtest")"
OOKLA_SHA256[x86_64]="${archive_digest/a/b}"
# Ensure the corruption differs even if the digest contains no a.
OOKLA_SHA256[x86_64]="0000000000000000000000000000000000000000000000000000000000000000"
reject ensure_ookla_speedtest
eq 'hash mismatch preserves previous executable' "${old}" "$(sha256sum "${BASE_DIR}/bin/speedtest")"
OOKLA_SHA256[x86_64]="${archive_digest}"
if (mv() { return 71; }; ensure_ookla_speedtest); then fail 'failed publication accepted'; fi
eq 'publication error preserves previous executable' "${old}" "$(sha256sum "${BASE_DIR}/bin/speedtest")"

# Kernel values are an on-disk mock. No real sysctl is ever executed.
sysctl() {
  local pair key
  case "$1" in
  -w) pair="$2"; key="${pair%%=*}"; printf '%s' "${pair#*=}" >"${SYSCTL_STATE}/${key}" ;;
  -n) [ -f "${SYSCTL_STATE}/$2" ] || return 1; cat "${SYSCTL_STATE}/$2" ;;
  *) fail 'unexpected sysctl mode' ;;
  esac
}
get_tcp_buffer_cap_mb() { printf 64; }
id() { printf '0\n'; }
get_setting() { printf '%s' ''; }
manager_env_or_setting() { case "$1" in net_tune) printf 1 ;; *) printf '%s' '' ;; esac; }
set_setting() { printf '%s=%s\n' "$1" "$2" >>"${TMP}/settings"; }
: >"${CALLS}"
apply_network_tune || fail 'default isolated tune'
[ ! -s "${CALLS}" ] || fail 'parameter application invoked speedtest'
eq 'leading-zero bandwidth parses as decimal' 8 "$(calculate_net_tune_buffer_mb 0000080 asia)"
[ -f "${SYSCTL_D_DIR}/99-mihomo-manager-net-tune.conf" ] || fail 'core tuning not persisted'
[ -f "${SYSCTL_D_DIR}/98-mihomo-manager-net-tune-extra.conf" ] || fail 'extra tuning not persisted'
ok 'default tuning applies fixed defaults and persists atomically without a probe'
missing="${TMP}/missing/sysctl.d"
SYSCTL_D_DIR="${missing}" apply_sysctls 8388608 >"${TMP}/missing.out" 2>"${TMP}/missing.err" || fail 'absent sysctl directory aborted tuning'
[ ! -e "${missing}" ] || fail 'created sysctl directory unexpectedly'
grep -q '仅对当前运行生效' "${TMP}/missing.err" || fail 'no missing-directory warning'
ok 'absent sysctl directory warns without abort or false persistence success'
chmod 0555 "${SYSCTL_D_DIR}"
if [ "${EUID}" -ne 0 ]; then
  apply_sysctls 8388608 >"${TMP}/readonly.out" 2>"${TMP}/readonly.err" || fail 'readonly sysctl directory aborted'
  grep -q '仅对当前运行生效' "${TMP}/readonly.err" || fail 'readonly warning missing'
fi
chmod 0755 "${SYSCTL_D_DIR}"
ok 'readonly persistence directory handled as best-effort runtime tuning'
previous="$(sha256sum "${SYSCTL_D_DIR}/99-mihomo-manager-net-tune.conf")"
if (mv() { return 72; }; net_tune_write_config 99-mihomo-manager-net-tune.conf <<<'# mihomo-manager net_tune replacement'); then fail 'config publication failure masked'; fi
eq 'failed config publication preserves previous file' "${previous}" "$(sha256sum "${SYSCTL_D_DIR}/99-mihomo-manager-net-tune.conf")"
printf 'foreign tuning\n' >"${SYSCTL_D_DIR}/99-other-project.conf"
remove_net_tune || fail 'manager config removal'
[ -f "${SYSCTL_D_DIR}/99-other-project.conf" ] || fail 'unrelated tuning deleted'
ok 'uninstall removes only two identified manager files'
printf 'foreign same name\n' >"${SYSCTL_D_DIR}/99-mihomo-manager-net-tune.conf"
ln -s "${SYSCTL_D_DIR}/99-other-project.conf" "${SYSCTL_D_DIR}/98-mihomo-manager-net-tune-extra.conf"
reject remove_net_tune
if [ ! -f "${SYSCTL_D_DIR}/99-mihomo-manager-net-tune.conf" ] || [ ! -L "${SYSCTL_D_DIR}/98-mihomo-manager-net-tune-extra.conf" ]; then fail 'foreign file or symlink deleted'; fi
if net_tune_write_config 99-mihomo-manager-net-tune.conf <<<'# mihomo-manager net_tune'; then fail 'foreign config overwritten'; fi
ok 'foreign same-name files and symlinks retained on write/removal'
SYSCTL_D_DIR="${missing}" remove_net_tune || fail 'missing cleanup directory'
ok 'uninstall with absent tuning directory is harmless'
printf 'PASS: %s speedtest/tuning audit assertions (fixtures only)\n' "${N}"
