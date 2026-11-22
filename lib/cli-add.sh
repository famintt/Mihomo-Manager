#!/usr/bin/env bash
set -eEuo pipefail

cli_add_usage() {
  cat <<'EOF'
用法: mm add --protocol PROTOCOL [选项]

协议:
  reality       VLESS-Reality (TCP)
  xudp          VLESS+XUDP+Reality (TCP)
  anytls        AnyTLS (TCP)
  tuic          TUIC v5 (UDP)
  hysteria2     Hysteria2 (UDP)
  socks5        SOCKS5 (TCP)
  argo          VLESS + Argo 临时隧道
  ws            VLESS + WS-TLS

选项:
  --port PORT          监听端口；省略随机选择
  --name NAME          节点名称
  --sni DOMAIN         SNI；Reality 可用 auto 自动检测
  --uuid UUID          指定 UUID
  --password VALUE     指定密码
  --socks5-username U  SOCKS5 用户名
  --socks5-password P  SOCKS5 密码
  --server-ip IP       分享链接使用的服务器 IP
  --direct-host HOST   直连协议使用的域名
  --argo-cdn-host HOST Argo 优选域名
  --argo-cdn-port PORT Argo 优选端口
EOF
}

random_free_port() {
  local p
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    p=$(( (RANDOM * 32768 + RANDOM) % 50000 + 10000 ))
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q "[:.]${p} "; then
      continue
    fi
    printf '%s' "${p}"
    return 0
  done
  printf '%s' "443"
}

cli_require_value() {
  local option="$1"
  if [ "$#" -lt 2 ] || [ -z "$2" ]; then
    print_err "$option requires a non-empty value"
    return 2
  fi
  case "$2" in
    -*)
      print_err "$option requires a value, not another option"
      return 2
      ;;
  esac
}

cli_normalize_port() {
  local value=${1:-}
  [[ "$value" =~ ^[0-9]+$ ]] && [ ${#value} -le 5 ] || return 1
  value=$((10#$value))
  ((value >= 1 && value <= 65535)) || return 1
  printf '%s' "$value"
}

sni_candidates() {
  cat <<'EOF'
dl-cdn.alpinelinux.org
deb.debian.org
crates.io
pypi.org
rubygems.org
addons.mozilla.org
formulae.brew.sh
static.rust-lang.org
cpan.org
EOF
}

detect_sni_best() {
  local host t best="" best_t="999"
  command -v curl >/dev/null 2>&1 || return 1
  while IFS= read -r host; do
    [ -n "${host}" ] || continue
    t="$(curl -fsS --http2 --tlsv1.3 -o /dev/null --connect-timeout 3 --max-time 6 \
      -w '%{time_appconnect}' "https://${host}" 2>/dev/null || true)"
    [[ "${t}" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
    if awk -v a="${t}" -v b="${best_t}" 'BEGIN { exit !(a < b) }'; then
      best="${host}"
      best_t="${t}"
    fi
  done < <(sni_candidates)
  [ -n "${best}" ] || return 1
  printf '%s' "${best}"
}

cli_sni() {
  local best
  print_info "正在检测 Reality SNI 候选（TLS 1.3 + HTTP/2）..."
  if best="$(detect_sni_best)"; then
    print_ok "推荐 SNI：${best}"
  else
    print_warn "自动检测失败，建议使用 pypi.org"
    return 1
  fi
}

cli_add() {
  require_root
  local protocol="" port="" port_supplied=false name="" sni="" uuid="" password="" s5user="" s5pass="" server_ip="" direct_host="" argo_host="" argo_port=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --protocol|--port|--name|--sni|--uuid|--password|--socks5-username|--socks5-password|--server-ip|--direct-host|--argo-cdn-host|--argo-cdn-port)
        cli_require_value "$@" || return $?
        case "$1" in
          --protocol) protocol="$2" ;; --port) port="$2"; port_supplied=true ;; --name) name="$2" ;; --sni) sni="$2" ;; --uuid) uuid="$2" ;; --password) password="$2" ;; --socks5-username) s5user="$2" ;; --socks5-password) s5pass="$2" ;; --server-ip) server_ip="$2" ;; --direct-host) direct_host="$2" ;; --argo-cdn-host) argo_host="$2" ;; --argo-cdn-port) argo_port="$2" ;;
        esac
        shift 2 ;;
      -h|--help) cli_add_usage; return 0 ;;
      *) print_err "未知参数：$1"; cli_add_usage; return 2 ;;
    esac
  done
  [ -n "$protocol" ] || { print_err "缺少 --protocol"; cli_add_usage; return 2; }
  protocol=$(printf '%s' "$protocol" | tr '[:upper:]' '[:lower:]')
  case "$protocol" in reality|vless-reality|xudp|xudp-reality|vless-xudp|anytls|tuic|tuic-v5|hysteria2|hy2|socks5|argo|vless-argo|ws|vless-ws|vless-ws-tls) ;; *) print_err "不支持的协议：$protocol"; return 2 ;; esac
  if [ "$port_supplied" = true ]; then port=$(cli_normalize_port "$port") || { print_err "端口无效"; return 2; }
  else port=$(random_free_port); port=$(cli_normalize_port "$port") || { print_err "随机端口无效"; return 2; }; fi
  if [ -n "$argo_port" ]; then argo_port=$(cli_normalize_port "$argo_port") || { print_err "Argo 端口无效"; return 2; }; fi
  [ -n "$name" ] || name="$protocol-$port"
  if [ "$sni" = auto ]; then sni=$(detect_sni_best || printf pypi.org); fi
  export name
  [ -n "$uuid" ] && export uuid
  [ -n "$password" ] && export passwd="$password"
  [ -n "$server_ip" ] && export server_ip
  [ -n "$direct_host" ] && export direct_host
  case "$protocol" in
    reality|vless-reality) export vlrt="$port"; [ -n "$sni" ] && export vl_sni="$sni" ;;
    xudp|xudp-reality|vless-xudp) export vxpt="$port"; [ -n "$sni" ] && export vx_sni="$sni" ;;
    anytls) export anypt="$port"; [ -n "$sni" ] && export any_sni="$sni" ;;
    tuic|tuic-v5) export tupt="$port"; [ -n "$sni" ] && export tu_sni="$sni" ;;
    hysteria2|hy2) export hypt="$port"; [ -n "$sni" ] && export hy_sni="$sni" ;;
    socks5) export socks5pt="$port"; [ -n "$s5user" ] && export socks5_username="$s5user"; [ -n "$s5pass" ] && export socks5_password="$s5pass" ;;
    argo|vless-argo) export argo=vlpt argo_pt="$port"; [ -n "$argo_host" ] && export argo_cdn_host="$argo_host"; [ -n "$argo_port" ] && export argo_cdn_port="$argo_port" ;;
    ws|vless-ws|vless-ws-tls) export wspt="$port" ws_mode=cdn; [ -n "$sni" ] && export ws_cdn_sni="$sni" ;;
  esac
  auto_install ins
}

