#!/usr/bin/env bash
# Run against the pinned real Linux Mihomo binary; never downloads or installs services.
# Usage: MIHOMO_BIN=/absolute/path/mihomo bash tests/accept-mihomo.sh
# shellcheck disable=SC1090,SC2034,SC2016
set -eEuo pipefail
umask 077
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIHOMO_BIN="${MIHOMO_BIN:-/tmp/opencode/mihomo}"
[ -x "$MIHOMO_BIN" ] || { printf 'Missing real Mihomo binary: %s\n' "$MIHOMO_BIN" >&2; exit 2; }
MIHOMO_BIN="$(readlink -f -- "$MIHOMO_BIN")"
[ "$(od -An -tx1 -N4 "$MIHOMO_BIN" | tr -d ' \n')" = 7f454c46 ] || {
  printf 'Acceptance requires a real Linux ELF binary.\n' >&2; exit 2;
}
for tool in jq python3 openssl ss; do command -v "$tool" >/dev/null || exit 2; done
TEST_ROOT="$(mktemp -d)"
export BASE_DIR="$TEST_ROOT/etc" LIB_DIR="$TEST_ROOT/lib" INSTALL_BIN="$TEST_ROOT/mm"
export LOCK_ROOT="$TEST_ROOT/locks" LOCK_FILE="$TEST_ROOT/locks/accept.lock" MM_TEST_MODE=1
export MIHOMO_DATA_DIR="$TEST_ROOT/etc/data" PUBLIC_IP_CACHE=8.8.8.8
export HOME="$TEST_ROOT/home" XDG_CONFIG_HOME="$TEST_ROOT/home/.config"
export clash_api=0 dns_servers=off ip_version=auto net_tune=off
mkdir -p "$HOME"
source "$ROOT_DIR/mm.sh"
KERNEL_PID=''
stop_kernel() {
  local i
  [ -n "$KERNEL_PID" ] || return 0
  kill -TERM "$KERNEL_PID" 2>/dev/null || true
  for ((i=0; i<30; i++)); do kill -0 "$KERNEL_PID" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$KERNEL_PID" 2>/dev/null; then kill -KILL "$KERNEL_PID" 2>/dev/null || true; fi
  wait "$KERNEL_PID" 2>/dev/null || true
  KERNEL_PID=''
}
cleanup_accept() {
  local status=$?
  trap - EXIT ERR
  stop_kernel
  release_lock
  if [ "$status" -ne 0 ]; then
    printf 'Acceptance failed; kernel output follows.\n' >&2
    [ ! -f "$TEST_ROOT/kernel.log" ] || while IFS= read -r line; do printf '%s\n' "$line" >&2; done <"$TEST_ROOT/kernel.log"
  fi
  rm -rf -- "$TEST_ROOT"
  exit "$status"
}
trap cleanup_accept EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# mm.sh installs an ERR trap, but EXIT here owns process and sandbox cleanup.
trap - ERR
for helper in mihomo_run mihomo_validate mihomo_data_dir mihomo_safe_paths; do
  declare -F "$helper" >/dev/null || { printf 'Missing production helper %s\n' "$helper" >&2; exit 1; }
