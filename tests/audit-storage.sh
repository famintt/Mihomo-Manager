#!/usr/bin/env bash
# MM-04/MM-15: failure injection, exact snapshots, flock and mkdir ownership.
# Indirect mocks are invoked by sourced production functions.
# shellcheck disable=SC1091,SC2016,SC2034,SC2317
set -eEuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
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
  if "$@"; then printf '+\n' >>"$RESULTS"; else printf '%s\n' - >>"$RESULTS"; printf 'FAIL: %s\n' "$description" >&2; fi
}
no() {
  local description="$1"; shift
  if "$@"; then printf '%s\n' - >>"$RESULTS"; printf 'FAIL (accepted): %s\n' "$description" >&2; else printf '+\n' >>"$RESULTS"; fi
}
same() { cmp -s "$1" "$2"; }
# No service manager, binary installation, network, or host permission changes.
stop_service() { printf 'stop\n' >>"$TEST_ROOT/stopped"; }
start_service() { printf 'restart\n' >>"$TEST_ROOT/restarted"; }
restart_all_argo_nodes() { :; }
stop_all_argo_nodes() { :; }
init_storage
ok 'fresh tables are objects' validate_storage_tables
ok 'fresh private settings' test "$(stat -c %a "$SETTING_FILE")" = 600
json_set_record "$NODES_FILE" keep '{"protocol":"socks5","port":30901}'
json_set_record "$SECRETS_FILE" keep '{"password":"old"}'
printf 'old-config\n' >"$CONFIG_FILE"
printf 'old-cert\n' >"$CERT_DIR/keep.crt"
set_setting mode old
cp "$NODES_FILE" "$TEST_ROOT/nodes.before"
cp "$SECRETS_FILE" "$TEST_ROOT/secrets.before"
(
  printf '{broken' >"$NODES_FILE"
  cp "$NODES_FILE" "$TEST_ROOT/broken.before"
  no 'corrupt nodes cannot initialize' init_storage
  no 'corrupt nodes cannot reconcile' reconcile_state
  ok 'corrupt nodes unchanged' same "$NODES_FILE" "$TEST_ROOT/broken.before"
  ok 'corrupt nodes leave secrets untouched' same "$SECRETS_FILE" "$TEST_ROOT/secrets.before"
)
cp "$TEST_ROOT/nodes.before" "$NODES_FILE"
(
  rm "$SECRETS_FILE"
  no 'missing secrets cannot initialize' init_storage
  no 'missing secrets cannot reconcile' reconcile_state
  ok 'missing secrets not recreated' test ! -e "$SECRETS_FILE"
  ok 'missing secrets leave nodes intact' same "$NODES_FILE" "$TEST_ROOT/nodes.before"
)
cp "$TEST_ROOT/secrets.before" "$SECRETS_FILE"
(
  printf '[]\n' >"$SECRETS_FILE"
  no 'array secrets rejected' init_storage
  printf '{}\n{}\n' >"$SECRETS_FILE"
  no 'multiple JSON documents rejected' validate_storage_tables
)
cp "$TEST_ROOT/secrets.before" "$SECRETS_FILE"
(
  printf '{broken' >"$SETTING_FILE"
  no 'corrupt settings read fails' get_setting mode default
  no 'corrupt settings forwarded failure' manager_env_or_setting mode default
  no 'corrupt settings cannot initialize' init_storage
)
printf '{"mode":"old"}\n' >"$SETTING_FILE"
(
  jq() { return 70; }
  no 'JSON mutator propagates jq error' json_set_record "$NODES_FILE" bad '{}'
  no 'JSON delete propagates jq error' json_delete_record "$NODES_FILE" keep
  no 'JSON field propagates jq error' json_set_field "$NODES_FILE" keep name bad
  ok 'failed mutators preserve file' same "$NODES_FILE" "$TEST_ROOT/nodes.before"
)
SNAPSHOT="$(backup_state)"
ok 'snapshot has checksum manifest' test -s "$SNAPSHOT/MANIFEST.sha256"
(
  cp() { return 71; }
  no 'snapshot copy failure propagates' backup_state
)
ok 'failed snapshot not published' test "$(find "$BASE_DIR/backups" -maxdepth 1 -type d -name '[0-9]*' | wc -l)" = 1
# An immutable test reference is not subject to normal ten-snapshot retention.
cp -a "$SNAPSHOT" "$TEST_ROOT/reference-snapshot"
SNAPSHOT="$TEST_ROOT/reference-snapshot"
printf '{"new":{}}\n' >"$NODES_FILE"
printf '{"new":{}}\n' >"$SECRETS_FILE"
printf 'new-config\n' >"$CONFIG_FILE"
printf '{"mode":"new"}\n' >"$SETTING_FILE"
printf 'new-cert\n' >"$CERT_DIR/new.crt"
printf 'changed\n' >"$CERT_DIR/keep.crt"
ok 'exact snapshot restore succeeds' restore_state_backup "$SNAPSHOT"
ok 'restore nodes exact bytes' same "$NODES_FILE" "$TEST_ROOT/nodes.before"
ok 'restore secrets exact bytes' same "$SECRETS_FILE" "$TEST_ROOT/secrets.before"
ok 'restore config exact bytes' same "$CONFIG_FILE" "$SNAPSHOT/config.yaml"
ok 'restore settings exact bytes' same "$SETTING_FILE" "$SNAPSHOT/settings.json"
ok 'restore old cert exact bytes' same "$CERT_DIR/keep.crt" "$SNAPSHOT/certs/keep.crt"
ok 'new certificates removed on restore' test ! -e "$CERT_DIR/new.crt"
(
  printf 'tampered\n' >>"$SNAPSHOT/config.yaml"
  no 'tampered snapshot rejected before publication' restore_state_backup "$SNAPSHOT"
  ok 'tampered snapshot leaves current config' test "$(<"$CONFIG_FILE")" = old-config
)
# The subshell changed disk bytes; repair only the test snapshot for later cases.
printf 'old-config\n' >"$SNAPSHOT/config.yaml"
(
  find() { case "$*" in *'-type l'*) return 77 ;; esac; command find "$@"; }
  no 'snapshot rejects certificate scan failure' backup_state
  no 'restore rejects certificate scan failure' restore_state_backup "$SNAPSHOT"
  ok 'failed restore scan preserves config' test "$(<"$CONFIG_FILE")" = old-config
)
# A command substitution must neither roll back nor release the parent's transaction.
acquire_lock
_AUTO_ROLLBACK_DIR="$SNAPSHOT"
_AUTO_ROLLBACK_OWNER="$BASHPID"
_node_parent="$BASHPID"
printf 'in-flight\n' >"$CONFIG_FILE"
_out="$(rollback_pending_transaction; release_lock; printf child)"
ok 'child rollback marker cannot restore parent data' test "$(<"$CONFIG_FILE")" = in-flight
ok 'child cannot unlock parent flock' bash -c 'source "$1/lib/env.sh"; source "$1/lib/storage.sh"; ! try_acquire_lock' _ "$ROOT_DIR"
ok 'parent still owns bookkeeping' test "$LOCK_OWNER_PID" = "$_node_parent"
rollback_pending_transaction
ok 'owner transaction restores exact config' test "$(<"$CONFIG_FILE")" = old-config
ok 'owner rollback restarts service' test -s "$TEST_ROOT/restarted"
release_lock
ok 'flock can be reacquired after release' try_acquire_lock
# A losing contender may not initialize or chmod its state directory.
new_base="$TEST_ROOT/not-created"
ok 'failed contender has no storage side effect' env BASE_DIR="$new_base" bash -c 'source "$1/lib/env.sh"; source "$1/lib/storage.sh"; ! try_acquire_lock && [ ! -e "$BASE_DIR" ]' _ "$ROOT_DIR"
release_lock
ok 'lock inode stays after release' test -f "$LOCK_FILE"
# Exercise the fallback even on systems with util-linux flock.
(
  command_exists() { [ "$1" != flock ] && command -v "$1" >/dev/null 2>&1; }
  acquire_lock
  touch -d '20 minutes ago' "$LOCK_DIR_FALLBACK"
  no 'fallback does not evict an old live owner' bash -c 'source "$1/lib/env.sh"; source "$1/lib/storage.sh"; command_exists() { [ "$1" != flock ] && command -v "$1" >/dev/null 2>&1; }; try_acquire_lock' _ "$ROOT_DIR"
  ( release_lock )
  ok 'fallback child cannot unlink parent lock' test -f "$LOCK_DIR_FALLBACK/owner"
  release_lock
  mkdir "$LOCK_DIR_FALLBACK"
  printf '99999999 impossible-identity\n' >"$LOCK_DIR_FALLBACK/owner"
  ok 'fallback reaps a dead owner' try_acquire_lock
  ok 'fallback records current owner' test "$LOCK_OWNER_PID" = "$BASHPID"
  release_lock
  ok 'fallback removes its own directory' test ! -e "$LOCK_DIR_FALLBACK"
)
# Mutating deletion must restore the same pre-operation state, including certificates.
(
  stop_argo_node() { :; }
  render_config() { printf 'partial-config\n' >"$CONFIG_FILE"; return 75; }
  reload_service() { return 75; }
  json_set_field "$NODES_FILE" keep certificate_path "$CERT_DIR/keep.crt"
  cp "$NODES_FILE" "$TEST_ROOT/delete.before"
  no 'single-node delete propagates render failure' delete_nodes_transaction keep
  ok 'failed delete restores node bytes' same "$NODES_FILE" "$TEST_ROOT/delete.before"
  ok 'failed delete restores secret bytes' same "$SECRETS_FILE" "$TEST_ROOT/secrets.before"
  ok 'failed delete restores exact config' test "$(<"$CONFIG_FILE")" = old-config
  ok 'failed delete restores certificates' test "$(<"$CERT_DIR/keep.crt")" = old-cert
  ok 'failed delete releases owned lock' test "$LOCK_HELD" = false
  no 'delete all propagates render failure' delete_all_nodes
  ok 'failed delete all restores nodes' same "$NODES_FILE" "$TEST_ROOT/delete.before"
  render_config() { printf 'deleted-config\n' >"$CONFIG_FILE"; }
  reload_service() { :; }
  acquire_lock
  ok 'successful deletion within parent transaction' delete_nodes_transaction keep
  ok 'deletion leaves parent lock held' test "$LOCK_HELD" = true
  ok 'successful deletion clears node' test "$(jq length "$NODES_FILE")" = 0
  ok 'successful deletion clears secrets' test "$(jq length "$SECRETS_FILE")" = 0
  ok 'successful deletion removes managed cert' test ! -e "$CERT_DIR/keep.crt"
  ok 'successful deletion commits marker' test -z "$_AUTO_ROLLBACK_DIR"
  release_lock
)
restore_state_backup "$SNAPSHOT" >/dev/null
(
  generate_hex() { return 74; }
  no 'WS path propagates RNG failure' random_ws_path
  no 'node tag propagates RNG failure' generate_tag socks
  ENV_NAME='' ENV_SOCKS5_USER='' ENV_SOCKS5_PASS='' ENV_PASSWD=''
  auto_save_node() { : >"$TEST_ROOT/unexpected-save"; }
  no 'automatic builder propagates RNG failure' auto_add_socks5 30902
  ok 'RNG failure never saves an incomplete node' test ! -e "$TEST_ROOT/unexpected-save"
  generate_hex() { :; }
  no 'empty RNG output cannot generate WS path' random_ws_path
  no 'empty RNG output cannot generate node tag' generate_tag socks
)
(
  mkdir "$TEST_ROOT/chmod-bin"
  printf '#!/usr/bin/env bash\ncase "$*" in *fail.crt*) exit 76;; esac\nexec /usr/bin/chmod "$@"\n' >"$TEST_ROOT/chmod-bin/chmod"
  chmod 700 "$TEST_ROOT/chmod-bin/chmod"
  printf insecure >"$CERT_DIR/fail.crt"
  chmod 644 "$CERT_DIR/fail.crt"
  export PATH="$TEST_ROOT/chmod-bin:$PATH"
  no 'sanitize propagates child chmod failure' sanitize_permissions
)
rm -f -- "$CERT_DIR/fail.crt"
# Exercise the full automatic orchestration under conditional callers (errexit is off).
for action in ins rep; do
  (
    ensure_singbox_ready() { :; }
    auto_has_node_env() { return 0; }
    auto_collect_specs() { printf 'socks5 30902\n'; }
    auto_try_port() { :; }
    cleanup_orphan_certs() { :; }
    stop_service() { :; }
    stop_argo_node() { :; }
    sub_enabled() { return 1; }
    sub_url_file() { printf '%s/nonexistent-url' "$TEST_ROOT"; }
    print_node_list() { :; }
    export vl_sni=example.com name=MiXeD socks5_password=fake-password
    cp "$NODES_FILE" "$TEST_ROOT/auto.nodes"
    cp "$SECRETS_FILE" "$TEST_ROOT/auto.secrets"
    cp "$SETTING_FILE" "$TEST_ROOT/auto.settings"
    render_config() { printf 'partial-auto\n' >"$CONFIG_FILE"; return 79; }
    reload_service() { :; }
    no "$action render failure propagates" auto_install "$action"
    ok "$action render failure restores nodes" same "$NODES_FILE" "$TEST_ROOT/auto.nodes"
    ok "$action render failure restores secrets" same "$SECRETS_FILE" "$TEST_ROOT/auto.secrets"
    ok "$action render failure restores settings" same "$SETTING_FILE" "$TEST_ROOT/auto.settings"
    ok "$action render failure restores exact config" test "$(<"$CONFIG_FILE")" = old-config
    ok "$action render failure releases lock" test "$LOCK_HELD" = false
    render_config() { printf 'new-auto\n' >"$CONFIG_FILE"; }
    reload_service() { return 81; }
    no "$action readiness failure propagates" auto_install "$action"
    ok "$action readiness failure restores nodes" same "$NODES_FILE" "$TEST_ROOT/auto.nodes"
    ok "$action readiness failure restores exact config" test "$(<"$CONFIG_FILE")" = old-config
    ok "$action readiness failure restores certs" test "$(<"$CERT_DIR/keep.crt")" = old-cert
    ok "$action readiness failure releases lock" test "$LOCK_HELD" = false
    reload_service() { :; }
    restart_all_argo_nodes() { return 83; }
    no "$action Argo readiness failure propagates" auto_install "$action"
    ok "$action Argo readiness failure restores nodes" same "$NODES_FILE" "$TEST_ROOT/auto.nodes"
    ok "$action Argo readiness failure restores secrets" same "$SECRETS_FILE" "$TEST_ROOT/auto.secrets"
    ok "$action Argo readiness failure restores exact config" test "$(<"$CONFIG_FILE")" = old-config
    ok "$action Argo readiness failure releases lock" test "$LOCK_HELD" = false
    restart_all_argo_nodes() { :; }
    set_setting sub_mode worker
    set_setting sub_domain https://worker.example.com
    set_setting sub_read_token fake-read-token
    set_setting sub_report_token fake-report-token
    unset sub_mode sub_domain sub_read_token sub_report_token sub
    ok "$action success commits automatic transaction" auto_install "$action"
    ok "$action preserves omitted worker mode" test "$(get_setting sub_mode)" = worker
    ok "$action preserves omitted worker domain" test "$(get_setting sub_domain)" = https://worker.example.com
    ok "$action preserves omitted read token" test "$(get_setting sub_read_token)" = fake-read-token
    ok "$action preserves omitted report token" test "$(get_setting sub_report_token)" = fake-report-token
    ok "$action clears committed marker" test -z "$_AUTO_ROLLBACK_DIR"
  )
  restore_state_backup "$SNAPSHOT" >/dev/null
