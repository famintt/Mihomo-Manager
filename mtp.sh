#!/usr/bin/env bash
# SCRIPT_VERSION 由 scripts/check-version.sh 外部读取做版本一致性门禁，豁免 SC2034。
# shellcheck disable=SC2034
set -eEuo pipefail
umask 077

###############################################################################
# MTProxy (Go mtg) 独立管理脚本 —— 与 Mihomo Manager(mm.sh) 完全分离
#
# 命令:
#   mtp              安装/更新 MTProxy（环境变量 mtpt 指定端口，缺省则为首次安装）
#   mtp info         查看已安装服务连接信息（tg://proxy 链接）
#   mtp restart      重启 MTProxy 服务
#   mtp un           全量卸载并清理（服务、二进制、配置、日志）
#
# 环境变量:
#   mtpt          监听端口（必填，安装时启用）
#   mtp_domain    伪装域名（可选，默认从内置列表随机）
#   mtp_secret    通信密钥 32 位 hex（可选，默认随机生成）
#   mtp_ip_mode   监听模式 v4 / v6 / dual（可选，默认 v4）
###############################################################################

SCRIPT_VERSION="1.3.1"

# bash>=4.0 前置守卫：MTP_SHA256 关联数组与 ${!var} 间接引用在 bash 3.x 不可用，
# 尽早失败并给出可读报错（mm.sh 侧同款要求，见 require_bash4）。
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "需要 bash 4.0 及以上版本（当前：${BASH_VERSION:-未知}）。" >&2
  exit 1
fi

# MTG GO 版本与校验：上游 jyucoeng/singbox-tools 的 Go 构建镜像
MTP_WORKDIR="/opt/mtproxy"
MTP_BIN_DIR="${MTP_WORKDIR}/bin"
MTP_CONF="${MTP_WORKDIR}/go.conf"
MTP_LOG="${MTP_WORKDIR}/mtp.log"
MTP_SERVICE="mtp"
MTP_SYSTEMD_DIR="/etc/systemd/system"
MTP_OPENRC_DIR="/etc/init.d"
MTP_OPENRC_PIDFILE="/run/mtp.pid"
MTP_LAUNCHER="$(readlink -f "${BASH_SOURCE[0]}")"
# 上游资产以 "evergreen" tag(Go-Rust)承载，换 tag 时只改 MTP_MTG_VERSION 一处，
# 下载 URL 由它拼出；tag 资产重建时需同步更新下方 MTP_SHA256 或按注释覆盖。
MTP_MTG_VERSION="Go-Rust"
MTP_DOWNLOAD_BASE="https://github.com/jyucoeng/singbox-tools/releases/download/${MTP_MTG_VERSION}"
# MTP 供应链（H-3）：锁定上游 Go-Rust Release 的 mtg-go 资产并 pin SHA256，
# 下载后完整校验才落盘（与 mihomo/cloudflared 强校验模型对齐）。
# 如需覆盖（如上游重新构建），可用环境变量 MTP_SHA256_amd64/MTP_SHA256_arm64 显式指定。
declare -A MTP_SHA256=(
  [amd64]="3653d6a1f47bd51255aa4aebed9ab2197261ad4d2f5954c7a57ef67c610563cf"
  [arm64]="3a03bc716189306a5a697a803285c8fd96ca45069d55178be26e999c6e95768c"
)
# 参考实现内置伪装域名（上游生成器同款列表）
MTP_FAKE_DOMAINS=("www.apple.com" "www.microsoft.com" "www.amazon.com" "www.bing.com" "www.mozilla.org")

# 配置仅按数据解析，绝不 source/eval；所有入口（含 init 原生重启）共用校验。
mtp_valid_secret() { [[ "${1:-}" =~ ^[0-9a-fA-F]{32}$ ]]; }

