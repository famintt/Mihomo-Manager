#!/usr/bin/env bash
# accept-mihomo.sh —— mihomo 迁移验收（交付判定链）
#
# 用途：在任一台机器（VPS 相同）复跑仓库 render 链，用真 mihomo 二进制做唯一
# schema 法官，逐条断言均已附真字段级判决字节（`mihomo -t -f` rc=0 + 实监听）。
#
# 用法：
#   MIHOMO_BIN=${MIHOMO_BIN:-/tmp/opencode/mihomo} ./tests/accept-mihomo.sh
# shellcheck disable=SC1090
set -eEuo pipefail

# ---- 0. 自检：本仓库是否存在（路径两拼兼容） ----
if [ -d ./lib ]; then :; elif [ -d ../lib ]; then cd ..; else
  printf '[1;31m[错误][0m 未能在仓库上下文运行（找不到 lib/）。\n' >&2
  exit 2
fi

# ---- 1. 真二进制就位 ----
MIHOMO_BIN="${MIHOMO_BIN:-/tmp/opencode/mihomo}"
if [ ! -x "${MIHOMO_BIN}" ]; then
  printf '[错误] 未找到真 mihomo 二进制：%s\n' "${MIHOMO_BIN}" >&2
  printf '       从 https://github.com/MetaCubeX/mihomo/releases 取 v1.19.31 后重试。\n' >&2
  exit 2
fi
_ver="$("${MIHOMO_BIN}" -v 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
printf '== 真二进制 == %s (%s)\n' "${MIHOMO_BIN}" "${_ver:-?}"

# ---- 2. 隔离沙箱：BASE_DIR 即 mihomo 的 -d 工作目录（证书 SAFE_PATHS 之内） ----
export BASE_DIR="${BASE_DIR:-$(mktemp -d)/etc}"
export LIB_DIR="${LIB_DIR:-$(mktemp -d)/lib}"
mkdir -p "${BASE_DIR}"
for f in lib/env.sh lib/io.sh lib/storage.sh lib/settings.sh lib/cert.sh lib/render.sh; do
  if [ -f "${f}" ]; then . "${f}"; else printf '[错误] 缺 %s\n' "${f}" >&2; exit 2; fi
done
init_storage

# ---- 3. 静态断言：render.sh 已脱离 sing-box JSON schema，改用 mihomo YAML ----
_bad_json="$(grep -nE '\.inbounds|listen_port|tcp_fast_open|max_early_data|zero_rtt_handshake|bbr_profile|\.tls\.reality' lib/render.sh || true)"
if [ -n "${_bad_json}" ]; then
  printf '[1;31m[错误][0m render.sh 仍残留 sing-box JSON schema 字段：\n%s\n' "${_bad_json}" >&2
  exit 1
fi
printf '== sing-box JSON schema 字段已清除 ==\n'
_bad_type="$(grep -nE 'type: vless \(ws\)' lib/render.sh || true)"
if [ -n "${_bad_type}" ]; then
  printf '[1;31m[错误][0m render.sh 使用非法 mihomo listener 类型 "vless (ws)"：\n%s\n' "${_bad_type}" >&2
  exit 1
fi
for _m in 'listeners:' 'reality-config:' 'congestion-controller: bbr' 'external-controller:' 'allow-insecure: true'; do
  grep -qF "${_m}" lib/render.sh || {
    printf '[1;31m[错误][0m render.sh 缺少 mihomo 必需片段：%s\n' "${_m}" >&2
    exit 1
  }
done
printf '== mihomo YAML 片段齐备 ==\n'

