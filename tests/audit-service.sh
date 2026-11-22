#!/usr/bin/env bash
# MM-02/MM-03/MM-04/MM-10/MM-11/MM-14: isolated service regressions.
# Optional: MM_SERVICE_DAC_TEST=1 (root, existing nobody:nogroup only).
# Optional: MIHOMO_BIN=/absolute/path/to/verified/mihomo (offline -t and isolated lifecycle).
# Indirect mocks are called by sourced production functions; fixture globals stay in subshells.
# shellcheck disable=SC1091,SC2016,SC2030,SC2031,SC2034,SC2317
set -eEuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_MIHOMO_BIN="${MIHOMO_BIN:-}"
TEST_ROOT="$(mktemp -d /tmp/mm-service-test.XXXXXXXX)"
export BASE_DIR="$TEST_ROOT/etc" LIB_DIR="$TEST_ROOT/lib" MM_TEST_MODE=1
export LOCK_ROOT="$TEST_ROOT/locks" LOCK_FILE="$TEST_ROOT/locks/shared.lock"
export PUBLIC_IP_CACHE=8.8.8.8
source "$ROOT_DIR/mm.sh"
cleanup() { release_lock; rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT
RESULTS="$TEST_ROOT/results"
: >"$RESULTS"
ok() {
  local description="$1"; shift
  if "$@"; then printf "+\n" >>"$RESULTS"; else printf -- "-\n" >>"$RESULTS"; printf "FAIL: %s\n" "$description" >&2; fi
}
no() {
  local description="$1"; shift
  if "$@"; then printf -- "-\n" >>"$RESULTS"; printf "FAIL (accepted): %s\n" "$description" >&2; else printf "+\n" >>"$RESULTS"; fi
}
status_is() { local expected="$1" rc=0; shift; "$@" || rc=$?; [ "$rc" = "$expected" ]; }
skip() { printf "SKIP: %s\n" "$*"; }
# The fixture never installs a core, identities, units, cron entries or host rules.
init_storage
mkdir -p "$BASE_DIR/data" "$TEST_ROOT/bin" "$TEST_ROOT/units"
export ARGV_CAPTURE="$TEST_ROOT/argv"
MIHOMO_BIN="$TEST_ROOT/bin/mihomo"
cat >"$MIHOMO_BIN" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf "%s\0" "${SAFE_PATHS:-}" "$@" >"$ARGV_CAPTURE"
STUB
chmod 700 "$MIHOMO_BIN"
argv_is() {
  local -a got=()
  mapfile -d "" -t got <"$ARGV_CAPTURE"
  [ "${#got[@]}" = "$#" ] || return 1
  local arg i=0
  for arg in "$@"; do [ "${got[$i]}" = "$arg" ] || return 1; i=$((i+1)); done
}
ok "validation executes explicit -d and SAFE_PATHS" mihomo_validate
ok "validation argv exactly matches real CLI" argv_is "$BASE_DIR:$CERT_DIR" -d "$BASE_DIR/data" -t -f "$CONFIG_FILE"
( mihomo_run )
ok "launch argv excludes unsupported run command" argv_is "$BASE_DIR:$CERT_DIR" -d "$BASE_DIR/data" -f "$CONFIG_FILE"
ok "core working directory is confined to data" test "$(mihomo_data_dir)" = "$BASE_DIR/data"
(
  MIHOMO_DATA_DIR="$BASE_DIR/../escape"
  no "working directory cannot escape base" mihomo_data_dir
)
(
  MIHOMO_DATA_DIR="$BASE_DIR/data:escape"
  no "working directory rejects SAFE_PATHS delimiter" mihomo_data_dir
)
(
  MIHOMO_DATA_DIR="$BASE_DIR/data with space"
  no "working directory rejects unit argument splitting" mihomo_data_dir
)
(
  mv "$BASE_DIR/data" "$BASE_DIR/real-data"
  ln -s "$BASE_DIR/real-data" "$BASE_DIR/data"
  no "working directory cannot be a symlink" mihomo_data_dir
  rm "$BASE_DIR/data"
  mv "$BASE_DIR/real-data" "$BASE_DIR/data"
)
(
  printf "{}\n" >"$TEST_ROOT/outside.yaml"
  no "configuration outside base is rejected" service_config_permissions "$TEST_ROOT/outside.yaml"
  ln -s "$TEST_ROOT/outside.yaml" "$BASE_DIR/link.yaml"
  no "configuration symlink is rejected" service_config_permissions "$BASE_DIR/link.yaml"
  rm "$BASE_DIR/link.yaml"
)
# Generated templates use a non-root identity; only the core data directory is writable.
(
  SYSTEMD_SERVICE_FILE="$TEST_ROOT/units/core.service"
  SYSTEMD_WATCHDOG_SERVICE_FILE="$TEST_ROOT/units/watchdog.service"
  SYSTEMD_WATCHDOG_TIMER_FILE="$TEST_ROOT/units/watchdog.timer"
  OPENRC_SERVICE_FILE="$TEST_ROOT/units/openrc"
  MM_CLI="$TEST_ROOT/bin/mm"
  MM_DEFER_WATCHDOG_ENABLE=1
  systemctl() { printf "%s\n" "$*" >>"$TEST_ROOT/systemctl"; }
  rc-update() { printf "%s\n" "$*" >>"$TEST_ROOT/rc-update"; }
  go_mem_limit_value() { printf 64MiB; }
  go_gc_requested() { return 1; }
  ok "systemd templates generate without host service mutation" create_systemd_units
  ok "systemd service has dedicated user" grep -Fx "User=$MIHOMO_SERVICE_USER" "$SYSTEMD_SERVICE_FILE"
  ok "systemd service has private working directory" grep -Fx "WorkingDirectory=$BASE_DIR/data" "$SYSTEMD_SERVICE_FILE"
  ok "systemd validation sets explicit data directory" grep -Fx "ExecStartPre=$MIHOMO_BIN -d $BASE_DIR/data -t -f $CONFIG_FILE" "$SYSTEMD_SERVICE_FILE"
  ok "systemd launch sets explicit data directory" grep -Fx "ExecStart=$MIHOMO_BIN -d $BASE_DIR/data -f $CONFIG_FILE" "$SYSTEMD_SERVICE_FILE"
  ok "systemd passes exact safe paths" grep -Fx "Environment=SAFE_PATHS=$BASE_DIR:$CERT_DIR" "$SYSTEMD_SERVICE_FILE"
  ok "systemd core writable path is data only" grep -Fx "ReadWritePaths=$BASE_DIR/data" "$SYSTEMD_SERVICE_FILE"
  no "management tree is not directly writable by core unit" grep -Fx "ReadWritePaths=$BASE_DIR" "$SYSTEMD_SERVICE_FILE"
  ok "systemd retains netlink for socket inspection" grep -F AF_NETLINK "$SYSTEMD_SERVICE_FILE"
  ok "systemd startup enforces whitelist" grep -Fx "ExecStartPre=+$MM_CLI fw protect" "$SYSTEMD_SERVICE_FILE"
  ok "OpenRC template generates in temporary directory" create_openrc_units
  ok "OpenRC launch sets explicit data directory" grep -Fx "command_args=\"-d $BASE_DIR/data -f $CONFIG_FILE\"" "$OPENRC_SERVICE_FILE"
  ok "OpenRC runs dedicated user" grep -Fx "command_user=\"$MIHOMO_SERVICE_USER:$MIHOMO_SERVICE_GROUP\"" "$OPENRC_SERVICE_FILE"
  ok "OpenRC startup enforces whitelist" grep -F "fw protect || return 1" "$OPENRC_SERVICE_FILE"
)
# Existing identity records must never map the data plane to root or a wrong group.
(
  MM_TEST_MODE=0
  getent() {
    case "$1" in group) printf 'mihomo:x:12345:\n' ;; passwd) printf 'mihomo:x:0:12345::/:/usr/sbin/nologin\n' ;; *) return 1 ;; esac
  }
  no "root UID is not a valid data-plane identity" service_ensure_identity
  getent() {
    case "$1" in group) printf 'mihomo:x:12345:\n' ;; passwd) printf 'mihomo:x:12346:54321::/:/usr/sbin/nologin\n' ;; *) return 1 ;; esac
  }
  no "dedicated user with wrong primary group is rejected" service_ensure_identity
  getent() {
    case "$1" in group) printf 'mihomo:x:12345:\n' ;; passwd) printf 'mihomo:x:12346:12345::/:/usr/sbin/nologin\n' ;; *) return 1 ;; esac
  }
  ok "existing non-root identity with matching primary group is accepted" service_ensure_identity
)
(
  MM_TEST_MODE=0
  service_ensure_identity() { :; }
  printf 'cert\n' >"$CERT_DIR/safe.crt"
  printf 'key\n' >"$CERT_DIR/safe.key"
  printf 'outside\n' >"$TEST_ROOT/outside.key"
  no "certificate key outside certificate directory is rejected" service_certificate_permissions "$CERT_DIR/safe.crt" "$TEST_ROOT/outside.key"
  ln -s "$TEST_ROOT/outside.key" "$CERT_DIR/linked.key"
  no "certificate symlink cannot expose outside key" service_certificate_permissions "$CERT_DIR/safe.crt" "$CERT_DIR/linked.key"
  rm "$CERT_DIR/linked.key"
)
json_set_record "$NODES_FILE" socks '{"protocol":"socks5","port":30901}'
json_set_record "$NODES_FILE" reality '{"protocol":"vless-reality","port":30902}'
set_setting socks5_wl_flag 1
set_setting socks5_ips "192.0.2.10 2001:db8::10"
ok "protected SOCKS port returns guard status 2" status_is 2 socks5_whitelist_guard 30901
ok "other protocol port returns guard status 0" status_is 0 socks5_whitelist_guard 30902
ok "unmanaged port returns guard status 0" status_is 0 socks5_whitelist_guard 30903
ok "invalid port returns guard status 1" status_is 1 socks5_whitelist_guard 0
(
  manager_env_or_setting() { return 71; }
  ok "guard propagates setting failure" status_is 1 socks5_whitelist_guard 30901
)
(
  iter_node_tags() { return 72; }
  ok "guard propagates node enumeration failure" status_is 1 socks5_whitelist_guard 30901
)
set_setting socks5_wl_flag 0
ok "disabled protection returns guard status 0" status_is 0 socks5_whitelist_guard 30901
set_setting socks5_wl_flag 1
# A strict stateful firewall model. Every operation is isolated JSON; no host backend runs.
export FW_STATE="$TEST_ROOT/firewall" FW_FAIL=""
mkdir "$FW_STATE"
cat >"$TEST_ROOT/firewall.py" <<'PY'
import ipaddress
import json
import os
from pathlib import Path
import sys
family, *args = sys.argv[1:]
root = Path(os.environ["FW_STATE"])
path = root / (family + ".json")
state = json.loads(path.read_text()) if path.exists() else {"INPUT": []}
with (root / "calls.log").open("a") as stream:
    stream.write(family + " " + " ".join(args) + "\n")