mtp_valid_domain() {
  local domain="${1:-}" label
  local -a labels=()
  [ "${#domain}" -le 253 ] && [[ "${domain}" == *.* ]] || return 1
  [[ "${domain}" != *[!a-zA-Z0-9.-]* && "${domain}" != *. ]] || return 1
  IFS=. read -r -a labels <<<"${domain}"
  for label in "${labels[@]}"; do
    [ "${#label}" -ge 1 ] && [ "${#label}" -le 63 ] || return 1
    [[ "${label}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
  done
  # DNS 主机名（可用 punycode），不接受 IP、空标签、尾点、URL 或控制字符。
  [[ "${domain##*.}" =~ [a-zA-Z] ]]
}

mtp_domain_hex() { printf '%s' "$1" | od -A n -t x1 | tr -d ' \n'; }

mtp_valid_full_secret() {
  local value="${1:-}" tail domain raw
  [[ "${value}" =~ ^ee[0-9a-fA-F]{32}([0-9a-fA-F]{2})+$ ]] || return 1
  tail="${value:34}"
  [ "${#tail}" -le 506 ] || return 1
  raw="$(printf '%s' "${tail}" | sed 's/../\\x&/g')"
  domain="$(printf '%b' "${raw}")"
  mtp_valid_domain "${domain}" && [ "$(mtp_domain_hex "${domain}")" = "${tail,,}" ]
}

mtp_validate_values() {
  valid_port "$1" || { mtp_print_err "端口必须为 1-65535 的十进制整数。"; return 1; }
  mtp_valid_secret "$2" || { mtp_print_err "mtp_secret 必须恰好为 32 位 hex。"; return 1; }
  mtp_valid_domain "$3" || { mtp_print_err "mtp_domain 必须为有效 DNS 主机名（不含 URL、空白或尾点）。"; return 1; }
  case "$4" in v4 | v6 | dual) ;; *) mtp_print_err "mtp_ip_mode 仅支持 v4 / v6 / dual。"; return 1 ;; esac
}

mtp_load_config() {
  local line key value full_secret="" seen=" "
  MTP_CONFIG_PORT="" MTP_CONFIG_SECRET="" MTP_CONFIG_DOMAIN="" MTP_CONFIG_MODE="v4"
  if [ ! -f "${MTP_CONF}" ] || [ -L "${MTP_CONF}" ]; then
    mtp_print_err "缺少有效配置：${MTP_CONF}"; return 1
  fi
  while IFS= read -r line || [ -n "${line}" ]; do
    [ -n "${line}" ] || continue
    [[ "${line}" == *=* ]] || return 1
    key="${line%%=*}" value="${line#*=}"
    [[ "${seen}" != *" ${key} "* ]] || { mtp_print_err "配置字段重复：${key}"; return 1; }
    seen+="${key} "
    case "${key}" in
      PORT) MTP_CONFIG_PORT="${value}" ;;
      SECRET) full_secret="${value}" ;;
      DOMAIN) MTP_CONFIG_DOMAIN="${value}" ;;
      IP_MODE) MTP_CONFIG_MODE="${value}" ;;
      *) mtp_print_err "未知配置字段：${key}"; return 1 ;;
    esac
  done <"${MTP_CONF}"
  mtp_valid_full_secret "${full_secret}" || { mtp_print_err "已有 SECRET 格式无效，拒绝启动。"; return 1; }
  MTP_CONFIG_SECRET="${full_secret:2:32}"
  mtp_validate_values "${MTP_CONFIG_PORT}" "${MTP_CONFIG_SECRET}" "${MTP_CONFIG_DOMAIN}" "${MTP_CONFIG_MODE}" || return 1
  [ "${full_secret,,}" = "ee${MTP_CONFIG_SECRET,,}$(mtp_domain_hex "${MTP_CONFIG_DOMAIN}")" ] || {
    mtp_print_err "SECRET 的域名与 DOMAIN 不一致，拒绝启动。"; return 1;
  }
}

# 真正的启动只使用数组；mtp_run_args 保留为诊断输出，禁止执行其字符串结果。
mtp_build_argv() {
  local port="$1" secret="$2" ip_mode="${3:-v4}" policy bind
  valid_port "${port}" && mtp_valid_full_secret "${secret}" || return 1
  case "${ip_mode}" in
    v4) policy="only-ipv4"; bind="0.0.0.0:${port}" ;;
    v6) policy="only-ipv6"; bind="[::]:${port}" ;;
    dual) policy="prefer-ipv6"; bind="[::]:${port}" ;;
    *) return 1 ;;
  esac
  MTP_ARGV=(simple-run -n 1.1.1.1 -t 30s -a 1mb -c 65535 -i "${policy}" "${bind}" "${secret}")
}

mtp_config_argv() {
  mtp_load_config || return 1
  mtp_build_argv "${MTP_CONFIG_PORT}" "ee${MTP_CONFIG_SECRET}$(mtp_domain_hex "${MTP_CONFIG_DOMAIN}")" "${MTP_CONFIG_MODE}"
}

mtp_run_args() {
  local port="${1:-}" secret="${2:-}" ip_mode="${3:-v4}"
  if [ -z "${port}" ] || [ -z "${secret}" ]; then
    mtp_config_argv || return 1
  else
    mtp_build_argv "${port}" "${secret}" "${ip_mode}" || return 1
  fi
  printf '%s' "${MTP_ARGV[*]}"
}

# 颜色输出（非 TTY 或 NO_COLOR 时禁用）
supports_color() {
  if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then return 1; fi
  return 0
}

GREEN=""
RED=""
YELLOW=""
BLUE=""
PLAIN=""
if supports_color; then
  GREEN=$'\033[32m'
  RED=$'\033[31m'
  YELLOW=$'\033[33m'
  BLUE=$'\033[34m'
  PLAIN=$'\033[0m'
