#!/usr/bin/env bash
set -eEuo pipefail
umask 022
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
# shellcheck source=install.sh
. "${ROOT_DIR}/install.sh"

refresh=0
if [ "${1:-}" = --refresh ] && [ "$#" -eq 1 ]; then refresh=1
elif [ "$#" -ne 0 ]; then echo '用法：build-release-bundle.sh [--refresh]' >&2; exit 2; fi
require_tools
version="$(<VERSION)"
[[ "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { fail 'VERSION 无效'; exit 1; }
cmp -s <(printf '%s\n' "${version}") VERSION || { fail 'VERSION 必须为单行 LF'; exit 1; }
[ "${version}" = "${PROJECT_VERSION}" ] || { fail 'bootstrap PROJECT_VERSION 不匹配'; exit 1; }
[ "${PACKAGE_NAME}" = "mihomo-manager-${version}.tar.gz" ] || { fail 'bootstrap PACKAGE_NAME 不匹配'; exit 1; }
paths="$(expected_files "${ROOT_DIR}" | LC_ALL=C sort)"
actual_modules="$(find lib -mindepth 1 -maxdepth 1 -printf '%p\n' | LC_ALL=C sort)"
expected_modules="$(printf '%s\n' "${paths}" | grep '^lib/')"
[ "${actual_modules}" = "${expected_modules}" ] || { fail '源码模块与 MM_MODULES 不一致'; exit 1; }
mkdir -p dist
work="$(mktemp -d "${ROOT_DIR}/dist/.build.XXXXXXXX")"
bootstrap_next=''
checksum_next=''
trap 'rm -rf -- "${work}"; [ -z "${bootstrap_next}" ] || rm -f -- "${bootstrap_next}"; [ -z "${checksum_next}" ] || rm -f -- "${checksum_next}"' EXIT
root="${work}/mihomo-manager-${version}"
install -d -m 0755 "${root}" "${root}/lib" "${root}/metadata" "${root}/scripts"
while IFS= read -r path; do
  if [ ! -f "${path}" ] || [ -L "${path}" ]; then fail "源码文件无效：${path}"; exit 1; fi
  case "${path}" in mm.sh|mtp.sh|scripts/watchdog.sh) mode=0755 ;; *) mode=0644 ;; esac
  install -m "${mode}" "${path}" "${root}/${path}"
done <<<"${paths}"
(
  cd "${root}"
  while IFS= read -r path; do printf '%s  %s\n' "$(sha256_file "${path}")" "${path}"; done <<<"${paths}"
) >"${root}/MANIFEST.sha256"
chmod 0644 "${root}/MANIFEST.sha256"
validate_candidate "${root}" "${version}"

# GNU format, stable order/modes/owner/time and gzip -n make a reproducible byte stream.
tar --format=gnu --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
  -cf - -C "${work}" "mihomo-manager-${version}" | gzip -n >"${work}/${PACKAGE_NAME}"
validate_archive_headers "${work}/${PACKAGE_NAME}" "${version}"
digest="$(sha256_file "${work}/${PACKAGE_NAME}")"
if [ "${refresh}" -eq 1 ]; then
  # The bootstrap is delivered alongside the bundle, avoiding a circular digest.
  bootstrap_next="$(mktemp "${ROOT_DIR}/.install.next.XXXXXXXX")"
  awk -v hash="${digest}" '/^PACKAGE_SHA256=/ { print "PACKAGE_SHA256=\"" hash "\""; next } { print }' install.sh >"${bootstrap_next}"
  bash -n "${bootstrap_next}"
  chmod 0755 "${bootstrap_next}"
  checksum_next="$(mktemp "${ROOT_DIR}/.install.sha.next.XXXXXXXX")"
  printf '%s\n' "$(sha256_file "${bootstrap_next}")" >"${checksum_next}"
  chmod 0644 "${checksum_next}"
  mv -f -- "${bootstrap_next}" install.sh
  mv -f -- "${checksum_next}" install.sh.sha256
fi
printf '%s  %s\n' "${digest}" "${PACKAGE_NAME}" >"${work}/checksums.txt"
install -m 0755 install.sh "${work}/install.sh"
install -m 0644 install.sh.sha256 "${work}/install.sh.sha256"
for path in "${PACKAGE_NAME}" checksums.txt install.sh install.sh.sha256; do mv -f -- "${work}/${path}" "dist/${path}"; done
printf 'Built %s/dist/%s\n' "${ROOT_DIR}" "${PACKAGE_NAME}"
if [ "${refresh}" -eq 1 ]; then printf 'Updated bootstrap pin and sidecar: %s\n' "${digest}"; fi
