#!/usr/bin/env bash
set -eEuo pipefail
umask 077
ROOT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
cleanup() { rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT
export BASE_DIR="$TEST_ROOT/etc" LIB_DIR="$TEST_ROOT/lib" INSTALL_BIN="$TEST_ROOT/mm"
export LOCK_ROOT="$TEST_ROOT/locks" LOCK_FILE="$TEST_ROOT/locks/audit.lock"
export MM_TEST_MODE=1 HOME="$TEST_ROOT/home" XDG_CONFIG_HOME="$TEST_ROOT/home/.config"
export MIHOMO_DATA_DIR="$TEST_ROOT/etc/data" MIHOMO_BIN="${MIHOMO_BIN:-}"
export clash_api=0 dns_servers=off ip_version=auto
mkdir -p "$HOME" "$MIHOMO_DATA_DIR"
if [ -z "$MIHOMO_BIN" ]; then
  mkdir -p "$TEST_ROOT/bin"
  cat >"$TEST_ROOT/bin/mihomo" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = -d ] && [ "${2:-}" = "$MIHOMO_DATA_DIR" ] || exit 11
shift 2
[ "${1:-}" = -t ] && [ "${2:-}" = -f ] && [ -f "${3:-}" ] && [ "$#" -eq 3 ] || exit 12
STUB
  chmod 700 "$TEST_ROOT/bin/mihomo"
  export MIHOMO_BIN="$TEST_ROOT/bin/mihomo"
fi
# shellcheck source=../mm.sh
source "$ROOT_DIR/mm.sh"
init_storage

pass=0
fail=0
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass=$((pass+1)); else printf 'FAIL: %s\n expected=[%s]\n actual=[%s]\n' "$label" "$expected" "$actual" >&2; fail=$((fail+1)); fi
}
assert_result() {
  local label="$1" expected="$2"; shift 2
  if "$@" >/dev/null 2>&1; then actual=0; else actual=$?; fi
  if [ "$expected" = "$actual" ]; then pass=$((pass+1)); else printf 'FAIL: %s (status=%s expected=%s)\n' "$label" "$actual" "$expected" >&2; fail=$((fail+1)); fi
}

# YAML JSON scalar escaping retains controls, Unicode line separators, and parsed value.
special=$'tab\tline\nreturn\rslash\\backslash'
special+="'single' and \"double\" quote"
special+=$'\b\a'
special+=$'\u2028\u2029\u0085'
quoted="$(yaml_quote "$special")"
assert_eq 'yaml_quote round trip' "$special" "$(printf '%s' "$quoted" | jq -Rr 'fromjson')"
[[ "$quoted" == *'\u2028'* && "$quoted" == *'\u0085'* ]] && pass=$((pass+1)) || { printf 'FAIL: yaml_quote escapes line separators\n' >&2; fail=$((fail+1)); }

# Metadata is NUL-delimited but field contents retain tabs/newlines/CR/backslashes and empty indexes.
meta_name=$'MiXeD\tname\ncontinued\r\\tail'
meta_password=$'p\nass\tword'
jq -n --arg name "$meta_name" '{fixture:{protocol:"socks5",name:$name,port:1080,username:""}}' >"$NODES_FILE"
jq -n --arg password "$meta_password" '{fixture:{password:$password}}' >"$SECRETS_FILE"
if node_meta_array fixture; then
  assert_eq 'metadata multiline name' "$meta_name" "${NODE_META[1]}"
  assert_eq 'metadata multiline password' "$meta_password" "${NODE_META[4]}"
  assert_eq 'metadata empty slots stable' '' "${NODE_META[5]}${NODE_META[6]}${NODE_META[7]}"
  assert_eq 'metadata count' 25 "${#NODE_META[@]}"
else printf 'FAIL: valid metadata rejected\n' >&2; fail=$((fail+1)); fi
jq -n '{fixture:{protocol:"socks5",name:[],port:1080}}' >"$NODES_FILE"
assert_result 'metadata rejects structured values' 1 node_meta_array fixture
jq -n '{fixture:{protocol:"socks5",name:"\u0000",port:1080}}' >"$NODES_FILE"
assert_result 'metadata rejects embedded NUL' 1 node_meta_array fixture