fail = os.environ.get("FW_FAIL", "").split("|", 1)
if len(fail) == 2 and family == fail[0] and fail[1] in " ".join(args):
    (root / "failure-reached").write_text(family + " " + " ".join(args))
    sys.exit(73)
def save():
    path.write_text(json.dumps(state, sort_keys=True))
def die():
    sys.exit(1)
if not args:
    die()
op, *rest = args
if op == "-S" and rest == ["INPUT"]:
    for rule in state["INPUT"]:
        print("-A INPUT " + " ".join(rule))
elif op == "-L":
    chain = rest[0]
    if chain not in state:
        die()
    print("Chain " + chain)
    print("num target prot opt source destination")
    for i, rule in enumerate(state[chain], 1):
        target = rule[rule.index("-j") + 1]
        print(i, target, "all -- anywhere anywhere")
elif op == "-N" and len(rest) == 1:
    if rest[0] in state:
        die()
    state[rest[0]] = []
    save()
elif op == "-F" and len(rest) == 1:
    if rest[0] not in state:
        die()
    state[rest[0]] = []
    save()
elif op == "-X" and len(rest) == 1:
    if rest[0] not in state or state[rest[0]]:
        die()
    if any("-j" in r and r[r.index("-j") + 1] == rest[0]
           for rules in state.values() for r in rules):
        die()
    del state[rest[0]]
    save()