done
version="$("$MIHOMO_BIN" -v)"
[[ "$version" == *" $MIHOMO_VERSION "* ]] || { printf 'Unexpected kernel: %s\n' "$version" >&2; exit 2; }
printf 'Real kernel: %s\n' "$version"
acquire_lock
init_storage
mkdir -p "$(mihomo_data_dir)"
# Reserve both transports and families until all candidate numbers are selected.
mapfile -t PORTS < <(python3 - <<'PY'
import socket
held = []
ports = []
while len(ports) < 9:
    trial = []
    try:
        tcp4 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        trial.append(tcp4)
        tcp4.bind(('0.0.0.0', 0))
        port = tcp4.getsockname()[1]
        for family, kind, addr in [(socket.AF_INET, socket.SOCK_DGRAM, '0.0.0.0'),
                                   (socket.AF_INET6, socket.SOCK_STREAM, '::'),
                                   (socket.AF_INET6, socket.SOCK_DGRAM, '::')]:
            s = socket.socket(family, kind)
            trial.append(s)
            if family == socket.AF_INET6:
                s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            s.bind((addr, port))
        held.extend(trial)
        ports.append(port)
    except OSError:
        for s in trial:
            s.close()
for port in ports:
    print(port)
PY
)
[ "${#PORTS[@]}" -eq 9 ] || { printf 'Cannot allocate dual-stack ports.\n' >&2; exit 1; }
CERT="$CERT_DIR/accept.crt"
KEY="$CERT_DIR/accept.key"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$KEY" -out "$CERT" -days 2 -subj /CN=example.com >/dev/null 2>&1
keypair="$("$MIHOMO_BIN" generate reality-keypair)"
private_key="$(printf '%s\n' "$keypair" | awk '/^PrivateKey:/ {print $2}')"
public_key="$(printf '%s\n' "$keypair" | awk '/^PublicKey:/ {print $2}')"
[ -n "$private_key" ] && [ -n "$public_key" ]
uuid=b8b1e0c5-ffd5-487f-a7f2-e72faa8fba7b
special_name=$'MiXeD-测试\nname\tquote\'"\\end'
special_password=$'pw\nline\rreturn\ttab\bback\aalert\'"\\end'
add_fixture() {
  local tag="$1" protocol="$2" port="$3" extra="${4:-}" node secret
  [ -n "$extra" ] || extra='{}'
  node="$(jq -n --arg protocol "$protocol" --arg name "$special_name" --argjson port "$port" \
    --arg cert "$CERT" --arg key "$KEY" --arg pub "$public_key" --argjson extra "$extra" \
    '{protocol:$protocol,name:$name,port:$port,certificate_path:$cert,key_path:$key,
      public_key:$pub,short_id:"0123456789abcdef,abcdef0123456789",reality_server:"example.com",
      username:"accept-user",ws_path:"/accept",certificate_mode:"self-signed"} + $extra')"
  secret="$(jq -n --arg uuid "$uuid" --arg private "$private_key" --arg password "$special_password" \
    '{uuid:$uuid,private_key:$private,password:$password}')"
  save_node_bundle "$tag" "$node" "$secret"
}
add_fixture nreality vless-reality "${PORTS[0]}"
add_fixture nxudp vless-xudp "${PORTS[1]}"
add_fixture nws vless-ws-tls "${PORTS[2]}"
add_fixture nany anytls "${PORTS[3]}"
add_fixture ntuic tuic-v5 "${PORTS[4]}"
add_fixture nhy2 hy2 "${PORTS[5]}" '{"up_mbps":0,"down_mbps":0}'
add_fixture nargo vless-argo "${PORTS[6]}"
add_fixture nsocks socks5 "${PORTS[7]}"
add_fixture nhy2mixed hy2 "${PORTS[8]}" '{"up_mbps":0,"down_mbps":100}'
render_config
mihomo_validate "$CONFIG_FILE"
[ "$(grep -c '^  - type:' "$CONFIG_FILE")" -eq 9 ]
! grep -q '^external-controller:' "$CONFIG_FILE"
! grep -q '^dns:' "$CONFIG_FILE"
hy2="$(render_inbound_for_tag nhy2)"
grep -q 'ignore-client-bandwidth: true' <<<"$hy2"
! grep -qE '^    (up|down):' <<<"$hy2"
hy2="$(render_inbound_for_tag nhy2mixed)"
! grep -q 'ignore-client-bandwidth: true' <<<"$hy2"
! grep -q '^    up:' <<<"$hy2"
grep -q '100 Mbps' <<<"$hy2"
node_meta_array nsocks
[ "${#NODE_META[@]}" -eq 25 ] && [ "${NODE_META[1]}" = "$special_name" ] && [ "${NODE_META[4]}" = "$special_password" ]
# Invoke the same helper as standalone production start. exec keeps PID identity exact.
( mihomo_run "$CONFIG_FILE" ) >"$TEST_ROOT/kernel.log" 2>&1 &
KERNEL_PID=$!
ready=0
for ((attempt=0; attempt<100; attempt++)); do
  kill -0 "$KERNEL_PID" 2>/dev/null || break
  snapshot="$(ss -H -ltnup)"
  ready=1
  for idx in 0 1 2 3 4 5 6 7 8; do
    transport=tcp
    case "$idx" in 4 | 5 | 8) transport=udp ;; esac
    if ! awk -v port="${PORTS[idx]}" -v proto="$transport" -v pid="$KERNEL_PID" \
      '$1==proto && $5 ~ (":" port "$") && index($0,"pid=" pid ",") {found=1} END {exit !found}' <<<"$snapshot"; then ready=0; break; fi
  done
  [ "$ready" -ne 1 ] || break
  sleep 0.1
done
[ "$ready" -eq 1 ] || { printf 'The real process did not own all expected TCP/UDP listeners.\n' >&2; exit 1; }
# Prove the supplied config was loaded, plus IPv4/IPv6 TCP reachability and Argo loopback.
python3 - "${PORTS[7]}" "${PORTS[6]}" <<'PY'
import socket, sys
for addr in ('127.0.0.1', '::1'):
    with socket.create_connection((addr, int(sys.argv[1])), timeout=2) as s:
        s.sendall(b'\x05\x01\x02')
        assert s.recv(2) == b'\x05\x02', 'SOCKS auth config not loaded'
with socket.create_connection(('127.0.0.1', int(sys.argv[2])), timeout=2):
    pass
PY
stop_kernel
release_lock
printf 'accept-mihomo: PASS — 9 real listeners, specified config, TCP/UDP, dual-stack SOCKS, HY2 zero/mixed and escaped scalars\n'
