#!/usr/bin/env bash
# MM-06/MM-09: local fixtures only; no downloads, host install, services, or GitHub API.
# shellcheck disable=SC1091,SC2016
set -eEuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf -- "${TEMP}"' EXIT
. "${ROOT}/install.sh"
N=0
fail_test() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { N=$((N + 1)); printf 'ok %s - %s\n' "${N}" "$*"; }
reject() { if "$@" >"${TEMP}/rejected.out" 2>"${TEMP}/rejected.err"; then fail_test "unexpected success: $*"; fi; }
tar_version_fixture() (
  local mode="$1"
  tar() {
    [ "$1" = --version ] || return 72
    case "$mode" in
      long) printf 'tar (GNU tar) fixture\n'; python3 -c 'import sys; sys.stdout.write("x" * 262144)' ;;
      failed) printf 'tar (GNU tar) fixture\n'; return 71 ;;
      other) printf 'tar (busybox) fixture\n' ;;
    esac
  }
  require_tools
)
tar_version_fixture long || fail_test 'complete GNU tar version output must be consumed'
ok 'GNU tar detection reads complete output without pipefail SIGPIPE'
reject tar_version_fixture failed
ok 'GNU tar version command failure is rejected even with matching stdout'
reject tar_version_fixture other
ok 'non-GNU tar remains rejected'
project="${TEMP}/project"
mkdir -p "${project}/lib" "${project}/metadata" "${project}/scripts" "${project}/interface"
cp "${ROOT}/install.sh" "${ROOT}/install.sh.sha256" "${project}/"
cp "${ROOT}/scripts/build-release-bundle.sh" "${ROOT}/scripts/check-version.sh" "${project}/scripts/"
cp "${ROOT}/interface/index.html" "${ROOT}/interface/build.py" "${ROOT}/interface/worker.js" "${project}/interface/"
printf 'v1.3.0\n' >"${project}/VERSION"
printf '# Fixture\n' >"${project}/README.md"
printf '#!/usr/bin/env bash\nSCRIPT_VERSION="1.3.0"\n' >"${project}/mm.sh"
cp "${project}/mm.sh" "${project}/mtp.sh"
printf '#!/usr/bin/env bash\n: watchdog\n' >"${project}/scripts/watchdog.sh"
printf '#!/usr/bin/env bash\nMM_MODULES=(env io)\n' >"${project}/lib/env.sh"
printf '#!/usr/bin/env bash\n: io\n' >"${project}/lib/io.sh"
printf 'REPO_OWNER="famintt"\n' >"${project}/metadata/upstream.env"
bash "${project}/scripts/build-release-bundle.sh" --refresh >"${TEMP}/build.log"
bundle="${project}/dist/${PACKAGE_NAME}"
first="$(sha256_file "${bundle}")"
bash "${project}/scripts/build-release-bundle.sh" >"${TEMP}/build2.log"
[ "${first}" = "$(sha256_file "${bundle}")" ] || fail_test 'bundle bytes not reproducible'
ok 'identical payload produces byte-identical bundles'
[ "$(bash "${project}/install.sh" --print-package-sha)" = "${first}" ] || fail_test 'refresh pin'
cmp -s <(printf '%s\n' "$(sha256_file "${project}/install.sh")") "${project}/install.sh.sha256" || fail_test 'refresh sidecar'
ok 'refresh regenerates bundle pin and bootstrap sidecar from one source'
bash "${project}/install.sh" --verify-bundle "${bundle}" >/dev/null
ok 'offline bootstrap verification accepts complete fixed bundle without root'
(cd "${project}" && bash scripts/check-version.sh --tag v1.3.0) >"${TEMP}/check.log"
ok 'version, manifest, sidecar, tag and generated frontend gate accepts consistent release'
reject bash "${project}/scripts/check-version.sh" --tag v1.2.8
ok 'release tag mismatch is rejected'
printf '%064d\n' 0 >"${project}/install.sh.sha256"
reject bash "${project}/scripts/check-version.sh"
ok 'stale repository bootstrap sidecar is rejected'
bash "${project}/scripts/build-release-bundle.sh" --refresh >/dev/null
printf '# changed\n' >>"${project}/README.md"
reject bash "${project}/scripts/check-version.sh"
ok 'payload change without repinning is rejected'
printf '# Fixture\n' >"${project}/README.md"
cp "${project}/lib/io.sh" "${project}/lib/extra.sh"
reject bash "${project}/scripts/build-release-bundle.sh"
ok 'undeclared module prevents release build'
rm "${project}/lib/extra.sh"
cp "${project}/lib/env.sh" "${TEMP}/env.valid"
printf '#!/usr/bin/env bash\nMM_MODULES=(env io io)\n' >"${project}/lib/env.sh"
reject bash "${project}/scripts/build-release-bundle.sh"
ok 'duplicate MM_MODULES entries cannot be normalized away'
cp "${TEMP}/env.valid" "${project}/lib/env.sh"
ln -s io.sh "${project}/lib/extra.sh"
reject bash "${project}/scripts/build-release-bundle.sh"
rm "${project}/lib/extra.sh"
mv "${project}/lib/io.sh" "${project}/lib/io.real"
ln -s io.real "${project}/lib/io.sh"
reject bash "${project}/scripts/build-release-bundle.sh"
ok 'declared source modules must be regular non-symlink files'
rm "${project}/lib/io.sh"
mv "${project}/lib/io.real" "${project}/lib/io.sh"
bash "${project}/scripts/build-release-bundle.sh" --refresh >/dev/null
mkdir "${TEMP}/valid"
tar --extract --gzip --file "${bundle}" --directory "${TEMP}/valid" --same-permissions
valid="${TEMP}/valid/mihomo-manager-v1.3.0"
validate_candidate "${valid}" v1.3.0
ok 'candidate inventory and manifest validate every packaged module'
candidate_scan_failure() (
  local fault="$1"
  find() {
    local argument
    for argument in "$@"; do
      if { [ "${fault}" = special ] && [ "${argument}" = '!' ]; } ||
         { [ "${fault}" = hardlinks ] && [ "${argument}" = -links ]; }; then
        printf '%s\n' "${fault}" >>"${TEMP}/find-fault"
        return 71
      fi
    done
    command find "$@"
  }
  validate_candidate "${valid}" v1.3.0
)
for scan in special hardlinks; do
  : >"${TEMP}/find-fault"
  reject candidate_scan_failure "${scan}"
  [ "$(<"${TEMP}/find-fault")" = "${scan}" ] || fail_test "${scan} fault injection did not run"
  ok "candidate rejects failed ${scan} enumeration with empty stdout"