elif op in ("-A", "-I") and len(rest) >= 3:
    chain, *rule = rest
    if chain not in state:
        die()
    index = len(state[chain])
    if op == "-I":
        index = int(rule.pop(0)) - 1
    if "-s" in rule:
        try:
            ipaddress.ip_network(rule[rule.index("-s") + 1], strict=False)
        except ValueError:
            die()
    if "-j" not in rule:
        die()
    target = rule[rule.index("-j") + 1]
    if target not in ("ACCEPT", "DROP", "RETURN") and target not in state:
        die()
    state[chain].insert(index, rule)
    save()
elif op == "-D" and len(rest) == 2 and rest[0] == "INPUT":
    index = int(rest[1]) - 1
    if not 0 <= index < len(state["INPUT"]):
        die()
    state["INPUT"].pop(index)
    save()
else:
    print("UNSUPPORTED MOCK FIREWALL OPERATION", family, args, file=sys.stderr)
    sys.exit(90)
PY
iptables() { python3 "$TEST_ROOT/firewall.py" iptables "$@"; }
ip6tables() { python3 "$TEST_ROOT/firewall.py" ip6tables "$@"; }
fw_reset() {
  FW_FAIL=""
  printf '{"INPUT": [["-p", "tcp", "--dport", "2200", "-j", "ACCEPT"]]}\n' >"$FW_STATE/iptables.json"
  cp "$FW_STATE/iptables.json" "$FW_STATE/ip6tables.json"
  : >"$FW_STATE/calls.log"
  rm -f "$FW_STATE/failure-reached"
}
fw_snapshot() { cp "$FW_STATE/iptables.json" "$FW_STATE/before4.json"; cp "$FW_STATE/ip6tables.json" "$FW_STATE/before6.json"; }
fw_old_policy_unchanged() {
  python3 - "$FW_STATE" <<'PY'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
for family, before in (("iptables", "before4"), ("ip6tables", "before6")):
    state = json.loads((root / (family + ".json")).read_text())
    old = json.loads((root / (before + ".json")).read_text())
    assert state["INPUT"] == old["INPUT"], (family, state["INPUT"], old["INPUT"])
    for key in {r[r.index("-j") + 1] for r in old["INPUT"]}:
        if key.startswith("MM_SOCKS5_WL_"):
            assert state[key] == old[key], (family, key)
PY
}
fw_policy_valid() {
  python3 - "$FW_STATE" <<'PY'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
for family, allowed in (("iptables", "192.0.2.10"), ("ip6tables", "2001:db8::10")):
    state = json.loads((root / (family + ".json")).read_text())
    assert [r for r in state["INPUT"] if "--comment" not in r] == [["-p", "tcp", "--dport", "2200", "-j", "ACCEPT"]]
    rules = [r for r in state["INPUT"] if "--comment" in r]
    assert len(rules) == 2, (family, rules)
    assert {r[r.index("-p") + 1] for r in rules} == {"tcp", "udp"}
    targets = {r[r.index("-j") + 1] for r in rules}
    assert len(targets) == 1
    chain = targets.pop()
    assert chain in ("MM_SOCKS5_WL_A", "MM_SOCKS5_WL_B")
    assert state[chain] == [["-s", allowed, "-j", "ACCEPT"], ["-j", "DROP"]], (family, state[chain])
    assert all(r[r.index("--dport") + 1] == "30901" for r in rules)
PY
}
fw_reset
ok "whitelist installs TCP and UDP protection in both families" socks5_whitelist_apply
ok "each family allows own addresses then drops other sources" fw_policy_valid
fw_snapshot
FW_FAIL="ip6tables|-A MM_SOCKS5_WL_B -j DROP"
no "IPv6 staging failure prevents new policy activation" socks5_whitelist_apply
ok "IPv6 staging fault injection reached backend" test -s "$FW_STATE/failure-reached"
ok "staging failure preserves both active family policies" fw_old_policy_unchanged
rm -f "$FW_STATE/failure-reached"
FW_FAIL="ip6tables|-I INPUT 1 -p tcp"
no "IPv6 activation failure rolls back new family references" socks5_whitelist_apply
ok "IPv6 activation fault injection reached backend" test -s "$FW_STATE/failure-reached"
ok "partial dual-stack activation restores old references and policy" fw_old_policy_unchanged
FW_FAIL=""
ok "whitelist update swaps to other chain after successful staging" socks5_whitelist_apply
ok "successful swap retains exact dual-stack policy" fw_policy_valid
(
  command_exists() { [ "$1" != ip6tables ] && command -v "$1" >/dev/null 2>&1; }
  no "missing IPv6 backend is a startup failure" socks5_whitelist_apply
)
(
  manager_env_or_setting() { case "$1" in socks5_wl_flag) printf 1 ;; socks5_ips) printf "" ;; *) return 1 ;; esac; }
  no "enabled empty whitelist fails closed" socks5_whitelist_apply
)
(
  manager_env_or_setting() { case "$1" in socks5_wl_flag) printf 1 ;; socks5_ips) printf invalid.example ;; *) return 1 ;; esac; }
  no "invalid whitelist cannot reach permissive fallback" socks5_whitelist_apply
)
# An alternate-family policy is still required when only IPv4 sources are allowed.
fw_reset
(
  manager_env_or_setting() { case "$1" in socks5_wl_flag) printf 1 ;; socks5_ips) printf 192.0.2.10 ;; *) return 1 ;; esac; }
  ok "IPv4-only allowlist still protects IPv6" socks5_whitelist_apply
  ok "IPv6 has terminal DROP without ACCEPT bypass" python3 -c 'import json,os; s=json.load(open(os.environ["FW_STATE"]+"/ip6tables.json")); c=s["INPUT"][0][-1]; assert s[c]==[["-j","DROP"]]'
)
set_setting socks5_wl_flag 0
ok "disabling whitelist removes only owned chains" socks5_whitelist_apply
ok "disabled policy preserves unrelated INPUT rules" python3 -c 'import json,os; expected=[["-p","tcp","--dport","2200","-j","ACCEPT"]]; assert all(json.load(open(os.environ["FW_STATE"]+"/"+f+".json"))["INPUT"] == expected for f in ("iptables","ip6tables"))'
set_setting socks5_wl_flag 1
# Explicit error guards must work even when the entire function is conditional.
(
  init_storage() { return 74; }
  install_core() { : >"$TEST_ROOT/unexpected-install"; }
  no "ensure ready propagates storage failure under conditional caller" ensure_singbox_ready
  ok "failed init cannot install core" test ! -e "$TEST_ROOT/unexpected-install"
)
(
  init_storage() { :; }
  MIHOMO_BIN="$TEST_ROOT/missing-core"
  install_core() { return 75; }
  systemd_available() { return 1; }
  openrc_available() { return 1; }
  no "ensure ready propagates failed core install" ensure_singbox_ready
)
(
  init_storage() { :; }
  systemd_available() { return 0; }
  openrc_available() { return 1; }
  SYSTEMD_SERVICE_FILE="$TEST_ROOT/missing-unit"
  create_systemd_units() { return 76; }
  no "ensure ready propagates systemd unit creation failure" ensure_singbox_ready
)
(
  init_storage() { :; }
  systemd_available() { return 1; }
  openrc_available() { return 0; }
  OPENRC_SERVICE_FILE="$TEST_ROOT/missing-openrc"
  create_openrc_units() { return 77; }
  create_cron_watchdog() { : >"$TEST_ROOT/unexpected-cron"; }
  no "ensure ready propagates OpenRC unit creation failure" ensure_singbox_ready
  ok "failed OpenRC creation cannot create cron entry" test ! -e "$TEST_ROOT/unexpected-cron"
)
# Readiness consumes production metadata and checks every TCP/UDP port.
json_set_record "$NODES_FILE" hy2 '{"protocol":"hy2","port":30903}'
(
  MM_READINESS_RETRIES=1
  sleep() { :; }
  probe_tcp_port() { [ "$2" != 30902 ]; }
  udp_port_binding_alive() { return 0; }
  no "one missing TCP listener makes readiness fail" verify_data_plane_ready
  probe_tcp_port() { return 0; }
  udp_port_binding_alive() { return 1; }
  no "missing UDP listener makes readiness fail" verify_data_plane_ready
  udp_port_binding_alive() { return 0; }
  ok "all TCP and UDP listeners pass readiness" verify_data_plane_ready
  node_meta_bulk() { return 78; }
  no "metadata failure is not reported as zero-node readiness" verify_data_plane_ready
)
# 低内存主机（BR-Oracle-nat 128MB，loadavg>13）冷启动 mihomo 明显超过默认 10 次
# 就绪等待，固定默认值会误判“数据面就绪失败”并回滚；默认次数必须随内存上调。
(
  printf 'MemTotal:       131072 kB\n' >"$TEST_ROOT/mem-low"
  printf 'MemTotal:      1048576 kB\n' >"$TEST_ROOT/mem-high"
  low="$(MM_MEMINFO_FILE="$TEST_ROOT/mem-low" mm_default_readiness_retries)"
  ok "low-memory host raises readiness retries to 30" test "$low" = 30
  normal="$(MM_MEMINFO_FILE="$TEST_ROOT/mem-high" mm_default_readiness_retries)"
  ok "normal host keeps 10 readiness retries" test "$normal" = 10
  missing="$(MM_MEMINFO_FILE="$TEST_ROOT/no-such-meminfo" mm_default_readiness_retries)"
  ok "unreadable meminfo falls back to 10 readiness retries" test "$missing" = 10
)
# MM-02 附加：BusyBox 的 setpriv 只管理能力位、不支持 uid/gid 切换（Alpine 精简
# 镜像实测 --reuid 直接报 unrecognized option），必须回退到 su-su，否则服务用户
# 校验必然失败。这里用行为桩复现两种 setpriv，避免依赖宿主实现。
(
  priv_bin="$TEST_ROOT/priv-busybox"
  mkdir -p "$priv_bin"
  cat >"$priv_bin/setpriv" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in --dump|--nnp|--inh-caps*|--ambient-caps*|--bounding-set*) exit 0 ;; esac