done
# Subscription export must never publish a partial set after a failed link/read/write.
(
  set_setting direct_host example.com
  iter_node_tags() { printf 'keep\nbroken\n'; }
  build_share_link() { if [ "$1" = keep ]; then printf 'socks5://fake-link'; else return 78; fi; }
  printf 'previous-subscription\n' >"$TEST_ROOT/export.txt"
  cp "$TEST_ROOT/export.txt" "$TEST_ROOT/export.before"
  no 'failed link aborts file export' sub_command "$TEST_ROOT/export.txt"
  ok 'failed link preserves published file' same "$TEST_ROOT/export.txt" "$TEST_ROOT/export.before"
  no 'failed link aborts stdout export' sub_command >"$TEST_ROOT/export.stdout"
  ok 'failed link emits no partial stdout' test ! -s "$TEST_ROOT/export.stdout"
  iter_node_tags() { printf 'keep\n'; }
  ok 'valid subscription export succeeds' sub_command "$TEST_ROOT/export.txt"
  ok 'export content is complete' test "$(base64 -d <"$TEST_ROOT/export.txt")" = socks5://fake-link
  ok 'export private mode' test "$(stat -c %a "$TEST_ROOT/export.txt")" = 600
  ln -s "$TEST_ROOT/export.txt" "$TEST_ROOT/export-link"
  no 'export rejects symlink destination' sub_command "$TEST_ROOT/export-link"
  cp "$TEST_ROOT/export.txt" "$TEST_ROOT/export.before"
  mv() { return 79; }
  no 'export publication failure propagates' sub_command "$TEST_ROOT/export.txt"
  ok 'export publication failure preserves prior file' same "$TEST_ROOT/export.txt" "$TEST_ROOT/export.before"
)
restore_state_backup "$SNAPSHOT" >/dev/null
# Restore chooses the prior snapshot before saving current state and retains inherited locks.
(
  restore_state_backup "$SNAPSHOT" >/dev/null
  TARGET="$(backup_state)"
  printf 'current-config\n' >"$CONFIG_FILE"
  set_setting mode current
  printf 'current-cert\n' >"$CERT_DIR/current.crt"
  cp "$CONFIG_FILE" "$TEST_ROOT/restore-current.before"
  mihomo_validate() { return 80; }
  no 'restore propagates candidate validation failure' restore_stack
  ok 'failed restore recovers exact operation-before config' same "$CONFIG_FILE" "$TEST_ROOT/restore-current.before"
  ok 'failed restore recovers operation-before settings' test "$(get_setting mode)" = current
  ok 'failed restore recovers operation-before certs' test -f "$CERT_DIR/current.crt"
  ok 'failed restore releases owned lock' test "$LOCK_HELD" = false
  latest_state_backup() { printf '%s' "$TARGET"; }
  mihomo_validate() { :; }
  acquire_lock
  ok 'valid restore under inherited lock succeeds' restore_stack
  ok 'restore publishes exact target config' same "$CONFIG_FILE" "$TARGET/config.yaml"
  ok 'restore publishes exact target settings' same "$SETTING_FILE" "$TARGET/settings.json"
  ok 'restore removes certificates outside target' test ! -e "$CERT_DIR/current.crt"
  ok 'restore retains caller lock' test "$LOCK_OWNER_PID" = "$BASHPID"
  ok 'restore commits marker' test -z "$_AUTO_ROLLBACK_DIR"
  render_config() { printf 'partial-restart\n' >"$CONFIG_FILE"; return 81; }
  no 'restart propagates render failure' restart_stack
  ok 'failed restart restores exact config' same "$CONFIG_FILE" "$TARGET/config.yaml"
  ok 'failed restart retains caller lock' test "$LOCK_OWNER_PID" = "$BASHPID"
  release_lock
)
# Recovery must repair broken/missing live JSON without accepting it as a valid backup.
for damage in corrupt-nodes missing-nodes corrupt-settings missing-settings missing-both; do
  (
    restore_state_backup "$SNAPSHOT" >/dev/null
    latest_state_backup() { printf '%s' "$SNAPSHOT"; }
    mihomo_validate() { :; }
    stop_all_argo_nodes() { printf 'argo-stop\n' >>"$TEST_ROOT/recovery-order"; }
    stop_service() { printf 'service-stop\n' >>"$TEST_ROOT/recovery-order"; }
    start_service() { printf 'target-start\n' >>"$TEST_ROOT/recovery-order"; }
    : >"$TEST_ROOT/recovery-order"
    case "$damage" in
      corrupt-nodes) printf 'broken-nodes\000\n' >"$NODES_FILE" ;;
      missing-nodes) rm "$NODES_FILE" ;;
      corrupt-settings) printf 'broken-settings\n' >"$SETTING_FILE" ;;
      missing-settings) rm "$SETTING_FILE" ;;
      missing-both) rm "$NODES_FILE" "$SETTING_FILE" ;;
    esac
    ok "$damage restore succeeds" restore_stack
    ok "$damage restores target nodes bytes" same "$NODES_FILE" "$SNAPSHOT/nodes.json"
    ok "$damage restores target settings bytes" same "$SETTING_FILE" "$SNAPSHOT/settings.json"
    ok "$damage stops tunnels before service" test "$(head -n 2 "$TEST_ROOT/recovery-order")" = $'argo-stop\nservice-stop'
    ok "$damage starts only restored target" test "$(grep -c target-start "$TEST_ROOT/recovery-order")" = 1
    ok "$damage clears marker and releases owned lock" test "$LOCK_HELD:$_AUTO_ROLLBACK_DIR" = false:
  )
