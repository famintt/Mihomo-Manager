#!/usr/bin/env bash
# Task-4 regressions: temporary files and loopback only, no public-IP probes.
# shellcheck disable=SC1091,SC2015,SC2016,SC2034,SC2317
set -eEuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
PASS=0
CLEANUP_PIDS=()
cleanup() {
  local pid
  for pid in "${CLEANUP_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT
source "$ROOT_DIR/lib/fmt.sh"
source "$ROOT_DIR/lib/network.sh"
source "$ROOT_DIR/lib/cert.sh"
source "$ROOT_DIR/lib/links.sh"
CERT_DIR="$TEST_ROOT/certs"
NODES_FILE="$TEST_ROOT/nodes.json"
mkdir -p "$CERT_DIR"
printf '{}\n' >"$NODES_FILE"
command_exists() { command -v "$1" >/dev/null 2>&1; }
print_err() { printf '%s\n' "$*" >&2; }
service_certificate_permissions() { chmod 600 "$1" "$2"; }
ok() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$*"; }
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected <$1>, got <$2>"; ok "$3"; }
reject() { if "$@" >/dev/null 2>&1; then fail "must reject: $*"; fi; }

for ip in 8.8.8.8 2606:4700:4700::1111 :: ::1 2001:db8::1 ::ffff:192.0.2.1 2001:db8::1.2.3.4; do is_ip_address "$ip" || fail "valid IP $ip"; done
for ip in 01.2.3.4 256.1.1.1 1.2.3 : 1:2:3 1::2::3 1:2:3:4:5:6:7 2001:db8::1.2.3.999; do reject is_ip_address "$ip"; done
for ip in 0.0.0.1 10.0.0.1 100.64.0.1 172.16.0.1 192.0.2.1 203.0.113.9 198.18.0.1 224.0.0.1 240.0.0.1 2001:db8::1 2001:0db8:0:0:0:0:0:1 ::ffff:8.8.8.8 fe80::1 febf::1 fc00::1 2001:20::1 3fff:fff::1; do is_private_ip "$ip" || fail "reserved IP $ip"; done
for ip in 8.8.8.8 1.1.1.1 2606:4700:4700::1111 2001:4860:4860::8888; do reject is_private_ip "$ip"; done
ok 'strict IPv4/IPv6 validation and reserved range filtering'
assert_eq 8.8.8.8 "$(extract_public_ip 8.8.8.8)" 'raw public IPv4'
for ip in 192.168.1.3 203.0.113.9 ::1 ::ffff:8.8.8.8; do reject extract_public_ip "$ip"; done
assert_eq 8.8.8.8 "$(extract_public_ip $'192.168.1.3\n8.8.8.8')" 'text skips private and preserves newline separator'
assert_eq 2001:4860:4860::8888 "$(extract_public_ip 'client=2001:db8::1; upstream=2001:4860:4860::8888')" 'text skips reserved IPv6'
assert_eq 8.8.8.8 "$(extract_public_ip '{"ip":"192.168.1.1","address":"8.8.8.8"}')" 'JSON continues past private field'
reject extract_public_ip '{"ip":"203.0.113.9"}'
ok 'all public IP response forms filter private/reserved candidates'

# public_ip_pin / MM_PUBLIC_IP 固定出口地址：出网被代理（WARP）时探测地址不可用于入站
TEST_PIN=""
TEST_CACHED_IP=""
TEST_CACHED_TS="0"
get_setting() {
  case "$1" in
  public_ip_pin) printf '%s' "${TEST_PIN}" ;;
  public_ip) printf '%s' "${TEST_CACHED_IP}" ;;
  public_ip_ts) printf '%s' "${TEST_CACHED_TS}" ;;
  public_ip_version) printf '%s' 4 ;;
  ip_version) printf '%s' 4 ;;
  *) printf '%s' "${2:-}" ;;
  esac
}
# 探测缓存仍是代理出口地址且已过期，固定值必须优先
TEST_CACHED_IP=104.28.195.192
TEST_CACHED_TS=1
TEST_PIN=216.167.28.249
PUBLIC_IP_CACHE=""
assert_eq 216.167.28.249 "$(get_public_ip)" 'pinned public IP wins over expired detected cache'
PUBLIC_IP_CACHE=""
assert_eq 8.8.8.8 "$(MM_PUBLIC_IP=8.8.8.8 get_public_ip)" 'MM_PUBLIC_IP overrides settings pin'
pin_reject() {
  local bad="$1"
  TEST_PIN="${bad}"
  PUBLIC_IP_CACHE=""
  if get_public_ip >/dev/null 2>&1; then fail "must reject pinned address ${bad}"; fi
}
for bad in 10.0.0.1 192.0.2.9 not-an-ip; do pin_reject "${bad}"; done
ok 'invalid or private pinned address is rejected instead of falling back silently'
TEST_PIN=""
PUBLIC_IP_CACHE=""

