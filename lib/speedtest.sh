#!/usr/bin/env bash
set -eEuo pipefail

umask 077

# Existing local executables are administrator-provided; the version probe identifies
# the CLI but is not a cryptographic trust assertion. Downloads require pinned SHA256.
speedtest_timeout_seconds() {
  local seconds="${NET_TUNE_SPEEDTEST_TIMEOUT-90}"
  [[ "${seconds}" =~ ^[1-9][0-9]{0,3}$ ]] && ((seconds <= 3600)) || return 1
  printf '%s' "${seconds}"
}

speedtest_measurement_allowed() {
  [ "${LOCK_HELD:-false}" != true ] || { print_warn "测速不能在持有全局锁时运行。"; return 1; }
  [ -z "${NET_TUNE_SKIP_SPEEDTEST:-}" ] && [ "${NET_TUNE_ALLOW_SPEEDTEST:-0}" = 1 ]
}

find_ookla_speedtest() {
  local bin resolved version
  local -a candidates=("${BASE_DIR}/bin/speedtest")
  if bin="$(type -P speedtest)" && [ -n "${bin}" ]; then candidates+=("${bin}"); fi
  for bin in "${candidates[@]}"; do
    if [ ! -f "${bin}" ] || [ ! -x "${bin}" ]; then continue; fi
    resolved="$(readlink -f -- "${bin}")" || continue
    case "${resolved}" in /*) ;; *) continue ;; esac
    command_exists timeout || return 1
    version="$(timeout -k 2 5 "${resolved}" --version 2>/dev/null)" || continue
    case "${version}" in *'Speedtest by Ookla'*) printf '%s' "${resolved}"; return 0 ;; esac
  done
  return 1
}

speedtest_download_url() {
  [[ "${OOKLA_SPEEDTEST_VERSION:-}" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || return 1
  case "$(uname -m)" in
  x86_64) printf 'https://install.speedtest.net/app/cli/ookla-speedtest-%s-linux-x86_64.tgz' "${OOKLA_SPEEDTEST_VERSION}" ;;
  aarch64) printf 'https://install.speedtest.net/app/cli/ookla-speedtest-%s-linux-aarch64.tgz' "${OOKLA_SPEEDTEST_VERSION}" ;;
  *) return 1 ;;
  esac
}

ensure_ookla_speedtest() (
  local bin url tmp_dir arch expected actual version
  speedtest_measurement_allowed && speedtest_timeout_seconds >/dev/null || return 1
  arch="$(uname -m)" || return 1
  case "${arch}" in x86_64 | aarch64) ;; *) return 1 ;; esac
  [[ "$(declare -p OOKLA_SHA256 2>/dev/null)" == 'declare -A '* ]] || return 1
  expected="${OOKLA_SHA256[${arch}]:-}"
  if ! [[ "${expected}" =~ ^[[:xdigit:]]{64}$ ]]; then
    print_warn "speedtest 缺少可信 SHA256，拒绝下载。"
    return 1
  fi
  # All prerequisites and the digest are checked before ANY download or publication.
  command_exists curl || command_exists wget || return 1
  command_exists tar && command_exists timeout || return 1
  command_exists sha256sum || command_exists shasum || return 1
  url="$(speedtest_download_url)" || return 1
  [ ! -L "${BASE_DIR}/bin" ] || return 1
  mkdir -p -- "${BASE_DIR}/bin" || return 1
  bin="${BASE_DIR}/bin/speedtest"
  [ ! -L "${bin}" ] && { [ ! -e "${bin}" ] || [ -f "${bin}" ]; } || return 1
  tmp_dir="$(mktemp -d "${BASE_DIR}/bin/.st.XXXXXX")" || return 1
  trap 'rm -rf -- "${tmp_dir}"' EXIT
  if command_exists curl; then
    curl -fsSL --retry 2 --connect-timeout 10 --max-time 90 "${url}" -o "${tmp_dir}/t.tgz" || return 1
  else
    wget -q --tries=2 --timeout=90 -O "${tmp_dir}/t.tgz" "${url}" || return 1
  fi
  if command_exists sha256sum; then
    actual="$(sha256sum "${tmp_dir}/t.tgz")" || return 1
  else
    actual="$(shasum -a 256 "${tmp_dir}/t.tgz")" || return 1
  fi
  actual="${actual%% *}"
  if [ "${actual,,}" != "${expected,,}" ]; then
    print_warn "speedtest 下载校验不匹配，已弃用。"
    return 1
  fi
  # Extract only the required member, never arbitrary archive paths.
  tar -xzf "${tmp_dir}/t.tgz" -C "${tmp_dir}" -- speedtest || return 1
  [ -f "${tmp_dir}/speedtest" ] && [ ! -L "${tmp_dir}/speedtest" ] || return 1
  chmod 0755 "${tmp_dir}/speedtest" || return 1
  version="$(timeout -k 2 5 "${tmp_dir}/speedtest" --version 2>/dev/null)" || return 1
  case "${version}" in *'Speedtest by Ookla'*) ;; *) return 1 ;; esac
  mv -f -- "${tmp_dir}/speedtest" "${bin}" || return 1
)

run_speedtest_metrics() {
  local bin="${1:-}" seconds out metric up lat
  [ "${LOCK_HELD:-false}" != true ] || return 1
  seconds="$(speedtest_timeout_seconds)" || return 1
  command_exists timeout || return 1
  [ -f "${bin}" ] && [ -x "${bin}" ] || return 1
  case "${bin}" in /*) ;; *) return 1 ;; esac
  # One bounded invocation. Text output from older CLIs can be parsed from this
  # same invocation; invalid JSON or an exit error never triggers a second test.
  out="$(timeout -k 5 "${seconds}" "${bin}" --accept-license --accept-gdpr --format=json 2>/dev/null)" || return 1
  if metric="$(printf '%s' "${out}" | jq -er '
      .upload.bandwidth as $b | .ping.latency as $l |
      select(($b|type)=="number" and $b>0 and $b<=100000000000000 and ($b|floor)==$b) |
      select($l==null or (($l|type)=="number" and $l>=0 and $l<=3600000)) |
      "\(($b*8/1000000)|floor) \(if $l==null then "" else ($l|floor|tostring) end)"' 2>/dev/null)"; then
    up="${metric%% *}"; lat="${metric#* }"
    [[ "${up}" =~ ^[0-9]{1,9}$ ]] && [[ "${lat}" =~ ^[0-9]{0,7}$ ]] || return 1
    printf '%s' "${metric}"
    return 0
  fi
  # Ookla bandwidth is bytes/s in JSON; human output already uses Mbit/s.
  printf '%s' "${out}" | grep -qi 'FAILED\|error' && return 1
  up="$(printf '%s\n' "${out}" | sed -nE 's/^[[:space:]]*[Uu]pload:[[:space:]]*([0-9]+(\.[0-9]+)?)[[:space:]]+(Mbit\/s|Mbps)([[:space:]].*)?$/\1/p' | head -n1)" || return 1
  lat="$(printf '%s\n' "${out}" | sed -nE 's/^[[:space:]]*([Ii]dle )?[Ll]atency:[[:space:]]*([0-9]+(\.[0-9]+)?)[[:space:]]+ms.*/\2/p' | head -n1)" || return 1
  [[ "${up}" =~ ^[0-9]{1,8}(\.[0-9]+)?$ ]] || return 1
  up="${up%.*}"
  if [[ "${lat}" =~ ^[0-9]{1,7}(\.[0-9]+)?$ ]]; then
    lat="${lat%.*}"; lat="$((10#${lat}))"
  else
    lat=""
  fi
  printf '%s %s' "$((10#${up}))" "${lat}"
}