cli_status() {
  local n=0
  init_storage
  n="$(iter_node_tags | wc -l | tr -d ' ')"
  printf '版本: %s\n' "${SCRIPT_VERSION}"
  printf '服务: %s\n' "$(service_state)"
  printf '节点: %s\n' "${n}"
  printf '配置: %s\n' "${CONFIG_FILE}"
}

cli_doctor() {
  local fail=0
  init_storage
  printf '== %s doctor ==\n' "$SCRIPT_VERSION"
  if [ -x "$MIHOMO_BIN" ]; then print_ok "mihomo 内核可执行"; else print_err "mihomo 内核不可执行：$MIHOMO_BIN"; fail=1; fi
  if [ -s "$CONFIG_FILE" ]; then print_ok "配置文件存在"; else print_err "配置文件缺失：$CONFIG_FILE"; fail=1; fi
  if [ -x "$MIHOMO_BIN" ] && [ -s "$CONFIG_FILE" ]; then
    if mihomo_validate "$CONFIG_FILE" >/dev/null 2>&1; then print_ok "配置校验通过"; else print_err "配置校验失败"; fail=1; fi
  fi
  case "$(service_state)" in *运行中*) print_ok "服务运行中" ;; *) print_err "服务未运行"; fail=1 ;; esac
  if [ "$fail" -eq 0 ]; then print_ok "doctor 检查通过"; else print_warn "doctor 检查发现问题"; fi
  return "$fail"
}

cli_fw_usage() {
  cat <<'EOF'
用法: mm fw list
      mm fw active
      mm fw open --port PORT [--proto tcp|udp]
      mm fw close --port PORT [--proto tcp|udp]
      mm fw protect（内部：应用 SOCKS5 白名单）
EOF
}

cli_fw_backend() {
  local status
  if command -v ufw >/dev/null 2>&1; then status="$(ufw status 2>/dev/null || true)"; status=$(printf '%s' "$status" | tr '[:upper:]' '[:lower:]'); case "$status" in *"status: active"*) printf ufw; return 0 ;; esac; fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then printf firewalld; return 0; fi
  if command -v iptables >/dev/null 2>&1 && command -v ip6tables >/dev/null 2>&1 && iptables -S INPUT >/dev/null 2>&1 && ip6tables -S INPUT >/dev/null 2>&1; then printf iptables; return 0; fi
  return 1
}