# DNS comma splitting does not glob; malformed final item fails before producing config.
mkdir -p "$TEST_ROOT/dns-glob/udp:"
touch "$TEST_ROOT/dns-glob/udp:/a.example"
(cd "$TEST_ROOT/dns-glob" && dns_servers='udp://*' && dns_out="$(render_dns_object)" && [[ "$dns_out" == *'"udp://*"'* ]]) && pass=$((pass+1)) || { printf 'FAIL: DNS glob remains literal\n' >&2; fail=$((fail+1)); }
dns_servers='https://valid.example/dns-query,'
assert_result 'DNS rejects trailing empty item' 2 render_dns_object
ip_version=6 dns_servers=''
dns_out="$(render_dns_object)"
[[ "$dns_out" == *'https://[2606:4700:4700::1111]/dns-query'* && "$dns_out" == *'strategy: prefer_ipv6'* ]] && pass=$((pass+1)) || { printf 'FAIL: IPv6 DNS defaults\n' >&2; fail=$((fail+1)); }

assert_eq 'explicit zero rate canonicalized' 0 "$(normalize_hy2_mbps 000)"
assert_eq 'missing legacy rate defaults to 200' 200 "$(normalize_hy2_mbps '')"
assert_result 'reject too large rate' 1 normalize_hy2_mbps 1000000000
assert_result 'reject negative rate' 1 normalize_hy2_mbps -1

# Renderer validates with explicit -d and preserves config when DNS invalid.
printf 'previous-config\n' >"$CONFIG_FILE"
dns_servers=invalid
assert_result 'invalid DNS stops rendering' 1 render_config
assert_eq 'invalid DNS preserves config' previous-config "$(<"$CONFIG_FILE")"

# A valid HY2 listener proves zero/mixed directions and CERT_DIR confinement.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 \
  -keyout "$CERT_DIR/fixture.key" -out "$CERT_DIR/fixture.crt" -subj /CN=example.com >/dev/null 2>&1
cert="$CERT_DIR/fixture.crt" key="$CERT_DIR/fixture.key"
jq -n --arg cert "$cert" --arg key "$key" '{hy:{protocol:"hy2",name:"Audit HY2",port:24443,tls_server:"example.com",up_mbps:0,down_mbps:0,certificate_path:$cert,key_path:$key}}' >"$NODES_FILE"
jq -n '{hy:{password:"safe"}}' >"$SECRETS_FILE"
dns_servers=off
assert_result 'HY2 zero-rate render' 0 render_config
hy2="$(render_inbound_for_tag hy)"
[[ "$hy2" == *'ignore-client-bandwidth: true'* && "$hy2" != *$'    up:'* && "$hy2" != *$'    down:'* ]] && pass=$((pass+1)) || { printf 'FAIL: both-zero HY2 semantics\n' >&2; fail=$((fail+1)); }
jq -n --arg cert "$cert" --arg key "$key" '{hy:{protocol:"hy2",name:"Audit HY2",port:24443,tls_server:"example.com",up_mbps:0,down_mbps:100,certificate_path:$cert,key_path:$key}}' >"$NODES_FILE"
hy2="$(render_inbound_for_tag hy)"
[[ "$hy2" != *'ignore-client-bandwidth: true'* && "$hy2" != *$'    up:'* && "$hy2" == *'down: "100 Mbps"'* ]] && pass=$((pass+1)) || { printf 'FAIL: mixed-zero HY2 semantics\n' >&2; fail=$((fail+1)); }
# Outside and symlinked paths are rejected before YAML emission.
if _render_certificate_path "$TEST_ROOT/outside.crt"; then printf 'FAIL: outside cert path accepted\n' >&2; fail=$((fail+1)); else pass=$((pass+1)); fi
ln -s "$cert" "$CERT_DIR/linked.crt"
if _render_certificate_path "$CERT_DIR/linked.crt"; then printf 'FAIL: symlink cert path accepted\n' >&2; fail=$((fail+1)); else pass=$((pass+1)); fi
rm "$CERT_DIR/linked.crt"