fi

mtp_print_ok() { echo -e "${GREEN}[OK] $*${PLAIN}"; }
mtp_print_info() { echo -e "${BLUE}[INFO] $*${PLAIN}"; }
mtp_print_warn() { echo -e "${YELLOW}[WARN] $*${PLAIN}"; }
mtp_print_err() { echo -e "${RED}[ERROR] $*${PLAIN}" >&2; }

mtp_fatal() {
  mtp_print_err "$*"
  exit 1
}

is_num() { case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac }

valid_port() {
  local p="$1"
  [[ "${p}" =~ ^[0-9]{1,5}$ ]] && [ "$((10#${p}))" -ge 1 ] && [ "$((10#${p}))" -le 65535 ]
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

download_file() {
  local url="$1" out="$2"
  if command_exists curl; then
    curl -fsSL --retry 3 --connect-timeout 10 "$url" -o "$out"
  elif command_exists wget; then
    wget -qO "$out" "$url"
  else
    mtp_fatal "需要安装 curl 或 wget 才能下载 MTProxy 二进制。"
  fi
}

# H-3：计算文件 SHA256（优先 sha256sum，其次 shasum/openssl）
mtp_sha256() {
  local target="$1"
  if command_exists sha256sum; then
    sha256sum "${target}" | awk '{print $1}'
  elif command_exists shasum; then
    shasum -a 256 "${target}" | awk '{print $1}'
  elif command_exists openssl; then
    openssl dgst -sha256 "${target}" | awk '{print $NF}'
  else
    return 1
  fi
}

# 检测 init 系统
detect_init_system() {
  if [ -d /run/systemd/system ]; then
    INIT_SYSTEM="systemd"
  elif [ -f /sbin/openrc-run ] || [ -f /etc/alpine-release ]; then
    INIT_SYSTEM="openrc"
  elif [ -f /etc/init.d/rcS ] && command -v service >/dev/null 2>&1; then
    INIT_SYSTEM="sysvinit"
  else
    INIT_SYSTEM="unknown"
  fi
}

# 获取本机公网 IPv4/IPv6（自包含实现，不依赖外部库）
get_public_ipv4() {
  local ip url
  for url in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.me"; do
    ip="$(curl -fsS --max-time 5 "$url" 2>/dev/null | tr -d '\r\n' || true)"
    case "$ip" in
    *[!0-9.]*) continue ;;
    esac
    [ -z "$ip" ] && continue
    printf '%s' "$ip"
    return 0
  done
  return 1
}

get_public_ipv6() {
  local ip url
  for url in "https://api64.ipify.org" "https://v6.ipv6-test.com/api/myip.php" "https://ifconfig.co"; do
    ip="$(curl -fsS --max-time 5 "$url" 2>/dev/null | tr -d '\r\n' || true)"
    case "$ip" in
    *:*)
      printf '%s' "$ip"
      return 0
      ;;
    *) continue ;;
    esac
  done
  return 1
}

# 生成 32 位 hex 密钥（16 字节）
generate_secret() {
  head -c 16 /dev/urandom | od -A n -t x1 | tr -d ' \n'
}