# Every socket uses an independent OS-assigned port and loopback only.
cat >"$TEST_ROOT/sockets.py" <<'PY'
import socket,sys,time
socks=[]
for family,kind,host in ((socket.AF_INET,socket.SOCK_STREAM,'127.0.0.1'),(socket.AF_INET,socket.SOCK_DGRAM,'127.0.0.1'),(socket.AF_INET6,socket.SOCK_STREAM,'::1'),(socket.AF_INET6,socket.SOCK_DGRAM,'::1')):
    sock=socket.socket(family,kind)
    if family==socket.AF_INET6: sock.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1)
    sock.bind((host,0))
    if kind==socket.SOCK_STREAM: sock.listen(1)
    socks.append(sock)
with open(sys.argv[1],'w') as output: output.write(' '.join(str(s.getsockname()[1]) for s in socks)+'\n')
time.sleep(60)
PY
python3 "$TEST_ROOT/sockets.py" "$TEST_ROOT/ports" & socket_pid=$!
CLEANUP_PIDS+=("$socket_pid")
for _ in {1..50}; do [ -s "$TEST_ROOT/ports" ] && break; sleep 0.05; done
[ -s "$TEST_ROOT/ports" ] || fail 'loopback listeners did not bind'
read -r -a ports <"$TEST_ROOT/ports"
[ "${#ports[@]}" -eq 4 ] || fail 'all four IP/protocol fixtures required'
invalidate_port_caches
for port in "${ports[@]}"; do reject port_available "$port"; done
kill "$socket_pid"; wait "$socket_pid" 2>/dev/null || true
CLEANUP_PIDS=()
for port in "${ports[@]}"; do system_has_port "$port" || fail 'cache unexpectedly refreshed before invalidation'; done
invalidate_port_caches
for port in "${ports[@]}"; do port_available "$port" || fail 'released port still occupied'; done
for port in 0 65536 abc -1 99999999999999999999; do reject port_available "$port"; done
ok 'real IPv4/IPv6 TCP/UDP sockets and cache refresh after release'
(
  command_exists() { [ "$1" = ss ]; }
  ss() { printf 'tcp LISTEN 0 128 127.0.0.1:45671 0.0.0.0:*\nudp UNCONN 0 0 [::1]:45672 [::]:*\n'; }
  invalidate_port_caches
  system_has_port 45671 && system_has_port 45672 || fail 'ss local column'
  reject system_has_port 128
)
(
  command_exists() { [ "$1" = netstat ]; }
  netstat() { printf 'tcp 0 0 127.0.0.1:45673 0.0.0.0:* LISTEN\nudp 0 0 :::45674 :::*\n'; }
  invalidate_port_caches
  system_has_port 45673 && system_has_port 45674 || fail 'netstat local column'
)
ok 'ss field five and independent netstat field four fixtures'

openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$TEST_ROOT/rsa.key" -out "$TEST_ROOT/rsa.crt" -subj '/CN=cn-only.example' -addext 'subjectAltName=DNS:*.example.com,DNS:other.test,IP:2001:db8::1' >/dev/null 2>&1
cert_covers_host "$TEST_ROOT/rsa.crt" foo.example.com || fail 'single label wildcard'
reject cert_covers_host "$TEST_ROOT/rsa.crt" a.b.example.com
reject cert_covers_host "$TEST_ROOT/rsa.crt" example.com
reject cert_covers_host "$TEST_ROOT/rsa.crt" cn-only.example
cert_covers_host "$TEST_ROOT/rsa.crt" OTHER.TEST || fail 'case-insensitive DNS SAN'
cert_covers_host "$TEST_ROOT/rsa.crt" 2001:0db8:0:0:0:0:0:1 || fail 'equivalent IP SAN'
reject cert_covers_host "$TEST_ROOT/rsa.crt" 2001:db8::2
(
  openssl() {
    local requested="${!#}"
    case " $* " in
      *" -checkhost "*) printf 'Hostname %s does NOT match certificate\n' "$requested" ;;
      *" -checkip "*) printf 'IP %s does NOT match certificate\n' "$requested" ;;
      *) command openssl "$@" ;;
    esac
  }
  reject cert_covers_host "$TEST_ROOT/rsa.crt" foo.example.com
  reject cert_covers_host "$TEST_ROOT/rsa.crt" 2001:db8::1
)
ok 'OpenSSL zero exit on hostname/IP mismatch never proves certificate coverage'
_validate_certificate_bundle "$TEST_ROOT/rsa.crt" "$TEST_ROOT/rsa.key" || fail 'valid RSA pair'
ensure_tls_material face face >/dev/null || fail 'self-signed DNS generation'
openssl x509 -in "$CERT_DIR/face.crt" -noout -ext subjectAltName | grep -q 'DNS:face' || fail 'hex DNS label misclassified as IP'
_validate_certificate_bundle "$CERT_DIR/face.crt" "$CERT_DIR/face.key" || fail 'valid EC pair'
reject _validate_certificate_bundle "$TEST_ROOT/rsa.crt" "$CERT_DIR/face.key"
import_custom_certificate_bundle preserved "$TEST_ROOT/rsa.crt" "$TEST_ROOT/rsa.key" >/dev/null || fail 'valid import'
before="$(sha256sum "$CERT_DIR/preserved.custom.crt" "$CERT_DIR/preserved.custom.key")"
reject import_custom_certificate_content preserved '%%%badbase64%%%' '%%%badbase64%%%'
reject import_custom_certificate_bundle preserved "$TEST_ROOT/rsa.crt" "$CERT_DIR/face.key"
assert_eq "$before" "$(sha256sum "$CERT_DIR/preserved.custom.crt" "$CERT_DIR/preserved.custom.key")" 'invalid imports preserve existing pair'
(
  mv() { case "$1" in --) shift;; esac; case "$1" in */candidate.key) return 1;; esac; command mv "$@"; }
  reject import_custom_certificate_bundle preserved "$CERT_DIR/face.crt" "$CERT_DIR/face.key"
)
assert_eq "$before" "$(sha256sum "$CERT_DIR/preserved.custom.crt" "$CERT_DIR/preserved.custom.key")" 'failed second publish restores previous pair'
(
  service_certificate_permissions() { return 1; }
  reject import_custom_certificate_bundle preserved "$CERT_DIR/face.crt" "$CERT_DIR/face.key"
)
assert_eq "$before" "$(sha256sum "$CERT_DIR/preserved.custom.crt" "$CERT_DIR/preserved.custom.key")" 'permission failure restores previous pair'
ok 'certificate SAN matching, RSA/EC keys, no-clobber imports and rollback'

printf '{"active":{}}\n' >"$NODES_FILE"
printf active >"$CERT_DIR/active.crt"; printf orphan >"$CERT_DIR/orphan.crt"
cleanup_orphan_certs || fail 'valid cleanup'
[ -e "$CERT_DIR/active.crt" ] && [ ! -e "$CERT_DIR/orphan.crt" ] || fail 'cleanup result'
printf '{broken' >"$NODES_FILE"
reject cleanup_orphan_certs
[ -e "$CERT_DIR/active.crt" ] || fail 'metadata parse failure deleted active cert'
printf '{"active":{}}\n' >"$NODES_FILE"
( jq() { return 78; }; reject cleanup_orphan_certs )
( jq() { if [ "$1" = -e ] && [ "$2" = --arg ]; then return 78; fi; command jq "$@"; }; reject cleanup_orphan_certs )
[ -e "$CERT_DIR/active.crt" ] || fail 'jq status78 deleted active cert'
( find() { printf '%s\0' "$CERT_DIR/active.crt"; return 1; }; reject cleanup_orphan_certs )
[ -e "$CERT_DIR/active.crt" ] || fail 'failed enumeration deleted active cert'
printf orphan >"$CERT_DIR/orphan.crt"
( rm() { case "$*" in *orphan.crt*) return 1;; esac; command rm "$@"; }; reject cleanup_orphan_certs )
[ -e "$CERT_DIR/orphan.crt" ] || fail 'rm fault lost file'
( rm() { return 1; }; reject remove_node_certificates active "$CERT_DIR/active.crt" ''; reject remove_node_certificates active '' "$CERT_DIR/active.crt" )
ok 'cleanup and explicit removal propagate jq/find/rm failures'

node_meta_array() {
  NODE_META=()
  local i
  for ((i=0;i<25;i++)); do NODE_META+=(""); done
  NODE_META[0]="$TEST_PROTOCOL"; NODE_META[1]=audit; NODE_META[2]=443
  NODE_META[3]=00000000-0000-0000-0000-000000000000
  NODE_META[6]=publickey; NODE_META[7]=first,second; NODE_META[8]=sni.example
}
manager_env_or_setting() { :; }
url_encode_many() { jq -rn --args '$ARGS.positional[] | @uri' -- "$@"; }
for protocol in vless-reality vless-xudp; do
  TEST_PROTOCOL="$protocol"
  link="$(build_share_link audit 8.8.8.8)"
  [[ "$link" == *'sid=first&'* && "$link" != *second* ]] || fail "first short ID $protocol"
done
node_meta_array() { return 1; }
reject build_share_link corrupt 8.8.8.8
ok 'Reality/XUDP links use first short ID and fail on corrupt metadata'
printf 'PASS %d task-4 groups\n' "$PASS"