# Legacy external custom certificates migrate to managed CERT_DIR and update both JSON paths.
cp "$cert" "$TEST_ROOT/legacy.crt"
cp "$key" "$TEST_ROOT/legacy.key"
jq -n --arg cert "$TEST_ROOT/legacy.crt" --arg key "$TEST_ROOT/legacy.key" '{legacy:{protocol:"hy2",name:"Legacy",port:24444,certificate_mode:"custom",certificate_path:$cert,key_path:$key}}' >"$NODES_FILE"
jq -n '{legacy:{password:"legacy-pass"}}' >"$SECRETS_FILE"
assert_result 'legacy custom certificate migration' 0 migrate_custom_certificates
legacy_cert="$(node_value legacy certificate_path)"
legacy_key="$(node_value legacy key_path)"
[[ "$legacy_cert" == "$CERT_DIR/legacy.custom.crt" && "$legacy_key" == "$CERT_DIR/legacy.custom.key" && -f "$legacy_cert" && -f "$legacy_key" ]] && pass=$((pass+1)) || { printf 'FAIL: migrated custom certificate paths\n' >&2; fail=$((fail+1)); }

# A stale transaction cannot replace a marker; prompt failures must not release caller locks.
_AUTO_ROLLBACK_DIR="$BASE_DIR/backups/sentinel"
_AUTO_ROLLBACK_OWNER="$BASHPID"
acquire_lock
assert_result 'begin refuses active transaction' 1 _begin_node_add 24444 second
assert_eq 'begin refusal preserves marker' "$BASE_DIR/backups/sentinel" "$_AUTO_ROLLBACK_DIR"
_AUTO_ROLLBACK_DIR=''; _AUTO_ROLLBACK_OWNER=''
assert_result 'pre-transaction abort leaves lock alone' 0 _abort_node_add
assert_eq 'pre-transaction abort retains lock' true "$LOCK_HELD"
release_lock
_AUTO_ROLLBACK_DIR=''; _AUTO_ROLLBACK_OWNER=''

# Force an interactive SOCKS add to fail after writes; rollback must restore all state bytes and cert tree.
mkdir -p "$CERT_DIR"
printf 'old-cert-material\n' >"$CERT_DIR/keep.crt"
printf 'prior-config\n' >"$CONFIG_FILE"
state_digest() {
  (cd "$BASE_DIR" && sha256sum nodes.json secrets.json config.yaml settings.json && find certs -type f -print0 | sort -z | xargs -0 -r sha256sum) | sha256sum | cut -d' ' -f1
}
before="$(state_digest)"
ensure_singbox_ready() { return 0; }
generate_tag() { printf 'audit-rollback'; }
prompt_port() { printf '24444'; }
prompt_with_default() { case "$1" in *用户名*) printf 'u';; *SNI*) printf 'example.com';; *) printf 'rollback-node';; esac; }
prompt_optional_value() { printf 'secret'; }
prompt_choice() { printf 'self-signed'; }
port_available() { return 0; }
render_config() { return 1; }
stop_service() { return 0; }
start_service() { return 0; }
if add_socks5; then printf 'FAIL: forced interactive add unexpectedly succeeded\n' >&2; fail=$((fail+1)); fi
after="$(state_digest)"
assert_eq 'interactive add failure restores exact files and certs' "$before" "$after"
assert_eq 'interactive rollback clears marker' '' "${_AUTO_ROLLBACK_DIR:-}"
assert_eq 'interactive rollback releases lock' false "${LOCK_HELD:-false}"

# Force AnyTLS to generate TLS material, then fail render; certificate and tables must revert exactly.
before="$(state_digest)"
if add_anytls; then printf 'FAIL: forced AnyTLS failure unexpectedly succeeded\n' >&2; fail=$((fail+1)); fi
after="$(state_digest)"
assert_eq 'AnyTLS failure removes generated certificate and restores state' "$before" "$after"
assert_eq 'AnyTLS rollback clears marker' '' "${_AUTO_ROLLBACK_DIR:-}"
assert_eq 'AnyTLS rollback releases lock' false "${LOCK_HELD:-false}"

if [ "$fail" -ne 0 ]; then printf 'audit-render: %s passed, %s failed\n' "$pass" "$fail" >&2; exit 1; fi
printf 'audit-render: %s passed\n' "$pass"