printf 'setpriv: unrecognized option: %s\n' "${1#--}" >&2
exit 1
STUB
  chmod 700 "$priv_bin/setpriv"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$priv_bin/su"
  chmod 700 "$priv_bin/su"
  PATH="$priv_bin:$PATH"
  ok "BusyBox 风格 setpriv 回退到 su" test "$(service_priv_drop_kind)" = su
)
(
  priv_bin="$TEST_ROOT/priv-utillinux"
  mkdir -p "$priv_bin"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$priv_bin/setpriv"
  chmod 700 "$priv_bin/setpriv"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$priv_bin/su"
  chmod 700 "$priv_bin/su"
  PATH="$priv_bin:$PATH"
  ok "可用的 util-linux setpriv 优先于 su" test "$(service_priv_drop_kind)" = setpriv
)
(
  command_exists() { return 1; }
  no "缺少降权工具时明确拒绝" service_priv_drop_kind
)
shell_quote_roundtrip() {
  local arg out rc=0
  for arg in "it's a b" '$HOME' '$(id)' 'a"b' 'x y'; do
    out="$(eval printf '%s' "$(service_shell_quote "$arg")")" || rc=1
    [ "$out" = "$arg" ] || rc=1
  done
  return "$rc"
}
ok "降权命令行引号转义保持原参数" shell_quote_roundtrip