cli_fw_whitelist_enabled() {
  local enabled
  enabled="$(manager_env_or_setting socks5_wl_flag '')"
  case "$enabled" in true|TRUE|1|yes|YES|on|ON) return 0 ;; *) return 1 ;; esac
}

cli_fw() {
  require_root
  [ "$#" -gt 0 ] || set -- list
  local cmd="$1" port="" proto=tcp backend
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port|--proto) cli_require_value "$@" || return $?; if [ "$1" = --port ]; then port="$2"; else proto="$2"; fi; shift 2 ;;
      -h|--help) cli_fw_usage; return 0 ;;
      *) print_err "未知参数：$1"; cli_fw_usage; return 2 ;;
    esac
  done
  case "$cmd" in
    protect) declare -F socks5_whitelist_apply >/dev/null || { print_err "SOCKS5 白名单保护模块不可用"; return 1; }; socks5_whitelist_apply ;;
    active) backend=$(cli_fw_backend) || { print_warn "未检测到活动的防火墙后端"; return 1; }; printf '活动防火墙后端：%s\n' "$backend" ;;
    list) backend=$(cli_fw_backend) || { print_warn "未检测到活动的防火墙后端"; return 0; }; case "$backend" in ufw) ufw status verbose ;; firewalld) firewall-cmd --list-all ;; iptables) iptables -S INPUT; ip6tables -S INPUT ;; esac ;;
    open|close)
      port=$(cli_normalize_port "$port") || { print_err "缺少有效 --port（1-65535）"; return 2; }
      case "$proto" in tcp|udp) ;; *) print_err "--proto 仅支持 tcp/udp"; return 2 ;; esac
      backend=$(cli_fw_backend) || { print_err "未检测到活动的防火墙后端，拒绝修改规则"; return 1; }
      if [ "$cmd" = open ]; then
        if declare -F socks5_whitelist_guard >/dev/null; then socks5_whitelist_guard "$port" || { print_err "端口 $port 受 SOCKS5 白名单保护，拒绝通用放行"; return 2; }
        elif cli_fw_whitelist_enabled; then print_err "SOCKS5 白名单状态未知，拒绝放行"; return 2; fi
      fi
      case "$backend" in
        ufw) if [ "$cmd" = open ]; then ufw allow "$port/$proto" || return 1; else ufw delete allow "$port/$proto" || return 1; fi ;;
        firewalld)
          if [ "$cmd" = open ]; then
            firewall-cmd --add-port="$port/$proto" >/dev/null || return 1
            if ! firewall-cmd --permanent --add-port="$port/$proto" >/dev/null; then firewall-cmd --remove-port="$port/$proto" >/dev/null 2>&1 || true; return 1; fi
          else
            firewall-cmd --remove-port="$port/$proto" >/dev/null || return 1
            firewall-cmd --permanent --remove-port="$port/$proto" >/dev/null || { firewall-cmd --add-port="$port/$proto" >/dev/null 2>&1 || true; return 1; }
          fi
          ;;
        iptables)
          if [ "$cmd" = open ]; then
            local added_v4=false
            if ! iptables -C INPUT -p "$proto" --dport "$port" -m comment --comment mm_fw -j ACCEPT >/dev/null 2>&1; then iptables -I INPUT -p "$proto" --dport "$port" -m comment --comment mm_fw -j ACCEPT || return 1; added_v4=true; fi
            if ! ip6tables -C INPUT -p "$proto" --dport "$port" -m comment --comment mm_fw -j ACCEPT >/dev/null 2>&1 && ! ip6tables -I INPUT -p "$proto" --dport "$port" -m comment --comment mm_fw -j ACCEPT; then
              if [ "$added_v4" = true ]; then iptables -D INPUT -p "$proto" --dport "$port" -m comment --comment mm_fw -j ACCEPT >/dev/null 2>&1 || true; fi
              print_err "IPv6 规则失败，已回滚本次 IPv4 放行"; return 1
            fi
          else
            iptables -D INPUT -p "$proto" --dport "$port" -m comment --comment mm_fw -j ACCEPT >/dev/null 2>&1 || return 1
            ip6tables -D INPUT -p "$proto" --dport "$port" -m comment --comment mm_fw -j ACCEPT >/dev/null 2>&1 || return 1
          fi
          print_warn "裸 iptables/ip6tables 规则不会自动持久化，请自行保存" ;;
      esac
      print_ok "防火墙$cmd：$port/$proto（$backend）" ;;
    *) print_err "未知 fw 子命令：$cmd"; cli_fw_usage; return 2 ;;
  esac
}