random_domain() {
  # Bash RANDOM 不依赖 GNU date 的 %N（BusyBox date 无此格式）。
  local idx
  idx=$((RANDOM % ${#MTP_FAKE_DOMAINS[@]}))
  printf '%s' "${MTP_FAKE_DOMAINS[$idx]}"
}

env_port() {
  local raw="${1:-}"
  [ -n "${raw}" ] || return 1
  valid_port "${raw}" || return 1
  printf '%s' "${raw}"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    mtp_fatal "需要 root 权限，请使用 sudo 或以 root 身份运行。"
  fi
}

is_service_installed() {
  if [ "${INIT_SYSTEM}" = "systemd" ]; then
    [ -f "${MTP_SYSTEMD_DIR}/${MTP_SERVICE}.service" ]
  elif [ "${INIT_SYSTEM}" = "openrc" ]; then
    [ -f "${MTP_OPENRC_DIR}/${MTP_SERVICE}" ]
  else
    [ -f "${MTP_CONF}" ]
  fi
}

print_usage() {
  cat <<EOF
用法: mtp [命令]

命令:
  (无参数)    安装/更新 MTProxy。环境变量 mtpt 指定监听端口；mtp_domain/mtp_secret/mtp_ip_mode 可选。
  info        查看已安装服务连接信息（tg://proxy 链接）
  restart     重启 MTProxy 服务
  un          全量卸载并清理（服务、二进制、配置、日志）
  -h|--help   显示本帮助

环境变量:
  mtpt          监听端口（必填）
  mtp_domain    伪装域名（默认从内置列表随机）
  mtp_secret    通信密钥，32 位 hex（默认随机生成）
  mtp_ip_mode   监听模式 v4 / v6 / dual（默认 v4）
EOF
}

# 生成 tg:// 链接 secret（与上游 show_info_mtg 一致：
# FULL_SECRET = 0xee + secret(32hex 16字节) + domain 字节串，base64 url-safe 无 padding）
mtp_tg_secret() {
  local secret="$1" domain="$2"
  local raw secret_b64
  mtp_validate_values 1 "${secret}" "${domain}" v4 || return 1
  raw="$(printf '%s' "${secret}" | sed 's/../\\x&/g')"
  secret_b64="$(printf '\xee%b%s' "${raw}" "${domain}" | base64 | tr -d '\r\n' | tr '+/' '-_' | tr -d '=')"
  printf '%s' "${secret_b64}"
}

mtp_install_binary() {
  local arch mtg_arch bin_url bin_tmp expected actual override_var
  arch="$(uname -m)"
  case "${arch}" in
  x86_64 | amd64) mtg_arch="amd64" ;;
  aarch64 | arm64) mtg_arch="arm64" ;;
  *)
    mtp_print_err "不支持的 CPU 架构：${arch}（仅支持 x86_64/aarch64）。"
    return 1
    ;;
  esac

  # H-3：锁定 Go-Rust Release 的 mtg-go 并强校验 SHA256（fail-closed）后才落盘。
  # 上游为 dev 构建、发布即重建，故提供 MTP_ALLOW_RUNTIME_VERIFY=1 降级为仅"可执行"校验
  # （与 cloudflared 的 CLOUDFLARED_ALLOW_RUNTIME_VERIFY 模型一致），并输出显著告警。
  override_var="MTP_SHA256_${mtg_arch}"
  if [ -n "${!override_var:-}" ]; then
    expected="${!override_var}"
  else
    expected="${MTP_SHA256[${mtg_arch}]:-}"
  fi
  if [ "${MTP_ALLOW_RUNTIME_VERIFY:-0}" = "1" ]; then
    mtp_print_warn "MTP_ALLOW_RUNTIME_VERIFY=1：跳过 SHA256 强校验，仅验证可执行性（供应链风险自担）。"
    expected=""
  elif [ -z "${expected}" ]; then
    mtp_print_err "缺少 mtg-go(${mtg_arch}) 的 SHA256 校验值（可设置 MTP_SHA256_${mtg_arch}），拒绝安装。"
    return 1
  fi

  if [ -f "${MTP_BIN_DIR}/mtg-go" ] && [ ! -L "${MTP_BIN_DIR}/mtg-go" ]; then
    actual="$(mtp_sha256 "${MTP_BIN_DIR}/mtg-go")" || return 1
    if { [ -n "${expected}" ] && [ "${actual}" = "${expected}" ]; } || [ "${MTP_ALLOW_RUNTIME_VERIFY:-0}" = "1" ]; then
      if [ -x "${MTP_BIN_DIR}/mtg-go" ] && "${MTP_BIN_DIR}/mtg-go" --version >/dev/null 2>&1; then
        mtp_print_info "已验证现有 mtg-go 二进制，跳过下载。"
        return 0
      fi
    fi
    mtp_print_warn "现有 mtg-go 校验失败，将下载并验证替换文件。"
  fi

  mtp_prepare_dirs || return 1
  bin_url="${MTP_DOWNLOAD_BASE}/mtg-go-${mtg_arch}"
  bin_tmp="$(mktemp "${MTP_BIN_DIR}/.mtg-go.XXXXXX")" || return 1
  mtp_print_info "下载 mtg-go (${arch}) ..."
  if ! download_file "${bin_url}" "${bin_tmp}"; then
    rm -f "${bin_tmp}"
    mtp_print_err "下载失败：${bin_url}"
    return 1
  fi
  if [ -n "${expected}" ]; then
    actual="$(mtp_sha256 "${bin_tmp}")" || {
      rm -f "${bin_tmp}"
      mtp_print_err "无法计算 mtg-go 校验值（需 sha256sum 或 shasum/openssl），已放弃安装。"
      return 1
    }
    if [ "${actual}" != "${expected}" ]; then
      rm -f "${bin_tmp}"
      mtp_print_err "mtg-go 下载校验不匹配，已拒绝安装（期望 ${expected}，实际 ${actual}）。"
      return 1
    fi
  fi
  chmod 0755 "${bin_tmp}"
  if ! "${bin_tmp}" --version >/dev/null 2>&1; then
    rm -f "${bin_tmp}"
    mtp_print_err "下载的 mtg-go 二进制无法执行，已放弃（可能下载到损坏文件）。"
    return 1
  fi
  mv -f "${bin_tmp}" "${MTP_BIN_DIR}/mtg-go"
  chmod 0755 "${MTP_BIN_DIR}/mtg-go"
  mtp_print_ok "mtg-go 安装完成：${MTP_BIN_DIR}/mtg-go"
}