(
  MM_TEST_MODE=0
  service_data_permissions() { :; }
  socks5_whitelist_apply() { return 79; }
  mihomo_validate() { : >"$TEST_ROOT/validation-after-failed-fw"; }
  no "start fails before launch when whitelist fails" start_service
  ok "failed whitelist cannot proceed to validation" test ! -e "$TEST_ROOT/validation-after-failed-fw"
)
(
  MM_TEST_MODE=0 MM_DEFER_WATCHDOG_ENABLE=1
  service_data_permissions() { :; }
  socks5_whitelist_apply() { :; }
  mihomo_validate() { :; }
  warn_if_bindv6only() { :; }
  go_mem_limit_value() { :; }
  systemd_available() { return 0; }
  create_systemd_units() { :; }
  systemctl() { printf "%s\n" "$*" >>"$TEST_ROOT/launch-calls"; }
  verify_data_plane_ready() { return 80; }
  stop_service() { : >"$TEST_ROOT/readiness-stop"; }
  no "start propagates readiness failure under conditional caller" start_service
  ok "failed readiness stops newly started service" test -f "$TEST_ROOT/readiness-stop"
)
(
  MM_TEST_MODE=0 MM_DEFER_WATCHDOG_ENABLE=0
  service_data_permissions() { :; }
  socks5_whitelist_apply() { :; }
  mihomo_validate() { :; }
  warn_if_bindv6only() { :; }
  go_mem_limit_value() { :; }
  systemd_available() { return 0; }
  create_systemd_units() { :; }
  systemctl() { :; }
  verify_data_plane_ready() { :; }
  ensure_watchdog_enabled() { return 87; }
  stop_service() { : >"$TEST_ROOT/watchdog-enable-stop"; }
  no "start propagates watchdog setup failure" start_service
  ok "failed watchdog setup stops the candidate service" test -f "$TEST_ROOT/watchdog-enable-stop"
)
(
  MM_TEST_MODE=0
  mihomo_validate() { :; }
  stop_service() { printf "stop\n" >>"$TEST_ROOT/reload-stops"; }
  start_service() { :; }
  verify_data_plane_ready() { return 81; }
  no "reload propagates readiness failure" reload_service
  ok "reload stops old and unready new service" test "$(wc -l <"$TEST_ROOT/reload-stops")" = 2
)
# Source-only watchdog entrypoint must remain safe in test mode.
(
  source "$ROOT_DIR/scripts/watchdog.sh"
  WD_TRACE="$TEST_ROOT/watchdog-trace"
  WD_INSTALL="$TEST_ROOT/watchdog-unexpected-install"
  install_core() { : >"$WD_INSTALL"; return 90; }
  install_cloudflared() { : >"$WD_INSTALL"; return 90; }
  ensure_dependencies() { : >"$WD_INSTALL"; return 90; }
  (
    MIHOMO_BIN="$TEST_ROOT/watchdog-missing-core"
    ok "watchdog skips absent core without installing dependencies" ensure_singbox
    ok "watchdog never installs an absent core" test ! -e "$WD_INSTALL"
  )
  (
    node_meta_bulk() { return 84; }
    start_argo_node() { : >"$TEST_ROOT/watchdog-argo-after-metadata-error"; }
    no "watchdog propagates failed Argo metadata read" ensure_argo_nodes
    ok "metadata failure cannot launch Argo" test ! -e "$TEST_ROOT/watchdog-argo-after-metadata-error"
  )
  (
    node_meta_bulk() { printf "temporary\tvless-argo\t30911\ttemp\nnamed\tvless-argo\t30912\ttoken\n"; }
    argo_node_running() { return 1; }
    start_argo_node() { printf "%s\n" "$1" >>"$TEST_ROOT/watchdog-argo-starts"; [ "$1" != temporary ]; }
    no "watchdog propagates shared Argo starter failure" ensure_argo_nodes
    ok "watchdog uses shared starter for temporary and named tunnels" test "$(<"$TEST_ROOT/watchdog-argo-starts")" = $'temporary\nnamed'
  )
  (
    systemd_available() { return 0; }
    systemctl() { return 85; }
    no "watchdog restart propagates service-manager failure" restart_singbox
  )
  (
    systemd_available() { return 0; }
    systemctl() { :; }
    verify_data_plane_ready() { return 86; }
    stop_service() { : >"$TEST_ROOT/watchdog-stopped-unready"; }
    no "watchdog propagates restart readiness failure" restart_singbox
    ok "watchdog stops unready restarted service" test -f "$TEST_ROOT/watchdog-stopped-unready"
  )
  (
    printf "live-core-cache\n" >"$BASE_DIR/data/cache.db"
    rm -f "$LOG_DIR/mihomo.log"
    ok "watchdog actual rotation succeeds when core log is absent" ensure_log_rotation
    ok "missing log does not get created by rotation" test ! -e "$LOG_DIR/mihomo.log"
    printf "small-core-log\n" >"$LOG_DIR/mihomo.log"
    printf "small-tunnel-log\n" >"$LOG_DIR/test.cloudflared.log"
    ok "watchdog actual rotation succeeds for small core and tunnel logs" ensure_log_rotation
    ok "small core log stays intact" grep -Fx small-core-log "$LOG_DIR/mihomo.log"
    ok "small tunnel log stays intact" grep -Fx small-tunnel-log "$LOG_DIR/test.cloudflared.log"
    ok "live cache survives watchdog log rotation" grep -Fx live-core-cache "$BASE_DIR/data/cache.db"
  )
  wd_call() { printf "%s\n" "$1" >>"$WD_TRACE"; [ "${WD_FAIL:-}" != "$1" ]; }
  require_root() { :; }
  require_bash4() { :; }
  try_acquire_lock() { wd_call lock && [ "${WD_LOCK_FAIL:-0}" != 1 ]; }
  setup_common_traps() { wd_call traps; }
  init_storage() { wd_call init_storage; }
  sanitize_permissions() { wd_call sanitize; }
  ensure_log_rotation() { wd_call logs; }
  reconcile_state() { wd_call reconcile; }
  ensure_singbox() { wd_call recover; }
  ensure_argo_nodes() { wd_call argo; }
  ensure_sub() { wd_call sub; }
  write_metrics_line() { wd_call metrics; }
  release_lock() { wd_call unlock; }
  WD_LOCK_FAIL=1
  : >"$WD_TRACE"
  no "watchdog lock contention aborts the round" watchdog_main
  ok "watchdog lock failure performs no state mutations or trap setup" test "$(<"$WD_TRACE")" = lock
  WD_LOCK_FAIL=0 WD_FAIL=init_storage
  : >"$WD_TRACE"
  no "watchdog propagates storage initialization failure" watchdog_main
  ok "watchdog stops immediately after failed storage initialization" test "$(<"$WD_TRACE")" = $'lock\ntraps\ninit_storage'
  WD_FAIL=reconcile
  : >"$WD_TRACE"
  no "watchdog propagates reconciliation failure" watchdog_main
  ok "failed reconciliation cannot reach recovery or metrics" test "$(<"$WD_TRACE")" = $'lock\ntraps\ninit_storage\nsanitize\nlogs\nreconcile'
  WD_FAIL=recover
  : >"$WD_TRACE"
  no "watchdog propagates core recovery failure" watchdog_main
  ok "failed core recovery cannot reach Argo or metrics" test "$(<"$WD_TRACE")" = $'lock\ntraps\ninit_storage\nsanitize\nlogs\nreconcile\nrecover'
  WD_FAIL=argo
  : >"$WD_TRACE"
  no "watchdog propagates tunnel recovery failure" watchdog_main
  ok "failed tunnel recovery cannot write metrics" test "$(<"$WD_TRACE")" = $'lock\ntraps\ninit_storage\nsanitize\nlogs\nreconcile\nrecover\nargo'
  WD_FAIL=sub
  : >"$WD_TRACE"
  no "watchdog propagates subscription recovery failure" watchdog_main
  ok "failed subscription recovery cannot write metrics" test "$(<"$WD_TRACE")" = $'lock\ntraps\ninit_storage\nsanitize\nlogs\nreconcile\nrecover\nargo\nsub'
  WD_FAIL=""
  : >"$WD_TRACE"
  ok "successful watchdog round releases the acquired lock" watchdog_main
  ok "watchdog orders mutations after lock and releases last" test "$(<"$WD_TRACE")" = $'lock\ntraps\ninit_storage\nsanitize\nlogs\nreconcile\nrecover\nargo\nsub\nmetrics\nsanitize\nunlock'
  ok "watchdog round never calls runtime installers" test ! -e "$WD_INSTALL"
)
# Optional kernel validation uses an explicitly supplied, previously verified executable.
if [ -n "$REAL_MIHOMO_BIN" ] && [ -x "$REAL_MIHOMO_BIN" ]; then
  (
    MIHOMO_BIN="$REAL_MIHOMO_BIN"
    printf "mode: direct\nlog-level: silent\nproxies: []\nrules: []\n" >"$CONFIG_FILE"
    ok "real supplied mihomo accepts service -d/-t/-f argv" mihomo_validate
    # The earlier cache-preservation check deliberately used a text sentinel.
    rm -f "$BASE_DIR/data/cache.db"
    owned_pid="" foreign_pid=""
    core_cleanup() {
      local child
      for child in "$owned_pid" "$foreign_pid"; do
        [ -n "$child" ] || continue
        kill -TERM "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
      done
    }
    trap core_cleanup EXIT
    core_live() {
      local stat
      local -a observed=()
      IFS= read -r stat 2>/dev/null <"/proc/$1/stat" || return 1
      read -r -a observed <<<"${stat##*) }"
      [ -n "${observed[0]:-}" ] && [[ "${observed[0]}" != [ZXx] ]] || return 1
      [ -z "${2:-}" ] || [ "${observed[19]:-}" = "$2" ]
    }
    wait_for_exec() {
      local child="$1" expected_config="${2:-$CONFIG_FILE}" attempt
      local -a actual_argv=()
      for attempt in {1..100}; do
        core_live "$child" || return 1
        actual_argv=()
        mapfile -d '' -t actual_argv <"/proc/$child/cmdline" 2>/dev/null || true
        if [ "$(readlink -f "/proc/$child/exe" 2>/dev/null || true)" = "$(readlink -f "$MIHOMO_BIN")" ] &&
          [ "${#actual_argv[@]}" -eq 5 ] && [ "${actual_argv[1]:-}" = -d ] &&
          { [ "${actual_argv[2]:-}" = "$BASE_DIR/data" ] || [ "${actual_argv[2]:-}" = "$BASE_DIR" ]; } &&
          [ "${actual_argv[3]:-}" = -f ] && [ "${actual_argv[4]:-}" = "$expected_config" ]; then return 0; fi
        sleep 0.02
      done
      return 1
    }
    foreign_config="$BASE_DIR/other-config.yaml"
    cp "$CONFIG_FILE" "$foreign_config"
    env SAFE_PATHS="$BASE_DIR:$CERT_DIR" "$MIHOMO_BIN" -d "$BASE_DIR/data" -f "$foreign_config" >"$TEST_ROOT/foreign-core.log" 2>&1 &
    foreign_pid=$!
    ok "foreign-config fixture executes the same real core" wait_for_exec "$foreign_pid" "$foreign_config"
    no "different configuration is not this instance's core" mihomo_process_matches "$foreign_pid"
    write_pid_file "$PID_FILE" "$foreign_pid"
    no "stop refuses numeric PID file pointing to foreign configuration" stop_mihomo_pid_file
    ok "foreign core survives refused stop" core_live "$foreign_pid"
    ok "foreign PID evidence is retained after refused stop" test -f "$PID_FILE"
    kill -TERM "$foreign_pid"
    wait "$foreign_pid" 2>/dev/null || true
    foreign_pid=""
    rm -f "$PID_FILE"
    env SAFE_PATHS="$BASE_DIR:$CERT_DIR" "$MIHOMO_BIN" -d "$BASE_DIR/data" -f "$CONFIG_FILE" >"$TEST_ROOT/owned-core.log" 2>&1 &
    owned_pid=$!
    ok "owned-config fixture executes the same real core" wait_for_exec "$owned_pid"
    ok "exact working-directory and config argv identifies owned core" mihomo_process_matches "$owned_pid"
    ok "owned PID and birth token can be saved securely" write_mihomo_pid_file "$owned_pid"
    saved_identity="$(<"$PID_FILE")"
    printf "%s 0\n" "$owned_pid" >"$PID_FILE"
    no "forged birth token cannot stop an otherwise matching core" stop_mihomo_pid_file
    ok "matching core survives forged birth token" core_live "$owned_pid"
    ok "forged birth token evidence is retained" test "$(<"$PID_FILE")" = "$owned_pid 0"
    printf "%s\n" "$saved_identity" >"$PID_FILE"
    ok "verified owned core terminates successfully" stop_mihomo_pid_file
    no "owned core is no longer running after stop" core_live "$owned_pid" "${saved_identity#* }"
    ok "successful verified stop removes PID evidence" test ! -e "$PID_FILE"
    if core_live "$owned_pid"; then kill -TERM "$owned_pid" 2>/dev/null || true; fi
    wait "$owned_pid" 2>/dev/null || true
    owned_pid=""
    # Upgrade may encounter a verified v1.2.7 process using the old working directory.
    env SAFE_PATHS="$BASE_DIR:$CERT_DIR" "$MIHOMO_BIN" -d "$BASE_DIR" -f "$CONFIG_FILE" >"$TEST_ROOT/legacy-core.log" 2>&1 &
    owned_pid=$!
    ok "legacy working-directory fixture executes same real core" wait_for_exec "$owned_pid"
    ok "exact legacy working directory is recognized for migration" mihomo_process_matches "$owned_pid"
    write_pid_file "$PID_FILE" "$owned_pid"
    legacy_birth="$(managed_proc_birth "$owned_pid")"
    ok "verified legacy numeric PID can be stopped for migration" stop_mihomo_pid_file
    no "legacy core no longer runs after migration stop" core_live "$owned_pid" "$legacy_birth"
    ok "legacy migration stop removes PID evidence" test ! -e "$PID_FILE"
    if core_live "$owned_pid"; then kill -TERM "$owned_pid" 2>/dev/null || true; fi
    wait "$owned_pid" 2>/dev/null || true
    owned_pid=""
    # Deliberately retain the launch shell briefly to exercise the exec handoff.
    ( sleep 0.15; exec env SAFE_PATHS="$BASE_DIR:$CERT_DIR" "$MIHOMO_BIN" -d "$BASE_DIR/data" -f "$CONFIG_FILE" ) >"$TEST_ROOT/delayed-core.log" 2>&1 &
    owned_pid=$!
    ok "PID recording waits for a verified delayed exec handoff" write_mihomo_pid_file "$owned_pid"
    ok "delayed exec is fully identified before PID save returns" mihomo_process_matches "$owned_pid"
    delayed_identity="$(<"$PID_FILE")"
    ok "delayed owned core can be stopped by verified identity" stop_mihomo_pid_file
    no "delayed owned core no longer runs after verified stop" core_live "$owned_pid" "${delayed_identity#* }"
    if core_live "$owned_pid"; then kill -TERM "$owned_pid" 2>/dev/null || true; fi
    wait "$owned_pid" 2>/dev/null || true
    owned_pid=""
    # A failed PID-file write must clean up only the freshly launched birth token.
    env SAFE_PATHS="$BASE_DIR:$CERT_DIR" "$MIHOMO_BIN" -d "$BASE_DIR/data" -f "$CONFIG_FILE" >"$TEST_ROOT/candidate-core.log" 2>&1 &
    owned_pid=$!
    wait_for_exec "$owned_pid"
    candidate_birth="$(managed_proc_birth "$owned_pid")"
    ok "candidate cleanup with a mismatched birth is an idempotent no-op" stop_mihomo_candidate "$owned_pid" 0
    ok "mismatched candidate birth does not signal the live process" core_live "$owned_pid" "$candidate_birth"
    ok "candidate cleanup stops the recorded launch birth" stop_mihomo_candidate "$owned_pid" "$candidate_birth"
    no "candidate no longer runs after matching-birth cleanup" core_live "$owned_pid" "$candidate_birth"
    if core_live "$owned_pid"; then kill -TERM "$owned_pid" 2>/dev/null || true; fi
    wait "$owned_pid" 2>/dev/null || true
    owned_pid=""
    for caller in service watchdog; do
      (
        # Source the real watchdog entrypoint, then isolate only host-facing helpers.
        source "$ROOT_DIR/scripts/watchdog.sh"
        trap core_cleanup EXIT
        MM_TEST_MODE=1 MM_DEFER_WATCHDOG_ENABLE=1
        service_data_permissions() { :; }
        socks5_whitelist_apply() { :; }
        warn_if_bindv6only() { :; }
        go_mem_limit_value() { :; }
        go_gc_requested() { return 1; }
        systemd_available() { return 1; }
        openrc_available() { return 1; }
        stop_service() { :; }
        stop_mihomo_pid_file() { :; }
        write_mihomo_pid_file() {
          owned_pid="$1"
          candidate_birth="$(managed_proc_birth "$owned_pid")" || return 1
          wait_for_exec "$owned_pid" || return 1
          : >"$TEST_ROOT/$caller-pid-save-failed"
          return 88
        }
        if [ "$caller" = service ]; then launch=start_service; else launch=start_non_systemd_singbox; fi
        no "$caller propagates failed PID recording" "$launch"
        ok "$caller PID-save fault reached a live real core" test -f "$TEST_ROOT/$caller-pid-save-failed"
        no "$caller cleans up the launched process after PID-save failure" core_live "$owned_pid" "$candidate_birth"
        if core_live "$owned_pid"; then kill -TERM "$owned_pid" 2>/dev/null || true; fi
        wait "$owned_pid" 2>/dev/null || true
        owned_pid=""
      )
    done
  )
