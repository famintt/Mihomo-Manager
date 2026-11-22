#!/usr/bin/env bash
set -eEuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
# shellcheck source=install.sh
. "${ROOT_DIR}/install.sh"
version="$(<VERSION)"
[[ "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { fail 'VERSION 无效'; exit 1; }
expected_tag="${version}"
if [ "${1:-}" = --tag ] && [ "$#" -eq 2 ]; then expected_tag="$2"
elif [ "$#" -gt 0 ]; then echo '用法：check-version.sh [--tag vX.Y.Z]' >&2; exit 2; fi
[ "${expected_tag}" = "${version}" ] || { fail "tag ${expected_tag} 与 VERSION ${version} 不一致"; exit 1; }
[ "${PROJECT_VERSION}" = "${version}" ] || { fail 'bootstrap 版本不一致'; exit 1; }
[ "${PACKAGE_NAME}" = "mihomo-manager-${version}.tar.gz" ] || { fail 'bundle 文件名不一致'; exit 1; }
[ "${PACKAGE_URL}" = "https://github.com/famintt/Mihomo-Manager/releases/download/${version}/${PACKAGE_NAME}" ] || { fail 'bootstrap 下载源不一致'; exit 1; }

# Build validates the literal module inventory, every code file, metadata, modes and payload version.
bash scripts/build-release-bundle.sh
verify_bundle "${ROOT_DIR}/dist/${PACKAGE_NAME}"
cmp -s <(printf '%s  %s\n' "${PACKAGE_SHA256}" "${PACKAGE_NAME}") dist/checksums.txt || { fail 'checksums.txt 格式或摘要错误'; exit 1; }
cmp -s <(printf '%s\n' "$(sha256_file install.sh)") install.sh.sha256 || { fail 'install.sh.sha256 陈旧或格式无效'; exit 1; }
if ! cmp -s install.sh dist/install.sh || ! cmp -s install.sh.sha256 dist/install.sh.sha256; then fail 'dist bootstrap 与源码不同'; exit 1; fi

# Preserve the existing frontend-generation gate without ever overwriting tracked files.
python=''
if command -v python3 >/dev/null 2>&1 && python3 -c pass >/dev/null 2>&1; then python=python3
elif command -v python >/dev/null 2>&1 && python -c pass >/dev/null 2>&1; then python=python; fi
[ -n "${python}" ] || { fail '需要 Python 校验 worker.js'; exit 1; }
grep -Fq 'releases/latest/download/install.sh' interface/index.html || { fail '前端入口没有使用最新 bootstrap'; exit 1; }
if grep -qE 'releases/download/v[0-9]+\.[0-9]+\.[0-9]+/install.sh' README.md; then fail 'README bootstrap URL 钉死旧版本'; exit 1; fi
temporary="$(mktemp -d)"
trap 'rm -rf -- "${temporary}"' EXIT
cp interface/index.html interface/build.py VERSION "${temporary}/"
(cd "${temporary}" && "${python}" build.py >/dev/null)
cmp -s interface/worker.js "${temporary}/worker.js" || { fail 'worker.js 未与 index.html 同步生成'; exit 1; }
printf '一致性校验通过：%s / %s\n' "${version}" "${PACKAGE_SHA256}"