# 生成模板仅接受固定安全路径，避免 systemd 的 %/$ 展开和 OpenRC shell 语法。
mtp_validate_paths() {
  local path
  for path in "${MTP_WORKDIR}" "${MTP_BIN_DIR}" "${MTP_CONF}" "${MTP_LOG}" "${MTP_LAUNCHER}"; do
    [[ "${path}" =~ ^/[a-zA-Z0-9_./-]+$ ]] || { mtp_print_err "不支持的安装路径：${path}"; return 1; }
  done
  [[ "${MTP_SERVICE}" =~ ^[a-zA-Z0-9_-]+$ ]]
}

mtp_prepare_dirs() {
  local dir
  for dir in "${MTP_WORKDIR}" "${MTP_BIN_DIR}"; do
    [ ! -L "${dir}" ] || return 1
    mkdir -p "${dir}" && chmod 0700 "${dir}" || return 1
  done
}

# 同目录 mktemp + rename：敏感内容从首字节起即为 0600，不跟随旧目标符号链接。
mtp_atomic_write() (
  local target="$1" mode="${2:-0600}" tmp
  umask 077
  [ ! -L "${target}" ] || { mtp_print_err "拒绝写入符号链接：${target}"; exit 1; }
  tmp="$(mktemp "${target}.tmp.XXXXXX")" || exit 1
  trap 'rm -f "${tmp}"' EXIT
  cat >"${tmp}" && chmod "${mode}" "${tmp}" && mv -f "${tmp}" "${target}"
)