else
  skip "real mihomo validation (set MIHOMO_BIN to a verified local executable)"
fi
# MM-03: a 0700 parent目录会挡住服务用户读取配置，只补“其他用户可穿越”一位即可。
(
  parent="$TEST_ROOT/traverse-parent"
  mkdir -p "$parent/base"
  chmod 0700 "$parent"
  chmod 0700 "$TEST_ROOT"
  BASE_DIR="$parent/base"
  ok "0700 parent of BASE_DIR is made traversable for the service user" service_ensure_parent_traversal
  ok "traversal fix adds only the other-execute bit" test "$(stat -c '%a' "$parent")" = 701
  ok "traversal fix keeps the config directory unreadable" test "$(stat -c '%a' "$parent")" = 701
  chmod 0700 "$TEST_ROOT"
  rm -rf -- "$parent"
)
(
  parent="$TEST_ROOT/traverse-missing"
  BASE_DIR="$parent/base"
  no "missing parent of BASE_DIR is reported instead of guessed" service_ensure_parent_traversal
)
# DAC tests intentionally require opt-in and use only an existing unprivileged identity.
if [ "${MM_SERVICE_DAC_TEST:-0}" = 1 ]; then
  if [ "$EUID" != 0 ] || ! command -v python3 >/dev/null 2>&1 || ! getent passwd nobody >/dev/null; then
    printf "MM_SERVICE_DAC_TEST=1 requires root, python3 and existing nobody with resolvable primary group.\n" >&2
    exit 1
  fi
  (
    uid="$(id -u nobody)"; gid="$(id -g nobody)"; dac_group="$(id -gn nobody)"
    [ "$uid" -gt 0 ] || exit 1
    dac_entry="$(getent group "$dac_group")"
    [ "$(printf '%s' "$dac_entry" | cut -d: -f3)" = "$gid" ] || exit 1
    printf 'FIXTURE_META DAC user=nobody uid=%s group=%s gid=%s\n' "$uid" "$dac_group" "$gid"
    MM_TEST_MODE=0 MIHOMO_SERVICE_USER=nobody MIHOMO_SERVICE_GROUP="$dac_group"
    chmod 711 "$TEST_ROOT"
    printf "private-cert\n" >"$CERT_DIR/test.crt"
    printf "private-key\n" >"$CERT_DIR/test.key"
    service_data_permissions
    private="$(sub_private_dir)"; public="$(sub_public_dir)"
    install -d -m 700 "$private" "$public"
    printf "private-subscription\n" >"$private/payload.txt"
    chmod 600 "$private/payload.txt"
    printf "root-management-code\n" >"$LIB_DIR/code.sh"
    chmod 700 "$LIB_DIR"; chmod 600 "$LIB_DIR/code.sh"
    # Existing primary uid/gid resolved above; no identity mutations.
    as_core() {
      python3 -c 'import os,sys; os.setgroups([]); os.setgid(int(sys.argv[2])); os.setuid(int(sys.argv[1])); os.execvp(sys.argv[3],sys.argv[3:])' "$uid" "$gid" "$@"
    }
    ok "core identity can read config" as_core test -r "$CONFIG_FILE"
    ok "core identity can read cert" as_core test -r "$CERT_DIR/test.crt"
    ok "core identity can read key" as_core test -r "$CERT_DIR/test.key"
    ok "core identity can write own data directory" as_core touch "$BASE_DIR/data/own-cache"
    no "core identity cannot read node table" as_core test -r "$NODES_FILE"
    no "core identity cannot read secret table" as_core test -r "$SECRETS_FILE"
    no "core identity cannot read settings" as_core test -r "$SETTING_FILE"
    no "core identity cannot read management code" as_core test -r "$LIB_DIR/code.sh"
    no "core identity cannot read private subscription" as_core test -r "$private/payload.txt"
    no "core identity cannot overwrite configuration" as_core test -w "$CONFIG_FILE"
    no "core identity cannot rename private subscription directory" as_core mv -T "$private" "$private.moved"
    no "core identity cannot rename public subscription directory" as_core mv -T "$public" "$public.moved"
    no "core identity cannot replace sibling secret table" as_core mv -T "$SECRETS_FILE" "$SECRETS_FILE.moved"
    ok "private subscription survived rename attempts" test -f "$private/payload.txt"
  )
else
  skip "root DAC assertions (explicit MM_SERVICE_DAC_TEST=1 only)"
fi
PASSED="$(awk '$0 == "+" {n++} END {print n+0}' "$RESULTS")"
FAILED="$(awk '$0 == "-" {n++} END {print n+0}' "$RESULTS")"
printf "Service audit: %s passed, %s failed\n" "$PASSED" "$FAILED"
[ "$FAILED" = 0 ]