done
copy_candidate() { rm -rf -- "${TEMP}/bad"; cp -a "${valid}" "${TEMP}/bad"; }
copy_candidate; rm "${TEMP}/bad/lib/io.sh"; reject validate_candidate "${TEMP}/bad" v1.3.0
ok 'missing module rejected'
copy_candidate; printf '# extra\n' >"${TEMP}/bad/lib/extra.sh"; reject validate_candidate "${TEMP}/bad" v1.3.0
ok 'extra module rejected'
copy_candidate; mkdir "${TEMP}/bad/unknown"; reject validate_candidate "${TEMP}/bad" v1.3.0
ok 'extra directory rejected'
copy_candidate; printf 'v1.2.8\n' >"${TEMP}/bad/VERSION"; reject validate_candidate "${TEMP}/bad" v1.3.0
ok 'payload VERSION must match bootstrap tag exactly'
copy_candidate; printf '\n' >>"${TEMP}/bad/VERSION"; reject validate_candidate "${TEMP}/bad" v1.3.0
ok 'VERSION rejects hidden extra lines'
copy_candidate; printf 'SCRIPT_VERSION="1.2.8"\n' >>"${TEMP}/bad/mtp.sh"; reject validate_candidate "${TEMP}/bad" v1.3.0
ok 'duplicate or mismatched MTProxy version rejected'
copy_candidate; printf '# tamper\n' >>"${TEMP}/bad/lib/io.sh"; reject validate_candidate "${TEMP}/bad" v1.3.0
ok 'modified module fails manifest verification'
copy_candidate; chmod 0777 "${TEMP}/bad/lib/io.sh"; reject validate_candidate "${TEMP}/bad" v1.3.0
ok 'writable payload mode rejected'
copy_candidate; chmod 0644 "${TEMP}/bad/mtp.sh"; reject validate_candidate "${TEMP}/bad" v1.3.0
ok 'missing executable mode rejected'
copy_candidate; rm "${TEMP}/bad/lib/io.sh"; ln -s ../mm.sh "${TEMP}/bad/lib/io.sh"; reject validate_candidate "${TEMP}/bad" v1.3.0
ok 'candidate symlinks rejected'
copy_candidate; rm "${TEMP}/bad/lib/io.sh"; ln "${TEMP}/bad/mm.sh" "${TEMP}/bad/lib/io.sh"; reject validate_candidate "${TEMP}/bad" v1.3.0
ok 'candidate hardlinks rejected'
for mode in unsorted duplicate missing crlf binary-marker; do
  copy_candidate
  python3 - "${TEMP}/bad/MANIFEST.sha256" "${mode}" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); lines=p.read_bytes().splitlines(keepends=True); mode=sys.argv[2]
if mode=='unsorted': lines.reverse()
elif mode=='duplicate': lines.append(lines[0])
elif mode=='missing': lines.pop()
elif mode=='crlf': lines=[line.replace(b'\n',b'\r\n') for line in lines]
elif mode=='binary-marker': lines=[line[:64]+b' *'+line[66:] for line in lines]
p.write_bytes(b''.join(lines))
PY
  reject validate_candidate "${TEMP}/bad" v1.3.0
  ok "strict manifest rejects ${mode}"