mtp_pid_start_time() {
  local stat
  local -a fields=()
  IFS= read -r stat <"/proc/$1/stat" || return 1
  read -r -a fields <<<"${stat##*) }"
  [[ "${fields[19]:-}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "${fields[19]}"
}

mtp_pid_matches() {
  local pid="${1:-}" expected_start="${2:-}" arg bin i
  local -a actual=()
  [[ "${pid}" =~ ^[0-9]+$ ]] && [ "${pid}" -gt 1 ] || return 1
  bin="$(readlink -f "${MTP_BIN_DIR}/mtg-go")" || return 1
  [ "$(readlink "/proc/${pid}/exe" 2>/dev/null)" = "${bin}" ] || return 1
  [ -z "${expected_start}" ] || [ "$(mtp_pid_start_time "${pid}")" = "${expected_start}" ] || return 1
  while IFS= read -r -d '' arg; do actual+=("${arg}"); done <"/proc/${pid}/cmdline"
  [ "${#actual[@]}" -eq 14 ] && [ "${actual[0]}" = "${MTP_BIN_DIR}/mtg-go" ] || return 1
  # 与已验证的当前配置逐项比较，拒绝同名程序、其他代理实例和被复用的 PID。
  mtp_config_argv || return 1
  for ((i=0; i<${#MTP_ARGV[@]}; i++)); do
    [ "${actual[i+1]}" = "${MTP_ARGV[i]}" ] || return 1
  done
}

# 旧版本曾把 sh -c 的 PID 写入文件。仅迁移与已验证配置完全相同的旧命令，
# 且只处理 /proc 证明的唯一直接子进程；不执行旧命令，不按名字扫描或 pkill。
mtp_legacy_child() {
  local wrapper="$1" arg expected child shell_bin
  local -a args=() children=()
  mtp_config_argv && mtp_validate_paths || return 1
  shell_bin="$(readlink -f "$(command -v sh)")" || return 1
  [ "$(readlink "/proc/${wrapper}/exe" 2>/dev/null)" = "${shell_bin}" ] || return 1
  while IFS= read -r -d '' arg; do args+=("${arg}"); done <"/proc/${wrapper}/cmdline"
  [ "${#args[@]}" -eq 3 ] && [ "${args[1]}" = -c ] || return 1
  case "${args[0]}" in sh | /bin/sh | /usr/bin/sh) ;; *) return 1 ;; esac
  expected="${MTP_BIN_DIR}/mtg-go ${MTP_ARGV[*]} >>${MTP_LOG} 2>&1"
  [ "${args[2]}" = "${expected}" ] || return 1
  read -r -a children <"/proc/${wrapper}/task/${wrapper}/children" || [ "${#children[@]}" -gt 0 ] || return 1
  [ "${#children[@]}" -eq 1 ] || return 1
  child="${children[0]}"
  mtp_pid_matches "${child}" || return 1
  # argv 还必须对应旧配置，不能只凭相同的可执行文件名。
  [ "${MTP_BIN_DIR}/mtg-go ${MTP_ARGV[*]} >>${MTP_LOG} 2>&1" = "${expected}" ] || return 1
  printf '%s' "${child}"
}

mtp_stop_process() {
  local pid start extra i pidfile="${1:-${MTP_WORKDIR}/mtp.pid}"
  [ -e "${pidfile}" ] || [ -L "${pidfile}" ] || return 0
  [ -f "${pidfile}" ] && [ ! -L "${pidfile}" ] || return 1
  read -r pid start extra <"${pidfile}" || return 1
  if ! [[ "${pid}" =~ ^[0-9]+$ && "${start:-0}" =~ ^[0-9]+$ && -z "${extra}" ]] || [ "${pid}" -le 1 ]; then
    mtp_print_err "PID 文件无效，拒绝终止进程。"; return 1
  fi
  if [ ! -d "/proc/${pid}" ]; then rm -f "${pidfile}"; return 0; fi
  if ! mtp_pid_matches "${pid}" "${start}"; then
    if [ -n "${start}" ]; then
      mtp_print_err "PID 身份不匹配，拒绝终止进程 ${pid}。"; return 1
    fi
    pid="$(mtp_legacy_child "${pid}")" || { mtp_print_err "旧 PID 无法安全迁移，拒绝终止。"; return 1; }
    start="$(mtp_pid_start_time "${pid}")" || return 1
    mtp_pid_matches "${pid}" "${start}" || return 1
  fi
  kill -TERM "${pid}" || return 1
  for ((i=0; i<50; i++)); do
    if ! mtp_pid_matches "${pid}" "${start}"; then rm -f "${pidfile}"; return 0; fi
    sleep 0.1
  done
  # 再次核验身份才升级信号，不使用全局 pkill。
  mtp_pid_matches "${pid}" "${start}" && kill -KILL "${pid}" || return 1
  for ((i=0; i<20; i++)); do
    if ! mtp_pid_matches "${pid}" "${start}"; then rm -f "${pidfile}"; return 0; fi
    sleep 0.1
  done
  mtp_print_err "旧 MTProxy 进程未退出，拒绝启动第二个实例。"
  return 1
}

# OpenRC 基线使用 /run/mtp.pid；覆盖旧脚本/二进制前，先按同样的身份规则停止它。
mtp_stop_managed_processes() {
  mtp_stop_process || return 1
  if [ "${INIT_SYSTEM:-}" = openrc ]; then
    mtp_stop_process "${MTP_OPENRC_PIDFILE}" || return 1
  fi
}

mtp_start_process() {
  local pid start i
  mtp_config_argv && mtp_validate_paths && mtp_prepare_dirs || return 1
  mtp_stop_managed_processes || return 1
  # stop 的身份校验也会构建 argv，重新加载当前配置供新进程使用。
  mtp_config_argv || return 1
  [ ! -L "${MTP_LOG}" ] && { [ ! -e "${MTP_LOG}" ] || [ -f "${MTP_LOG}" ]; } || return 1
  : >>"${MTP_LOG}"
  chmod 0600 "${MTP_LOG}" || return 1
  nohup "${MTP_BIN_DIR}/mtg-go" "${MTP_ARGV[@]}" >>"${MTP_LOG}" 2>&1 </dev/null &
  pid=$!
  for ((i=0; i<30; i++)); do
    if mtp_pid_matches "${pid}"; then
      start="$(mtp_pid_start_time "${pid}")" || return 1
      if ! printf '%s %s\n' "${pid}" "${start}" | mtp_atomic_write "${MTP_WORKDIR}/mtp.pid"; then
        mtp_pid_matches "${pid}" "${start}" && kill -TERM "${pid}"
        return 1
      fi
      sleep 0.1
      mtp_pid_matches "${pid}" "${start}" && return 0
      break
    fi
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.1
  done
  mtp_print_err "MTProxy 启动失败，请检查 ${MTP_LOG}。"
  return 1
}

mtp_run_service() {
  # systemd 直接托管 exec 后的真实 mtg PID；OpenRC/独立模式调用 start-service。
  mtp_config_argv && mtp_validate_paths || return 1
  exec "${MTP_BIN_DIR}/mtg-go" "${MTP_ARGV[@]}"
}

mtp_create_service() {
  local port="$1" secret="$2" domain="$3" ip_mode="$4" bash_bin
  mtp_validate_values "${port}" "${secret}" "${domain}" "${ip_mode}" && mtp_validate_paths || return 1
  mtp_prepare_dirs || return 1
  # 升级先停用当前手工实例；保留旧二进制时仍可核验 legacy 单 PID 文件。
  mtp_stop_managed_processes || return 1
  port="$((10#${port}))"
  mtp_atomic_write "${MTP_CONF}" <<EOF || return 1
PORT=${port}
SECRET=ee${secret}$(mtp_domain_hex "${domain}")
DOMAIN=${domain}
IP_MODE=${ip_mode}
EOF
  bash_bin="$(command -v bash)"
  [[ "${bash_bin}" =~ ^/[a-zA-Z0-9_./-]+$ ]] || return 1
  if [ "${INIT_SYSTEM}" = "systemd" ]; then
    mtp_atomic_write "${MTP_SYSTEMD_DIR}/${MTP_SERVICE}.service" <<EOF || return 1
[Unit]
Description=MTProto Proxy (Go - mtg)
After=network.target

[Service]
Type=simple
ExecStart=${bash_bin} ${MTP_LAUNCHER} run-service
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable "${MTP_SERVICE}" >/dev/null 2>&1 && systemctl restart "${MTP_SERVICE}"
  elif [ "${INIT_SYSTEM}" = "openrc" ]; then
    # OpenRC 不再内嵌 secret/command_args；每次原生 start 都执行受校验的数组启动。
    mtp_atomic_write "${MTP_OPENRC_DIR}/${MTP_SERVICE}" 0700 <<EOF || return 1
#!/sbin/openrc-run
name="${MTP_SERVICE}"
description="MTProto Proxy (Go)"
rc_ulimit="-n 65535"
depend() { need net; }
start() { "${bash_bin}" "${MTP_LAUNCHER}" start-service; }
stop() { "${bash_bin}" "${MTP_LAUNCHER}" stop-service; }
status() { "${bash_bin}" "${MTP_LAUNCHER}" status-service; }
EOF
    rc-update add "${MTP_SERVICE}" default >/dev/null 2>&1 && rc-service "${MTP_SERVICE}" restart
  else
    mtp_start_process || return 1
    mtp_print_warn "未检测到 systemd/openrc，已直接后台运行 MTProxy。"
  fi
}

mtp_show_info() {
  local port secret domain ip_mode ipv4 ipv6 tg_secret
  if [ ! -f "${MTP_CONF}" ]; then
    mtp_print_err "MTProxy 尚未安装（缺少 ${MTP_CONF}）。先运行：mtpt=端口 mtp"
    return 1
  fi
  mtp_load_config || return 1
  port="${MTP_CONFIG_PORT}" secret="${MTP_CONFIG_SECRET}"
  domain="${MTP_CONFIG_DOMAIN}" ip_mode="${MTP_CONFIG_MODE}"

  ipv4="$(get_public_ipv4 || true)"
  ipv6="$(get_public_ipv6 || true)"
  tg_secret="$(mtp_tg_secret "${secret}" "${domain}")"

  echo -e "=============================="
  echo -e "${GREEN}MTProxy (Go mtg) 连接信息${PLAIN}"
  echo -e "端口: ${port}"
  echo -e "Secret: ${tg_secret}"
  echo -e "Domain: ${domain}"
  echo -e "监听模式: ${ip_mode}"
  echo -e "------------------------------"
  if [ -n "${ipv4}" ]; then
    echo -e "${GREEN}IPv4 链接:${PLAIN}"
    echo "tg://proxy?server=${ipv4}&port=${port}&secret=${tg_secret}"
  else
    echo -e "${YELLOW}未检测到 IPv4 地址${PLAIN}"
  fi
  if [ "${ip_mode}" = "v6" ] || [ "${ip_mode}" = "dual" ]; then
    if [ -n "${ipv6}" ]; then
      echo -e "${GREEN}IPv6 链接:${PLAIN}"
      echo "tg://proxy?server=${ipv6}&port=${port}&secret=${tg_secret}"
    else
      echo -e "${YELLOW}未检测到 IPv6 地址${PLAIN}"
    fi
  fi
  echo -e "=============================="
}

mtp_process_status() {
  local pid start extra
  [ -f "${MTP_WORKDIR}/mtp.pid" ] && [ ! -L "${MTP_WORKDIR}/mtp.pid" ] || return 1
  read -r pid start extra <"${MTP_WORKDIR}/mtp.pid" || return 1
  [ -z "${extra}" ] && mtp_pid_matches "${pid}" "${start}" || return 1
  printf '%s\n' 'started'
}

mtp_status() {
  local active
  if [ ! -f "${MTP_CONF}" ]; then
    mtp_print_err "MTProxy 未安装。"
    return 1
  fi
  case "${INIT_SYSTEM}" in
  systemd)
    active="$(systemctl is-active "${MTP_SERVICE}" 2>/dev/null || echo inactive)"
    echo -e "服务: ${MTP_SERVICE} (systemd) ${GREEN}${active}${PLAIN}"
    ;;
  openrc)
    active="$(rc-service "${MTP_SERVICE}" status 2>/dev/null | grep -qi 'started' && echo started || echo stopped)"
    echo -e "服务: ${MTP_SERVICE} (openrc) ${GREEN}${active}${PLAIN}"
    ;;
  *)
    active="$(mtp_process_status || printf 'stopped')"
    echo -e "服务: ${MTP_SERVICE} (无服务管理器) ${active}"
    ;;
  esac
}