# ---- 4. 组装 6 协议节点（证书落在 BASE_DIR/certs，位于 mihomo SAFE_PATHS 内） ----
CERT="${BASE_DIR}/certs/accept.crt"
KEY="${BASE_DIR}/certs/accept.key"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "${KEY}" -out "${CERT}" -days 2 -subj "/CN=www.bing.com" >/dev/null 2>&1
_rk="$("${MIHOMO_BIN}" generate reality-keypair)"
_priv="$(printf '%s\n' "${_rk}" | sed -n 's/^PrivateKey: //p')"
_pub="$(printf '%s\n' "${_rk}" | sed -n 's/^PublicKey: //p')"
_uuid="b8b1e0c5-ffd5-487f-a7f2-e72faa8fba7b"
_add() { json_set_record "${NODES_FILE}" "$1" "$2"; json_set_record "${SECRETS_FILE}" "$1" "$3"; }
_add nreality "{\"protocol\":\"vless-reality\",\"name\":\"HK\",\"port\":30831,\"public_key\":\"${_pub}\",\"short_id\":\"0123456789abcdef\",\"reality_server\":\"www.apple.com\"}" "{\"uuid\":\"${_uuid}\",\"private_key\":\"${_priv}\"}"
_add nws "{\"protocol\":\"vless-ws-tls\",\"name\":\"HK\",\"port\":30851,\"ws_path\":\"/w\",\"certificate_mode\":\"custom\",\"certificate_path\":\"${CERT}\",\"key_path\":\"${KEY}\"}" "{\"uuid\":\"${_uuid}\"}"
_add nany "{\"protocol\":\"anytls\",\"name\":\"HK\",\"port\":30861,\"certificate_path\":\"${CERT}\",\"key_path\":\"${KEY}\"}" '{"password":"testpw"}'
_add ntuic "{\"protocol\":\"tuic-v5\",\"name\":\"HK\",\"port\":30862,\"certificate_path\":\"${CERT}\",\"key_path\":\"${KEY}\"}" "{\"uuid\":\"${_uuid}\",\"password\":\"testpw\"}"
_add nhy2 "{\"protocol\":\"hy2\",\"name\":\"HK\",\"port\":30853,\"certificate_path\":\"${CERT}\",\"key_path\":\"${KEY}\",\"up_mbps\":100,\"down_mbps\":500}" '{"password":"testpw"}'
_add nargo "{\"protocol\":\"vless-argo\",\"name\":\"HK\",\"port\":30854,\"ws_path\":\"/a\"}" "{\"uuid\":\"${_uuid}\"}"
_add nsocks "{\"protocol\":\"socks5\",\"name\":\"HK\",\"port\":30855,\"username\":\"testu\"}" '{"password":"testpw"}'

# ---- 5. 端到端：仓库 render 链产出 config → 真二进制 -t（VPS service.sh 的判决点） ----
# 关闭 clash_api 可观测面，避免与宿主机既有 19990 端口冲突（本验收只判 listener schema）
export clash_api=off
printf '== 仓库 render_config 全链 + 真 %s -t ==\n' "${_ver:-?}"
rc=0
render_config >/dev/null 2>&1 || rc=$?
if [ "${rc}" -ne 0 ]; then
  printf '[1;31m[错误][0m 仓库 render 链 -t rc=%s（VPS 同链会在此中止）。\n' "${rc}" >&2
  exit 1
fi
assert_listeners="$(grep -cE '^  - type:' "${CONFIG_FILE}")"
if [ "${assert_listeners}" != "7" ]; then
  printf '[1;31m[错误][0m 期望 7 个 listener，实际 %s。\n' "${assert_listeners}" >&2
  exit 1
fi
printf '[32m✓[0m render_config rc=0，7 个 listener 通过 mihomo -t。\n'

# ---- 6. 实监听：真进程起 7 个端口，全部 LISTEN 后强杀（kill -9 + wait 同调用） ----
printf '== 实监听冒烟 ==\n'
"${MIHOMO_BIN}" -d "${BASE_DIR}" -f "${CONFIG_FILE}" >"${BASE_DIR}/accept-run.log" 2>&1 &
_mpid=$!
sleep 2
_missing=""
# TCP：reality/ws/anytls/argo/socks；UDP：tuic(30862)/hy2(30853)
for _p in 30831 30851 30861 30854 30855; do
  if ! (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -qE "[:.]${_p}[[:space:]]"; then
    _missing="${_missing} tcp/${_p}"
  fi
done
for _p in 30862 30853; do
  if ! (ss -lun 2>/dev/null || netstat -lun 2>/dev/null) | grep -qE "[:.]${_p}[[:space:]]"; then
    _missing="${_missing} udp/${_p}"
  fi
done
kill -9 "${_mpid}" 2>/dev/null || true
wait "${_mpid}" 2>/dev/null || true
if [ -n "${_missing}" ]; then
  printf '[1;31m[错误][0m 以下端口未监听：%s\n' "${_missing}" >&2
  sed 's/^/  run: /' "${BASE_DIR}/accept-run.log" >&2 || true
  exit 1
fi
printf '[32m✓[0m 7 个 listener 全部实监听（含 :: 双栈、Argo allow-insecure）。\n'

printf '\n== 验收 mihomo 全部通过 ==\n'