done
restore_state_backup "$SNAPSHOT" >/dev/null
(
  latest_state_backup() { printf '%s' "$SNAPSHOT"; }
  mihomo_validate() { :; }
  stop_all_argo_nodes() { printf 'argo-stop\n' >>"$TEST_ROOT/raw-services"; }
  stop_service() { printf 'service-stop\n' >>"$TEST_ROOT/raw-services"; }
  start_service() { printf 'target-start\n' >>"$TEST_ROOT/raw-services"; return 84; }
  printf 'broken-nodes\000exact\n' >"$NODES_FILE"
  printf 'broken-config\000exact\n' >"$CONFIG_FILE"
  cp "$NODES_FILE" "$TEST_ROOT/raw-nodes.before"
  cp "$CONFIG_FILE" "$TEST_ROOT/raw-config.before"
  rm "$SECRETS_FILE" "$SETTING_FILE"
  printf 'before-extra\n' >"$CERT_DIR/extra.crt"
  cp "$CERT_DIR/extra.crt" "$TEST_ROOT/raw-cert.before"
  : >"$TEST_ROOT/raw-services"
  no 'failed target start propagates from damaged current state' restore_stack
  ok 'raw rollback restores corrupt nodes including NUL' same "$NODES_FILE" "$TEST_ROOT/raw-nodes.before"
  ok 'raw rollback restores corrupt config including NUL' same "$CONFIG_FILE" "$TEST_ROOT/raw-config.before"
  ok 'raw rollback restores absent secrets' test ! -e "$SECRETS_FILE"
  ok 'raw rollback restores absent settings' test ! -e "$SETTING_FILE"
  ok 'raw rollback restores exact prior certificate bytes' same "$CERT_DIR/extra.crt" "$TEST_ROOT/raw-cert.before"
  ok 'raw rollback never starts invalid before state' test "$(grep -c target-start "$TEST_ROOT/raw-services")" = 1
  ok 'raw rollback releases owned lock' test "$LOCK_HELD" = false
  image="$(find "$BASE_DIR" -maxdepth 1 -type d -name '.quarantine.*' | head -n 1)"
  ok 'raw recovery evidence is retained after failed restore' test -n "$image"
  ok 'raw evidence is not a valid dated restore backup' test "$(latest_state_backup)" = "$SNAPSHOT"
)
restore_state_backup "$SNAPSHOT" >/dev/null
(
  latest_state_backup() { printf '%s' "$SNAPSHOT"; }
  mihomo_validate() { :; }
  stop_all_argo_nodes() { :; }
  start_service() { printf 'start\n' >>"$TEST_ROOT/raw-no-certs-start"; return 85; }
  rm "$NODES_FILE" "$SETTING_FILE"
  rm -rf "$CERT_DIR"
  : >"$TEST_ROOT/raw-no-certs-start"
  no 'failed restore from absent state propagates' restore_stack
  ok 'raw rollback preserves missing nodes' test ! -e "$NODES_FILE"
  ok 'raw rollback preserves missing settings' test ! -e "$SETTING_FILE"
  ok 'raw rollback does not recreate absent cert directory' test ! -e "$CERT_DIR"
  ok 'absent before state never starts' test "$(wc -l <"$TEST_ROOT/raw-no-certs-start")" = 1
)
restore_state_backup "$SNAPSHOT" >/dev/null
(
  # Normal startup rollback remains available only for a validated before image.
  latest_state_backup() { printf '%s' "$SNAPSHOT"; }
  mihomo_validate() { :; }
  stop_all_argo_nodes() { :; }
  count=0
  start_service() { count=$((count + 1)); [ "$count" -gt 1 ]; }
  printf 'valid-before\n' >"$CONFIG_FILE"
  no 'target start failure from valid state propagates' restore_stack
  ok 'validated old state is restarted once' test "$count" = 2
  ok 'validated old config restored exactly' test "$(<"$CONFIG_FILE")" = valid-before
)
restore_state_backup "$SNAPSHOT" >/dev/null
(
  acquire_lock
  _AUTO_ROLLBACK_DIR="$SNAPSHOT" _AUTO_ROLLBACK_OWNER="$BASHPID"
  old_owner="$BASHPID"
  cp "$CONFIG_FILE" "$TEST_ROOT/nested.before"
  cp "$NODES_FILE" "$TEST_ROOT/nested.nodes"
  cp "$SECRETS_FILE" "$TEST_ROOT/nested.secrets"
  cp "$SETTING_FILE" "$TEST_ROOT/nested.settings"
  auto_has_node_env() { : >"$TEST_ROOT/nested-auto-reached"; return 1; }
  no 'automatic append refuses active transaction before parsing input' auto_install ins
  no 'automatic replace refuses active transaction before parsing input' auto_install rep
  ok 'nested automatic calls stop before input preparation' test ! -e "$TEST_ROOT/nested-auto-reached"
  no 'restart refuses active same-owner transaction' restart_stack
  no 'restore refuses active same-owner transaction' restore_stack
  no 'node deletion refuses active same-owner transaction' delete_nodes_transaction keep
  ok 'nested calls preserve rollback directory' test "$_AUTO_ROLLBACK_DIR" = "$SNAPSHOT"
  ok 'nested calls preserve rollback owner' test "$_AUTO_ROLLBACK_OWNER" = "$old_owner"
  ok 'nested calls preserve caller lock' test "$LOCK_OWNER_PID" = "$old_owner"
  ok 'nested calls do not alter config' same "$CONFIG_FILE" "$TEST_ROOT/nested.before"
  ok 'nested calls do not alter nodes' same "$NODES_FILE" "$TEST_ROOT/nested.nodes"
  ok 'nested calls do not alter secrets' same "$SECRETS_FILE" "$TEST_ROOT/nested.secrets"
  ok 'nested calls do not alter settings' same "$SETTING_FILE" "$TEST_ROOT/nested.settings"
  _AUTO_ROLLBACK_DIR='' _AUTO_ROLLBACK_OWNER=''
  release_lock
)
(
  image="$(quarantine_state)"
  ok 'raw image validates with exact presence map' validate_raw_state "$image"
  no 'raw image cannot be used as normal valid snapshot' validate_state_backup "$image"
  printf 'tamper\n' >>"$image/PRESENCE"
  no 'raw presence corruption rejected' restore_raw_state "$image"
  rm -rf "$image"
  cp() { return 86; }
  no 'raw quarantine propagates copy failure before mutation' quarantine_state
)
# Normal and raw images share the same checked publisher and reversal path.
for image_kind in valid raw; do
  (
    restore_state_backup "$SNAPSHOT" >/dev/null
    image="$SNAPSHOT"
    if [ "$image_kind" = raw ]; then image="$(quarantine_state)"; fi
    printf 'before-nodes\000exact\n' >"$NODES_FILE"
    printf 'before-secrets\000exact\n' >"$SECRETS_FILE"
    printf 'before-config\n' >"$CONFIG_FILE"
    printf 'before-settings\n' >"$SETTING_FILE"
    printf 'before-cert\n' >"$CERT_DIR/publish-before.crt"
    cp "$NODES_FILE" "$TEST_ROOT/publish.nodes"
    cp "$SECRETS_FILE" "$TEST_ROOT/publish.secrets"
    cp "$CONFIG_FILE" "$TEST_ROOT/publish.config"
    cp "$SETTING_FILE" "$TEST_ROOT/publish.settings"
    cp "$CERT_DIR/publish-before.crt" "$TEST_ROOT/publish.cert"
    fault_seen=0
    mv() {
      local source="${*: -2:1}" destination="${*: -1}"
      if [[ "$source" == */.restore.*/config.yaml ]] && [ "$destination" = "$CONFIG_FILE" ]; then
        fault_seen=1; return 87
      fi
      command mv "$@"
    }
    if [ "$image_kind" = raw ]; then
      no 'raw image propagates third-file publication failure' restore_raw_state "$image"
    else
      no 'valid image propagates third-file publication failure' restore_state_backup "$image"
    fi
    ok "$image_kind reached third-file publication fault" test "$fault_seen" = 1
    ok "$image_kind reverts earlier nodes publication exactly" same "$NODES_FILE" "$TEST_ROOT/publish.nodes"
    ok "$image_kind reverts earlier secrets publication exactly" same "$SECRETS_FILE" "$TEST_ROOT/publish.secrets"
    ok "$image_kind preserves old config after publication failure" same "$CONFIG_FILE" "$TEST_ROOT/publish.config"
    ok "$image_kind preserves old settings after publication failure" same "$SETTING_FILE" "$TEST_ROOT/publish.settings"
    ok "$image_kind restores original certificate tree" same "$CERT_DIR/publish-before.crt" "$TEST_ROOT/publish.cert"
    if [ "$image_kind" = raw ]; then rm -rf -- "$image"; fi
  )