run_speedtest() {
  local metric
  metric="$(run_speedtest_metrics "${1:-}")" || return 1
  printf '%s' "${metric%% *}"
}

measure_net_metrics() {
  local bin
  speedtest_measurement_allowed && speedtest_timeout_seconds >/dev/null || return 1
  command_exists timeout || return 1
  if ! bin="$(find_ookla_speedtest)"; then
    ensure_ookla_speedtest || return 1
    bin="$(find_ookla_speedtest)" || return 1
  fi
  run_speedtest_metrics "${bin}"
}

measure_net_bandwidth() {
  local metric
  metric="$(measure_net_metrics)" || return 1
  printf '%s' "${metric%% *}"
}

# Read-only probe: call before taking the manager lock, then persist/apply the
# result in a short transaction. Explicit CLI speed commands may set the opt-in.
probe_net_tune() {
  local answer
  [ "${LOCK_HELD:-false}" != true ] || { print_warn "请先释放全局锁再测速。"; return 1; }
  [ -z "${NET_TUNE_SKIP_SPEEDTEST:-}" ] && [ "${MM_TEST_MODE:-0}" != 1 ] || return 1
  if [ "${NET_TUNE_ALLOW_SPEEDTEST:-0}" != 1 ]; then
    [ -t 0 ] || return 1
    print_info "测速将连接 Ookla、消耗网络流量，并接受其许可与隐私条款。" >&2
    read -r -p '是否现在测速？[y/N]: ' answer || return 1
    case "${answer}" in y | Y | yes | YES) ;; *) return 1 ;; esac
  fi
  NET_TUNE_ALLOW_SPEEDTEST=1 measure_net_metrics
}