done
copy_candidate
printf 'if then\n' >"${TEMP}/bad/lib/io.sh"
(cd "${TEMP}/bad" && find . -type f ! -name MANIFEST.sha256 -printf '%P\n' | LC_ALL=C sort | while IFS= read -r path; do sha256sum "${path}"; done) >"${TEMP}/bad/MANIFEST.sha256"
reject validate_candidate "${TEMP}/bad" v1.3.0
ok 'syntax error rejected even with matching manifest'

# A verified local fixture supplies the same public transaction function as lib/install.sh.
# The fake endpoint records only to TEMP; it cannot publish host files or touch a service.
copy_candidate
cat >"${TEMP}/bad/mm.sh" <<'FIXTURE'
#!/usr/bin/env bash
SCRIPT_VERSION="1.3.0"
[ "${MM_TEST_MODE:-}" = 1 ] || return 61
install_project_candidate() {
  [ -z "${MM_TEST_MODE+x}" ] || return 62
  printf '%s %s\n' "${1##*/}" "$2" >>"${HANDOFF_RECORD}"
  return "${HANDOFF_RESULT:-0}"
}
FIXTURE
chmod 0755 "${TEMP}/bad/mm.sh"
(cd "${TEMP}/bad" && find . -type f ! -name MANIFEST.sha256 -printf '%P\n' | LC_ALL=C sort | while IFS= read -r path; do sha256sum "${path}"; done) >"${TEMP}/bad/MANIFEST.sha256"
mkdir "${TEMP}/handoff"
cp -a "${TEMP}/bad" "${TEMP}/handoff/mihomo-manager-v1.3.0"
tar --format=gnu --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -cf - -C "${TEMP}/handoff" mihomo-manager-v1.3.0 | gzip -n >"${TEMP}/handoff.tgz"
PACKAGE_SHA256="$(sha256_file "${TEMP}/handoff.tgz")"
HANDOFF_RECORD="${TEMP}/handoff.record"
MM_TEST_MODE=outer
install_bundle "${TEMP}/handoff.tgz"
[ "$(<"${HANDOFF_RECORD}")" = 'mihomo-manager-v1.3.0 v1.3.0' ] || fail_test 'bootstrap handoff args'
[ "${MM_TEST_MODE}" = outer ] || fail_test 'candidate sourcing escaped subshell'
unset MM_TEST_MODE
ok 'bootstrap verifies before sourcing and invokes shared transaction with test mode unset'
HANDOFF_RESULT=53 reject install_bundle "${TEMP}/handoff.tgz"
ok 'shared transaction failure propagates to bootstrap without a success result'

# Exercise path/type attacks before extraction. Every archive is local and deliberately repinned
# in this test process; production has no option to override its compiled bootstrap digest.
python3 - "${TEMP}" <<'PY'
import io, sys, tarfile
from pathlib import Path
base=Path(sys.argv[1]); root='mihomo-manager-v1.3.0/'
attacks={'traversal':root+'../escaped','absolute':'/tmp/mm-release-escaped','extra-root':'other/mm.sh','newline':root+'mm.sh\nevil','symlink':root+'mm.sh','hardlink':root+'lib/io.sh','fifo':root+'mm.sh','wrong-mode':root+'mm.sh','duplicate':root+'mm.sh'}
for mode,name in attacks.items():
    with tarfile.open(base/(mode+'.tgz'),'w:gz',format=tarfile.GNU_FORMAT) as tf:
        info=tarfile.TarInfo(name); info.mode=0o755; content=b'#!/bin/sh\n'
        if mode=='symlink': info.type=tarfile.SYMTYPE; info.linkname='/tmp/mm-release-escaped'
        elif mode=='hardlink': info.type=tarfile.LNKTYPE; info.linkname=root+'mm.sh'
        elif mode=='fifo': info.type=tarfile.FIFOTYPE
        else: info.size=len(content)
        if mode=='wrong-mode': info.mode=0o777
        tf.addfile(info,io.BytesIO(content) if info.isreg() else None)
        if mode=='duplicate': tf.addfile(info,io.BytesIO(content))
PY
for mode in traversal absolute extra-root newline symlink hardlink fifo wrong-mode duplicate; do
  reject validate_archive_headers "${TEMP}/${mode}.tgz" v1.3.0
  ok "pre-extraction header gate rejects ${mode}"
done
PACKAGE_SHA256="${first}"
reject verify_bundle "${TEMP}/wrong-mode.tgz"
ok 'pinned bootstrap rejects mismatched archive bytes before extraction'
printf 'not gzip\n' >"${TEMP}/not-gzip"
PACKAGE_SHA256="$(sha256_file "${TEMP}/not-gzip")"
reject verify_bundle "${TEMP}/not-gzip"
ok 'invalid gzip rejected even after local test repin'
if (has_cmd() { [ "$1" != gzip ] && command -v "$1" >/dev/null 2>&1; }; require_tools) >/dev/null 2>&1; then fail_test 'missing gzip accepted'; fi
ok 'gzip is an explicit bootstrap dependency'
printf 'PASS: %s release audit assertions (offline fixtures only)\n' "${N}"