done
restore_state_backup "$SNAPSHOT" >/dev/null
(
  printf 'certificate-before\n' >"$CERT_DIR/revert-before.crt"
  cp "$CERT_DIR/revert-before.crt" "$TEST_ROOT/revert.cert"
  cp "$CONFIG_FILE" "$TEST_ROOT/revert.config"
  retained_stage=''
  mv() {
    local source="${*: -2:1}" destination="${*: -1}"
    if [ "$destination" = "$CERT_DIR" ]; then
      case "$source" in
        */.restore.*/new-certs) retained_stage="${source%/new-certs}"; return 88 ;;
        */.restore.*/previous/certs) return 89 ;;
      esac
    fi
    command mv "$@"
  }
  no 'certificate publish and reversal failures propagate' restore_state_backup "$SNAPSHOT"
  ok 'failed certificate reversal records retained stage' test -n "$retained_stage"
  ok 'failed reversal retains exact previous certificate bytes' same "$retained_stage/previous/certs/revert-before.crt" "$TEST_ROOT/revert.cert"
  ok 'failed reversal retains previous state files' same "$retained_stage/previous/config.yaml" "$TEST_ROOT/revert.config"
  ok 'certificate fault occurs before publishing live config' same "$CONFIG_FILE" "$TEST_ROOT/revert.config"
)
restore_state_backup "$SNAPSHOT" >/dev/null
# A failed tunnel stop must prevent both service stop and target publication.
(
  latest_state_backup() { printf '%s' "$SNAPSHOT"; }
  mihomo_validate() { :; }
  stop_all_argo_nodes() { return 90; }
  stop_service() { : >"$TEST_ROOT/unexpected-service-stop"; }
  printf 'before-stopping\n' >"$CONFIG_FILE"
  cp "$CONFIG_FILE" "$TEST_ROOT/stop.before"
  no 'tunnel stop error aborts restore before publication' restore_stack
  ok 'tunnel stop error leaves live state unchanged' same "$CONFIG_FILE" "$TEST_ROOT/stop.before"
  ok 'tunnel stop error never stops service or publishes target' test ! -e "$TEST_ROOT/unexpected-service-stop"
  ok 'tunnel stop error releases owned lock' test "$LOCK_HELD" = false
)
restore_state_backup "$SNAPSHOT" >/dev/null
# Clock rollback or imported future mtimes must never prune the just-returned image.
(
  for n in {1..10}; do
    mkdir "$BASE_DIR/backups/20990101-$n"
    touch -d '2099-01-01 UTC' "$BASE_DIR/backups/20990101-$n"
  done
  _AUTO_ROLLBACK_DIR="$SNAPSHOT"
  fresh="$(backup_state)"
  ok 'future mtime pruning preserves returned snapshot' test -d "$fresh"
  ok 'future mtime pruning preserves current transaction snapshot' test -d "$SNAPSHOT"
  ok 'returned snapshot remains valid after pruning' validate_state_backup "$fresh"
)
# Delete-all removes managed orphan names before commit and rolls back cleanup errors.
(
  stop_argo_node() { :; }
  render_config() { printf 'deleted-config\n' >"$CONFIG_FILE"; }
  reload_service() { :; }
  printf 'orphan-cert\n' >"$CERT_DIR/bk.crt"
  printf 'orphan-key\n' >"$CERT_DIR/bk.key"
  cp "$NODES_FILE" "$TEST_ROOT/cleanup.nodes"
  cp "$SECRETS_FILE" "$TEST_ROOT/cleanup.secrets"
  (
    cleanup_orphan_certs() { rm -f -- "$CERT_DIR/bk.key"; return 91; }
    no 'delete-all propagates orphan cleanup failure' delete_all_nodes
    ok 'cleanup failure restores node bytes' same "$NODES_FILE" "$TEST_ROOT/cleanup.nodes"
    ok 'cleanup failure restores secret bytes' same "$SECRETS_FILE" "$TEST_ROOT/cleanup.secrets"
    ok 'cleanup failure restores partially removed orphan key' test "$(<"$CERT_DIR/bk.key")" = orphan-key
    ok 'cleanup failure releases owned lock' test "$LOCK_HELD" = false
  )
  ok 'delete-all commits checked real orphan cleanup' delete_all_nodes
  ok 'delete-all removes orphan certificate' test ! -e "$CERT_DIR/bk.crt"
  ok 'delete-all removes orphan key' test ! -e "$CERT_DIR/bk.key"
  ok 'delete-all leaves no node records' test "$(jq length "$NODES_FILE")" = 0
  ok 'delete-all leaves no secret records' test "$(jq length "$SECRETS_FILE")" = 0
  printf 'empty-orphan\n' >"$CERT_DIR/empty.custom.crt"
  ok 'delete-all cleans orphans even with an empty table' delete_all_nodes
  ok 'empty-table delete-all removes managed custom orphan' test ! -e "$CERT_DIR/empty.custom.crt"
)
restore_state_backup "$SNAPSHOT" >/dev/null
# Real /proc identity and stop path; the native fixture only pauses, with no sockets.
(
  source "$ROOT_DIR/lib/argo.sh"
  RUNTIME_DIR="$TEST_ROOT/real-argo-runtime"
  LOG_DIR="$TEST_ROOT/real-argo-log"
  CLOUDFLARED_BIN="$TEST_ROOT/native-cloudflared"
  mkdir -p "$RUNTIME_DIR" "$LOG_DIR"
  command -v cc >/dev/null || { printf 'cc required for native Argo fixture\n' >&2; exit 1; }
  cat >"$TEST_ROOT/native-cloudflared.c" <<'C'
#include <unistd.h>
int main(void) { for (;;) pause(); }
C
  cc -Wall -Wextra -Werror -O2 -o "$CLOUDFLARED_BIN" "$TEST_ROOT/native-cloudflared.c"
  own_pid='' own_birth='' foreign_pid='' foreign_birth=''
  cleanup_native_argo() {
    if [ -n "$own_pid" ]; then managed_pid_stop "$own_pid" "$own_birth" || true; wait "$own_pid" 2>/dev/null || true; fi
    if [ -n "$foreign_pid" ]; then managed_pid_stop "$foreign_pid" "$foreign_birth" || true; wait "$foreign_pid" 2>/dev/null || true; fi
  }
  trap cleanup_native_argo EXIT
  managed_spawn "$RUNTIME_DIR/owned.pid" "$LOG_DIR/owned.cloudflared.log" "$CLOUDFLARED_BIN" tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:30901
  read -r own_pid own_birth <"$RUNTIME_DIR/owned.pid"
  ok 'real Argo fixture has exact executable argv log and birth' managed_wait_exec "$RUNTIME_DIR/owned.pid" argo_proc_matches "$LOG_DIR/owned.cloudflared.log" '' ''
  managed_spawn "$RUNTIME_DIR/foreign.pid" "$LOG_DIR/foreign.cloudflared.log" "$CLOUDFLARED_BIN" other-role
  read -r foreign_pid foreign_birth <"$RUNTIME_DIR/foreign.pid"
  # Wait for the harmless fixture to exec without requiring Argo role validation.
  for _ in {1..20}; do
    if managed_proc_exe "$foreign_pid" "$CLOUDFLARED_BIN"; then break; fi
    sleep 0.05
  done
  printf '{broken\000nodes\n' >"$NODES_FILE"
  cp "$NODES_FILE" "$TEST_ROOT/argo.badnodes"
  (
    managed_pid_stop() { return 92; }
    no 'real scanner propagates owned process stop failure' stop_all_argo_nodes
    ok 'failed process stop retains verified pidfile' test -f "$RUNTIME_DIR/owned.pid"
  )
  ok 'real scanner stops owned Argo despite corrupt node JSON' stop_all_argo_nodes
  no 'owned native Argo process is no longer live' managed_proc_birth "$own_pid"
  ok 'successful owned stop removes its pidfile' test ! -e "$RUNTIME_DIR/owned.pid"
  ok 'scanner preserves foreign argv even with same executable' test "$(managed_proc_birth "$foreign_pid")" = "$foreign_birth"
  ok 'scanner preserves foreign pidfile' test -f "$RUNTIME_DIR/foreign.pid"
  ok 'scanner never reads or changes damaged node bytes' same "$NODES_FILE" "$TEST_ROOT/argo.badnodes"
)
restore_state_backup "$SNAPSHOT" >/dev/null
(
  LOG_ROTATE_SIZE_MB=1 LOG_ROTATE_BACKUPS=3
  log="$TEST_ROOT/watchdog-small.log"
  ok 'missing log is a successful no-op for watchdog' rotate_log_file "$log"
  printf 'live-log\n' >"$log"
  before_inode="$(stat -c %i "$log")"
  ok 'small live log is a successful no-op' rotate_log_file "$log"
  ok 'no-op leaves the live log inode intact' test "$(stat -c %i "$log")" = "$before_inode"
  ok 'no-op preserves live log bytes' test "$(<"$log")" = live-log
  ln -s "$log" "$TEST_ROOT/watchdog-link.log"
  no 'log symlink still fails instead of no-op' rotate_log_file "$TEST_ROOT/watchdog-link.log"
  mkdir "$TEST_ROOT/watchdog-directory.log"
  no 'nonregular log still fails instead of no-op' rotate_log_file "$TEST_ROOT/watchdog-directory.log"
)
# Existing core readiness is inside the node-state transaction.
(
  MIHOMO_BIN=/bin/true
  auto_has_node_env() { return 0; }
  auto_collect_specs() { printf 'socks5 30902\n'; }
  export vl_sni=example.com
  cp "$NODES_FILE" "$TEST_ROOT/ready.nodes"
  cp "$SECRETS_FILE" "$TEST_ROOT/ready.secrets"
  cp "$SETTING_FILE" "$TEST_ROOT/ready.settings"
  cp "$CONFIG_FILE" "$TEST_ROOT/ready.config"
  ensure_singbox_ready() {
    [ -n "${_AUTO_ROLLBACK_DIR:-}" ] || return 98
    printf '{}\n' >"$NODES_FILE"
    printf '{}\n' >"$SECRETS_FILE"
    printf '{"partial":true}\n' >"$SETTING_FILE"
    printf 'partial-ready\n' >"$CONFIG_FILE"
    printf 'partial-cert\n' >"$CERT_DIR/keep.crt"
    return 97
  }
  no 'existing-core readiness failure aborts node operation' auto_install ins
  ok 'existing readiness restores node bytes' same "$NODES_FILE" "$TEST_ROOT/ready.nodes"
  ok 'existing readiness restores secret bytes' same "$SECRETS_FILE" "$TEST_ROOT/ready.secrets"
  ok 'existing readiness restores settings bytes' same "$SETTING_FILE" "$TEST_ROOT/ready.settings"
  ok 'existing readiness restores config bytes' same "$CONFIG_FILE" "$TEST_ROOT/ready.config"
  ok 'existing readiness restores certificate bytes' test "$(<"$CERT_DIR/keep.crt")" = old-cert
  ok 'existing readiness clears transaction marker' test -z "${_AUTO_ROLLBACK_DIR:-}"
  ok 'existing readiness releases owned lock' test "$LOCK_HELD" = false
)
restore_state_backup "$SNAPSHOT" >/dev/null
# A successful fresh core is committed before a later first-node failure.
(
  MIHOMO_BIN="$TEST_ROOT/staged-core"
  printf '{}\n' >"$NODES_FILE"
  printf '{}\n' >"$SECRETS_FILE"
  printf '{}\n' >"$SETTING_FILE"
  auto_has_node_env() { return 0; }
  auto_collect_specs() { printf 'socks5 30902\n'; }
  auto_try_port() { return 0; }
  export vl_sni=example.com
  ensure_singbox_ready() {
    [ -z "${_AUTO_ROLLBACK_DIR:-}" ] || return 98
    printf '#!/bin/sh\nexit 0\n' >"$MIHOMO_BIN"
    chmod 700 "$MIHOMO_BIN"
    printf 'listeners: []\n' >"$CONFIG_FILE"
    printf 'prepared\n' >"$TEST_ROOT/core-prerequisite"
  }
  auto_add_socks5() {
    json_set_record "$NODES_FILE" candidate '{"protocol":"socks5","port":30902}'
    json_set_record "$SECRETS_FILE" candidate '{"password":"candidate"}'
    printf 'partial-node\n' >"$CONFIG_FILE"
    return 96
  }
  no 'first-node failure propagates after fresh core preparation' auto_install ins
  ok 'fresh-core committed binary remains' test -x "$MIHOMO_BIN"
  ok 'fresh-core prerequisite record remains' test -f "$TEST_ROOT/core-prerequisite"
  ok 'first-node rollback retains valid core-ready config' test "$(<"$CONFIG_FILE")" = 'listeners: []'
  ok 'first-node rollback removes candidate nodes' test "$(jq length "$NODES_FILE")" = 0
  ok 'first-node rollback removes candidate secrets' test "$(jq length "$SECRETS_FILE")" = 0
  ok 'first-node rollback clears transaction marker' test -z "${_AUTO_ROLLBACK_DIR:-}"
  ok 'first-node rollback releases owned lock' test "$LOCK_HELD" = false
)
restore_state_backup "$SNAPSHOT" >/dev/null
PASS="$(grep -c '^+' "$RESULTS" || true)"
FAIL="$(grep -c '^-' "$RESULTS" || true)"
printf 'audit-storage: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
