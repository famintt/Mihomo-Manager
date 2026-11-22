#!/usr/bin/env bash
# MM-05/MM-02: CLI parsing, field mappings, firewall safeguards, and restore delegation.
set -eEuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/mm-audit-cli.XXXXXX)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
PASS=0
ok() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$*"; }
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected <$1>, got <$2>"; ok "$3"; }
print_err() { :; }
print_ok() { :; }
print_warn() { :; }
print_info() { :; }
require_root() { :; }
EXPECT_PROTOCOL=ws
auto_install() {
  [ "$1" = ins ] || fail 'CLI add action preserved'
  case "$EXPECT_PROTOCOL" in
    ws)
      [ "$passwd" = 'literal-password' ] || fail 'password exported as passwd'
      [ "$wspt" = 443 ] || fail 'WS port normalized'
      [ "$ws_mode" = cdn ] || fail 'WS mode set to CDN'
      [ "$ws_cdn_sni" = 'ws.example.test' ] || fail 'WS SNI exported to ws_cdn_sni'
      ;;
    reality) [ "$vlrt" = 54321 ] || fail 'omitted port uses random port' ;;
  esac
}
source "$ROOT_DIR/lib/cli-add.sh"
random_free_port() { printf 54321; }
cli_add --protocol ws --port 00443 --password literal-password --sni ws.example.test || fail 'valid ws add'
ok 'valid WS add normalizes port and exports expected fields'
EXPECT_PROTOCOL=reality
cli_add --protocol reality || fail 'omitted port should select random port'
ok 'omitted port uses the random-port path'
EXPECT_PROTOCOL=ws
for args in   '--protocol reality --port'   '--protocol reality --port --name x'   '--protocol reality --name --unknown 443'   '--protocol reality --password --unknown'   '--protocol reality --port nope'   '--protocol reality --port 0'   '--protocol reality --port 65536'   '--protocol bogus --port 443'; do
  if eval "cli_add $args" >/dev/null 2>&1; then fail "invalid CLI add accepted: $args"; fi
done
ok 'CLI add rejects missing, option-like, malformed, out-of-range ports and protocol'
[ "$(cli_normalize_port 00080)" = 80 ] || fail 'decimal port normalization'
if cli_normalize_port 999999999999999999999 >/dev/null 2>&1; then fail 'oversized port accepted'; fi
ok 'port normalization is bounded decimal'
MIHOMO_BIN="$TEST_DIR/mihomo"; CONFIG_FILE="$TEST_DIR/config.yaml"; SCRIPT_VERSION=1.2.7
: > "$MIHOMO_BIN"; chmod +x "$MIHOMO_BIN"; printf 'mixed-port: 7890\n' > "$CONFIG_FILE"
init_storage() { :; }
service_state() { printf '运行中'; }
mihomo_validate() { [ "$#" = 1 ] && [ "$1" = "$CONFIG_FILE" ] || return 1; printf '%s' "$1" > "$TEST_DIR/validated"; }
cli_doctor >/dev/null || fail 'doctor accepted valid service configuration'
assert_eq "$CONFIG_FILE" "$(<"$TEST_DIR/validated")" 'doctor uses mihomo_validate with config path'
manager_env_or_setting() { printf '%s' "${TEST_WL_FLAG:-}"; }
ufw() { if [ "$1" = status ]; then printf 'Status: active\n'; else printf '%s\n' "$*" >> "$TEST_DIR/fw.calls"; fi; }
cli_fw_backend() { printf ufw; }
socks5_whitelist_guard() { [ "$1" = 1080 ] || return 1; return 2; }
if cli_fw open --port 1080 >/dev/null 2>&1; then fail 'protected SOCKS port was opened'; fi
[ ! -s "$TEST_DIR/fw.calls" ] || fail 'firewall mutation happened despite guard'
ok 'active SOCKS whitelist guard blocks generic open'
unset -f socks5_whitelist_guard
TEST_WL_FLAG=1
if cli_fw open --port 1080 >/dev/null 2>&1; then fail 'unknown protected state was opened'; fi
[ ! -s "$TEST_DIR/fw.calls" ] || fail 'firewall mutation happened without guard helper'
ok 'missing guard fails closed when whitelist enabled'
TEST_WL_FLAG=
if cli_fw open --port nope >/dev/null 2>&1; then fail 'invalid firewall port accepted'; fi
if cli_fw open --port 0 >/dev/null 2>&1; then fail 'zero firewall port accepted'; fi
if cli_fw open --port 65536 >/dev/null 2>&1; then fail 'out-of-range firewall port accepted'; fi
if cli_fw open --port 1234 --proto sctp >/dev/null 2>&1; then fail 'unsupported firewall protocol accepted'; fi
ok 'firewall rejects malformed ports and unsupported protocols'
cli_fw open --port 1080 >/dev/null || fail 'unprotected valid port should be allowed'
assert_eq 'allow 1080/tcp' "$(<"$TEST_DIR/fw.calls")" 'unprotected open reaches active backend'
rm -f "$TEST_DIR/fw.calls"
cli_fw_backend() { printf iptables; }
socks5_whitelist_guard() { return 0; }
IPV4_EXISTS=0
iptables() { case "$1" in -C) [ "$IPV4_EXISTS" = 1 ];; -I) IPV4_EXISTS=1; printf 'insert\n' >> "$TEST_DIR/fw.calls";; -D) IPV4_EXISTS=0; printf 'delete\n' >> "$TEST_DIR/fw.calls";; *) return 0;; esac; }
ip6tables() { case "$1" in -C) return 1;; -I) return 1;; *) return 0;; esac; }
if cli_fw open --port 2080 >/dev/null 2>&1; then fail 'dual-stack open succeeded after IPv6 failure'; fi
assert_eq 0 "$IPV4_EXISTS" 'new IPv4 rule rolled back after IPv6 failure'
assert_eq $'insert\ndelete' "$(<"$TEST_DIR/fw.calls")" 'IPv4 rollback is specific to this operation'
IPV4_EXISTS=1; : > "$TEST_DIR/fw.calls"
if cli_fw open --port 2080 >/dev/null 2>&1; then fail 'preexisting IPv4 rule escaped IPv6 failure'; fi
assert_eq 1 "$IPV4_EXISTS" 'preexisting IPv4 rule preserved after IPv6 failure'
assert_eq '' "$(<"$TEST_DIR/fw.calls")" 'preexisting rule was neither inserted nor deleted'
ok 'IPv6 failure rolls back only newly inserted IPv4 allow rule'
source "$ROOT_DIR/lib/cli.sh"
require_root() { :; }
RESTORE_CALLED=0
restore_stack() { RESTORE_CALLED=$((RESTORE_CALLED + 1)); }
main restore
assert_eq 1 "$RESTORE_CALLED" 'restore dispatch delegates to restore_stack'
printf '1..%s\n' "$PASS"