infer_net_tune_region() {
  local latency="${1:-}"
  if [[ "${latency}" =~ ^[0-9]+$ ]] && [ "${latency}" -ge 150 ]; then
    printf '%s' "overseas"
  else
    printf '%s' "asia"
  fi
}

net_tune_confirm_measurement() {
  local bandwidth="$1" latency="$2" region="$3" cap_mb buffer_mb
  local answer new_bw new_lat
  [ "${LOCK_HELD:-false}" != true ] || return 1
  if [ "${MM_TEST_MODE:-0}" = "1" ] || [ ! -t 0 ] || [ "${NET_TUNE_SKIP_CONFIRM:-0}" = "1" ]; then
    printf '%s %s' "${bandwidth}" "${latency}"
    return 0
  fi
  cap_mb="$(get_tcp_buffer_cap_mb)"
  buffer_mb="$(calculate_net_tune_buffer_mb "${bandwidth}" "${region}")"
  echo >&2
  print_info "net_tune 自动测速结果：约 ${COLOR_NUM_HL}${bandwidth}${COLOR_RESET} Mbps${latency:+，延迟约 ${COLOR_NUM_HL}${latency}${COLOR_RESET} ms}（${region} 档）。" >&2
  print_info "推荐 TCP 缓冲：${COLOR_NUM_HL}${buffer_mb}${COLOR_RESET}MB（内存上限 ${COLOR_NUM_HL}${cap_mb}${COLOR_RESET}MB 内）。" >&2
  while true; do
    print_info "网络不佳时自动测速常有误差，可输入  新带宽 新延迟  覆写。" >&2
    read -r -p "直接回车确认，或输入新值（格式：带宽 延迟，如 500 120）: " answer || true
    answer="$(printf '%s' "${answer}" | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if [ -z "${answer}" ]; then
      break
    fi
    new_bw="$(printf '%s' "${answer}" | awk '{print $1}')"
    new_lat="$(printf '%s' "${answer}" | awk '{print $2}')"
    if [[ "${new_bw}" =~ ^[0-9]+$ ]] && [ "${new_bw}" -gt 0 ]; then
      bandwidth="${new_bw}"
      [[ "${new_lat}" =~ ^[0-9]+$ ]] && latency="${new_lat}"
      if [ -n "${latency}" ]; then
        print_ok "已覆写：带宽 ${COLOR_NUM_HL}${bandwidth}${COLOR_RESET} Mbps，延迟 ${COLOR_NUM_HL}${latency}${COLOR_RESET} ms。" >&2
      else
        print_ok "已覆写：带宽 ${COLOR_NUM_HL}${bandwidth}${COLOR_RESET} Mbps，延迟 未测 ms。" >&2
      fi
      break
    fi
    print_warn "输入无效，应为两个正整数（带宽 延迟）。"
  done
  printf '%s %s' "${bandwidth}" "${latency}"
}