# 安装/更新主流程
mtp_install() {
  local port domain secret ip_mode old_port=""
  require_root
  detect_init_system
  port="$(env_port "${mtpt:-}")" || {
    mtp_print_err "缺少有效的监听端口：mtpt=端口（1-65535）"; return 1;
  }
  domain="${mtp_domain:-}" secret="${mtp_secret:-}" ip_mode="${mtp_ip_mode:-}"
  if [ -e "${MTP_CONF}" ] || [ -L "${MTP_CONF}" ]; then
    mtp_load_config || return 1
    old_port="${MTP_CONFIG_PORT}"
    # 独立回填，显式修改一个字段不会轮换另一字段；旧版无 IP_MODE 时用 v4。
    [ -n "${domain}" ] || domain="${MTP_CONFIG_DOMAIN}"
    [ -n "${secret}" ] || secret="${MTP_CONFIG_SECRET}"
    [ -n "${ip_mode}" ] || ip_mode="${MTP_CONFIG_MODE}"
  fi
  [ -n "${domain}" ] || domain="$(random_domain)"
  [ -n "${secret}" ] || secret="$(generate_secret)"
  ip_mode="${ip_mode:-v4}"
  mtp_validate_values "${port}" "${secret}" "${domain}" "${ip_mode}" && mtp_validate_paths || return 1
  if [ -n "${old_port}" ] && [ "${port}" != "${old_port}" ]; then
    mtp_print_info "监听端口变更：${old_port} → ${port}"
  fi
  # 二进制更换前核验并停止旧的手工实例，避免 /proc/exe 指向被替换文件。
  mtp_stop_managed_processes || return 1
  mtp_install_binary || return 1
  mtp_create_service "${port}" "${secret}" "${domain}" "${ip_mode}" || return 1
  mtp_status || true
  mtp_show_info || return 1
  mtp_print_ok "MTProxy 安装/更新完成。"
}

mtp_restart() {
  require_root
  detect_init_system
  mtp_load_config || return 1
  # 重建模板使旧版 unit/OpenRC 脚本一并迁移；所有 init 分支使用已验证值。
  mtp_create_service "${MTP_CONFIG_PORT}" "${MTP_CONFIG_SECRET}" "${MTP_CONFIG_DOMAIN}" "${MTP_CONFIG_MODE}" || return 1
  mtp_print_ok "已重启 ${MTP_SERVICE}。"
}

mtp_uninstall() {
  require_root
  detect_init_system
  if ! is_service_installed && [ ! -d "${MTP_WORKDIR}" ]; then
    mtp_print_info "MTProxy 未安装，无需卸载。"
    return 0
  fi
  case "${INIT_SYSTEM}" in
  systemd)
    systemctl disable --now "${MTP_SERVICE}" >/dev/null 2>&1 || true
    rm -f "${MTP_SYSTEMD_DIR}/${MTP_SERVICE}.service"
    systemctl daemon-reload || true
    ;;
  openrc)
    mtp_stop_managed_processes || return 1
    rc-update del "${MTP_SERVICE}" default >/dev/null 2>&1 || true
    rc-service "${MTP_SERVICE}" stop >/dev/null 2>&1 || true
    rm -f "${MTP_OPENRC_DIR}/${MTP_SERVICE}"
    ;;
  *)
    mtp_stop_managed_processes || return 1
    ;;
  esac
  rm -rf "${MTP_WORKDIR}"
  mtp_print_ok "MTProxy 已全量卸载并清理。"
}

main() {
  local action="${1:-}"
  case "${action}" in
  run-service)
    require_root
    mtp_run_service
    ;;
  start-service)
    require_root
    detect_init_system
    mtp_start_process
    ;;
  stop-service)
    require_root
    detect_init_system
    mtp_stop_managed_processes
    ;;
  status-service)
    mtp_process_status
    ;;
  "")
    mtp_install
    ;;
  info)
    require_root
    detect_init_system
    mtp_show_info
    ;;
  restart)
    mtp_restart
    ;;
  un)
    mtp_uninstall
    ;;
  -h | --help | help)
    print_usage
    exit 0
    ;;
  *)
    mtp_print_warn "未知命令：${action}"
    print_usage
    exit 1
    ;;
  esac
}

if [ "${MTP_TEST_MODE:-0}" != "1" ]; then
  # 测试钩子：MTP_TEST_MODE=1 时供 tests/smoke.sh source 本文件做函数级验证
  main "$@"
fi
