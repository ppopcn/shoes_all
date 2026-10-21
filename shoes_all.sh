#!/usr/bin/env bash
# =============================================================================
# shoes_all.sh — shoes 全家桶一键部署脚本 (参考 singbox_all.sh 架构)
# 核心: https://github.com/cfal/shoes (Rust 多协议代理服务端)
#
# 用法:
#   sudo bash shoes_all.sh install    # 安装(默认全部协议)
#   sudo bash shoes_all.sh plan       # 只打印端口计划
#   sudo bash shoes_all.sh status     # 服务状态
#   sudo bash shoes_all.sh info       # 重新打印凭据与分享链接
#   sudo bash shoes_all.sh logs [N]   # 日志
#   sudo bash shoes_all.sh update     # 升级二进制并重启 (配置不变)
#   sudo bash shoes_all.sh uninstall  # 卸载 (KEEP_CONFIG=1 保留配置)
#
# 环境变量:
#   PROTOCOLS=hy2,tuic,ss,vless,vmess,trojan,reality   选择启用的协议(逗号分隔)
#   HY2_PORT=443 TUIC_PORT=8443 SS_PORT=8388 VLESS_PORT=8989 VMESS_PORT=8990 TROJAN_PORT=8444 REALITY_PORT=8899
#   REALITY_DEST=www.microsoft.com:443   Reality 握手目标(借用其 TLS 指纹)
#   DOMAIN=xxx.com                  SNI/证书域名(默认随机伪装域名)
#   SHOES_TAG=v0.3.3                锁定版本
#   MIRROR=https://ghfast.top/      GitHub 下载镜像前缀
#   CERT_FILE/KEY_FILE=...          使用已有证书
#   SERVER_ADDR=1.2.3.4             手动指定对外 IP
# =============================================================================
set -euo pipefail

SHOES_TAG_DEFAULT="v0.3.3"
SERVICE_NAME="shoes-all"
BIN_PATH="/usr/local/bin/shoes"
CONF_DIR="/etc/shoes"
CONF_FILE="${CONF_DIR}/all.yaml"
CREDS_FILE="${CONF_DIR}/creds.env"
CERT_FILE_DEFAULT="${CONF_DIR}/cert.pem"
KEY_FILE_DEFAULT="${CONF_DIR}/key.pem"
LOG_LEVEL="${LOG_LEVEL:-info}"

# ---- 默认端口 / 协议 ----
PROTOCOLS="${PROTOCOLS:-hy2,tuic,ss,vless,vmess,trojan,reality}"
HY2_PORT="${HY2_PORT:-443}"
TUIC_PORT="${TUIC_PORT:-8443}"
SS_PORT="${SS_PORT:-8388}"
VLESS_PORT="${VLESS_PORT:-8989}"
VMESS_PORT="${VMESS_PORT:-8990}"
TROJAN_PORT="${TROJAN_PORT:-8444}"
REALITY_PORT="${REALITY_PORT:-8899}"
REALITY_DEST="${REALITY_DEST:-www.microsoft.com:443}"   # Reality 握手目标(需为支持 TLS1.3+H2 的真实站点)

# ---- 平台探测 ----
OS_FAMILY=""; INIT_SYS=""; SERVICE_FILE=""
detect_platform() {
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    INIT_SYS="systemd"; SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
  elif command -v rc-service >/dev/null 2>&1; then
    INIT_SYS="openrc"; SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"
  else
    echo "错误: 未找到 systemd 或 OpenRC" >&2; exit 1
  fi
  if command -v apt-get >/dev/null 2>&1; then OS_FAMILY="debian"
  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then OS_FAMILY="rhel"
  elif command -v apk >/dev/null 2>&1; then OS_FAMILY="alpine"
  else OS_FAMILY="unknown"; fi
}

log()  { echo "[shoes-all] $*"; }
warn() { echo "[shoes-all][警告] $*" >&2; }
die()  { echo "[shoes-all][错误] $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

check_deps() {
  local pkgs=""
  have curl || pkgs="$pkgs curl"
  have tar  || pkgs="$pkgs tar"
  have openssl || pkgs="$pkgs openssl"
  case "$OS_FAMILY" in
    debian) [ -n "$pkgs" ] && apt-get update -y >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null ;;
    rhel)   [ -n "$pkgs" ] && { have dnf && dnf install -y $pkgs >/dev/null || yum install -y $pkgs >/dev/null; } ;;
    alpine) [ -n "$pkgs" ] && apk add --no-cache $pkgs >/dev/null ;;
  esac
  have curl || die "缺少 curl，请手动安装"
  have tar  || die "缺少 tar"
  have openssl || die "缺少 openssl"
}

# ---- 随机工具 ----
rand_uuid() { have uuidgen && uuidgen || cat /proc/sys/kernel/random/uuid; }
rand_pass() { openssl rand -base64 24 | tr -d '/+=' | head -c 24; }
rand_hex()  { openssl rand -hex "$1"; }

# ---- 凭据生成 / 复用 ----
load_or_init_creds() {
  mkdir -p "$CONF_DIR"
  local need=0
  [ -f "$CREDS_FILE" ] || need=1
  if [ "$need" = "0" ]; then . "$CREDS_FILE"; fi
  local out=""
  out="DOMAIN='${DOMAIN:-$(pick_sni)}'
HY2_PASSWORD='${HY2_PASSWORD:-$(rand_pass)}'
TUIC_UUID='${TUIC_UUID:-$(rand_uuid)}'
TUIC_PASSWORD='${TUIC_PASSWORD:-$(rand_pass)}'
SS_PASSWORD='${SS_PASSWORD:-$(rand_pass)}'
VLESS_UUID='${VLESS_UUID:-$(rand_uuid)}'
VMESS_UUID='${VMESS_UUID:-$(rand_uuid)}'
TROJAN_PASSWORD='${TROJAN_PASSWORD:-$(rand_pass)}'
REALITY_UUID='${REALITY_UUID:-$(rand_uuid)}'
REALITY_PRIVATE_KEY='${REALITY_PRIVATE_KEY:-}'
REALITY_PUBLIC_KEY='${REALITY_PUBLIC_KEY:-}'
REALITY_SHORT_ID='${REALITY_SHORT_ID:-$(rand_hex 8)}'
"
  # 用 <名字>_V 环境变量显式覆盖凭据 (如 HY2_PASSWORD_V=xxx TUIC_PASSWORD_V=yyy)
  local v val
  for v in HY2_PASSWORD TUIC_UUID TUIC_PASSWORD SS_PASSWORD VLESS_UUID VMESS_UUID TROJAN_PASSWORD REALITY_UUID REALITY_SHORT_ID; do
    eval "val=\"\${${v}_V:-}\""
    if [ -n "$val" ]; then
      out=$(printf '%s\n' "$out" | sed "s|^${v}=.*|${v}='${val}'|")
    fi
  done
  printf '%s\n' "$out" > "$CREDS_FILE"
  chmod 600 "$CREDS_FILE"
  . "$CREDS_FILE"
}

pick_sni() {
  local list=("www.cloudflare.com" "www.microsoft.com" "www.bing.com" "www.apple.com" "www.amazon.com")
  echo "${list[$((RANDOM % ${#list[@]}))]}"
}

ensure_cert() {
  local user_cert="${CERT_FILE:-}" user_key="${KEY_FILE:-}"
  CERT_FILE="${user_cert:-$CERT_FILE_DEFAULT}"
  KEY_FILE="${user_key:-$KEY_FILE_DEFAULT}"
  [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ] && { log "复用已有证书: $CERT_FILE"; return; }
  [ -n "$user_cert" ] && [ "$CERT_FILE" != "$CERT_FILE_DEFAULT" ] && die "指定证书不存在: $CERT_FILE"
  log "生成自签证书 (SNI: $DOMAIN)"
  openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
    -subj "/CN=${DOMAIN}" \
    -addext "subjectAltName=DNS:${DOMAIN},DNS:*.${DOMAIN},IP:0.0.0.0" \
    -keyout "$KEY_FILE" -out "$CERT_FILE" >/dev/null 2>&1 \
    || die "证书生成失败"
  chmod 600 "$KEY_FILE"
}

# ---- 二进制安装 ----
detect_arch_asset() {
  case "$(uname -m)" in
    x86_64)  echo "x86_64-unknown-linux-musl" ;;
    aarch64|arm64) echo "aarch64-unknown-linux-musl" ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
}

install_binary() {
  local tag="${SHOES_TAG:-$SHOES_TAG_DEFAULT}"
  if [ -x "$BIN_PATH" ]; then
    local cur; cur=$("$BIN_PATH" --version 2>/dev/null | head -1 || true)
    log "检测到已安装: $cur"
    if echo "$cur" | grep -q "$tag"; then log "版本一致，跳过安装"; return; fi
  fi
  local asset="shoes-$(detect_arch_asset)"
  local url="https://github.com/cfal/shoes/releases/download/${tag}/${asset}.tar.gz"
  [ -n "${MIRROR:-}" ] && url="${MIRROR%/}/${url}"
  local tmp; tmp=$(mktemp -d)
  log "下载 $url"
  curl -fSL --retry 3 -o "$tmp/shoes.tar.gz" "$url" || die "下载失败(可用 MIRROR= 换镜像)"
  tar -xzf "$tmp/shoes.tar.gz" -C "$tmp"
  local b; b=$(find "$tmp" -type f -name shoes | head -1)
  [ -n "$b" ] || die "压缩包内未找到 shoes 二进制"
  install -m 755 "$b" "${BIN_PATH}.new" && mv -f "${BIN_PATH}.new" "$BIN_PATH"
  rm -rf "$tmp"
  log "已安装: $("$BIN_PATH" --version 2>&1 | head -1)"
}

# ---- Reality 密钥 (依赖 shoes 二进制, 需在 install_binary 之后调用) ----
ensure_reality_keys() {
  enabled reality || return 0
  [ -n "${REALITY_PRIVATE_KEY:-}" ] && [ -n "${REALITY_PUBLIC_KEY:-}" ] && { log "复用已有 Reality 密钥"; return; }
  local kp
  kp=$("$BIN_PATH" generate-reality-keypair 2>/dev/null) || die "Reality 密钥生成失败"
  REALITY_PRIVATE_KEY=$(printf '%s\n' "$kp" | sed -n 's/^REALITY private key: *//p')
  REALITY_PUBLIC_KEY=$(printf '%s\n' "$kp" | sed -n 's/^REALITY public key: *//p')
  [ -n "$REALITY_PRIVATE_KEY" ] && [ -n "$REALITY_PUBLIC_KEY" ] || die "Reality 密钥解析失败"
  # 持久化到凭据文件, 重装时复用
  if grep -q '^REALITY_PRIVATE_KEY=' "$CREDS_FILE"; then
    sed -i "s|^REALITY_PRIVATE_KEY=.*|REALITY_PRIVATE_KEY='${REALITY_PRIVATE_KEY}'|" "$CREDS_FILE"
    sed -i "s|^REALITY_PUBLIC_KEY=.*|REALITY_PUBLIC_KEY='${REALITY_PUBLIC_KEY}'|" "$CREDS_FILE"
  else
    printf "REALITY_PRIVATE_KEY='%s'\nREALITY_PUBLIC_KEY='%s'\n" "$REALITY_PRIVATE_KEY" "$REALITY_PUBLIC_KEY" >> "$CREDS_FILE"
  fi
  chmod 600 "$CREDS_FILE"
  log "已生成 Reality X25519 密钥对"
}

# ---- 配置渲染 ----
render_config() {
  local sni="$DOMAIN" cert="$CERT_FILE" key="$KEY_FILE"
  echo "# 顶层为 YAML 列表; 日志级别由服务单元 RUST_LOG 控制"
  if enabled hy2; then
    cat <<EOF
  - address: "0.0.0.0:${HY2_PORT}"
    transport: quic
    quic_settings:
      cert: ${cert}
      key: ${key}
      alpn_protocols: ["h3"]
    rules: allow-all-direct
    protocol:
      type: hysteria2
      password: ${HY2_PASSWORD}
      udp_enabled: true
EOF
  fi
  if enabled tuic; then
    cat <<EOF
  - address: "0.0.0.0:${TUIC_PORT}"
    transport: quic
    quic_settings:
      cert: ${cert}
      key: ${key}
      alpn_protocols: ["h3"]
    rules: allow-all-direct
    protocol:
      type: tuic
      uuid: ${TUIC_UUID}
      password: ${TUIC_PASSWORD}
      zero_rtt_handshake: true
EOF
  fi
  if enabled ss; then
    cat <<EOF
  - address: "0.0.0.0:${SS_PORT}"
    rules: allow-all-direct
    protocol:
      type: shadowsocks
      cipher: aes-256-gcm
      password: ${SS_PASSWORD}
EOF
  fi
  if enabled vless; then
    cat <<EOF
  - address: "0.0.0.0:${VLESS_PORT}"
    protocol:
      type: tls
      tls_targets:
        "${sni}":
          cert: ${cert}
          key: ${key}
          protocol:
            type: vless
            user_id: ${VLESS_UUID}
            udp_enabled: true
    rules: allow-all-direct
EOF
  fi
  if enabled vmess; then
    cat <<EOF
  - address: "0.0.0.0:${VMESS_PORT}"
    protocol:
      type: tls
      tls_targets:
        "${sni}":
          cert: ${cert}
          key: ${key}
          protocol:
            type: vmess
            cipher: chacha20-poly1305
            user_id: ${VMESS_UUID}
            udp_enabled: true
    rules: allow-all-direct
EOF
  fi
  if enabled trojan; then
    cat <<EOF
  - address: "0.0.0.0:${TROJAN_PORT}"
    protocol:
      type: tls
      tls_targets:
        "${sni}":
          cert: ${cert}
          key: ${key}
          protocol:
            type: trojan
            password: ${TROJAN_PASSWORD}
    rules: allow-all-direct
EOF
  fi
  if enabled reality; then
    cat <<EOF
  - address: "0.0.0.0:${REALITY_PORT}"
    protocol:
      type: tls
      reality_targets:
        "${REALITY_DEST%%:*}":
          private_key: "${REALITY_PRIVATE_KEY}"
          short_ids: ["${REALITY_SHORT_ID}", ""]
          dest: "${REALITY_DEST}"
          protocol:
            type: vless
            user_id: ${REALITY_UUID}
            udp_enabled: true
    rules: allow-all-direct
EOF
  fi
}

enabled() { echo ",${PROTOCOLS}," | grep -q ",$1,"; }

write_config() {
  [ -f "$CONF_FILE" ] && cp -f "$CONF_FILE" "${CONF_FILE}.bak.$(date +%s)"
  render_config > "$CONF_FILE"
  chmod 600 "$CONF_FILE"
  # 备份只保留最近 3 份
  ls -t "${CONF_FILE}".bak.* 2>/dev/null | tail -n +4 | xargs -r rm -f
  "$BIN_PATH" check "$CONF_FILE" || { warn "配置校验失败!"; return 1; }
  log "配置校验通过: $CONF_FILE"
}

# ---- 服务 ----
write_service() {
  if [ "$INIT_SYS" = "systemd" ]; then
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=shoes all-in-one proxy server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} ${CONF_FILE}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
Environment=RUST_LOG=${LOG_LEVEL}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  else
    cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run
name="${SERVICE_NAME}"
command="${BIN_PATH}"
command_args="${CONF_FILE}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/${SERVICE_NAME}.log"
error_log="/var/log/${SERVICE_NAME}.log"

depend() { need net; }
EOF
    chmod +x "$SERVICE_FILE"
  fi
}

open_firewall() {
  local ports=""
  enabled hy2 && ports="$ports ${HY2_PORT}/udp" || true
  enabled tuic && ports="$ports ${TUIC_PORT}/udp" || true
  enabled ss && ports="$ports ${SS_PORT}" || true
  enabled vless && ports="$ports ${VLESS_PORT}" || true
  enabled vmess && ports="$ports ${VMESS_PORT}" || true
  enabled trojan && ports="$ports ${TROJAN_PORT}" || true
  enabled reality && ports="$ports ${REALITY_PORT}" || true
  if have ufw; then for p in $ports; do ufw allow "$p" >/dev/null 2>&1 || true; done; fi
  if have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    for p in $ports; do
      local pn=${p%%/*} pr=${p##*/}
      if [ "$pr" != "$p" ]; then firewall-cmd --permanent --add-port="${pn}-${pn#*/}/${pr}" >/dev/null 2>&1 || firewall-cmd --permanent --add-port="${pn}/${pr}" >/dev/null 2>&1 || true
      else firewall-cmd --permanent --add-port="$p" >/dev/null 2>&1 || true; fi
    done
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  if have iptables && iptables -L INPUT -n 2>/dev/null | head -1 | grep -qE 'DROP|REJECT'; then
    for p in $ports; do
      local pn=${p%%/*} proto=tcp
      case "$p" in */udp) proto=udp;; esac
      iptables -C INPUT -p "$proto" --dport "$pn" -j ACCEPT 2>/dev/null || iptables -I INPUT -p "$proto" --dport "$pn" -j ACCEPT
    done
  fi
  if ! have ufw && ! (have firewall-cmd && firewall-cmd --state >/dev/null 2>&1) \
     && ! (have iptables && iptables -L INPUT -n 2>/dev/null | head -1 | grep -qE 'DROP|REJECT'); then
    warn "未检测到 ufw/firewalld/iptables 防火墙规则 (可能是 nftables 托管)，请自行确认端口已放行"
  fi
  log "如为云服务器请确认安全组已放行上述端口"
}

start_service() {
  if [ "$INIT_SYS" = "systemd" ]; then
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME"
    sleep 1
    systemctl is-active --quiet "$SERVICE_NAME" || { journalctl -u "$SERVICE_NAME" -n 30 --no-pager; die "服务启动失败"; }
    systemctl status "$SERVICE_NAME" --no-pager -l | head -5
  else
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
    rc-service "$SERVICE_NAME" restart || rc-service "$SERVICE_NAME" start
    sleep 1
    rc-service "$SERVICE_NAME" status
  fi
}

detect_public_ip() {
  if [ -n "${SERVER_ADDR:-}" ]; then echo "$SERVER_ADDR"; return; fi
  curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null \
    || echo "<YOUR_IP>"
}

b64() { printf '%s' "$1" | base64 2>/dev/null | tr -d '\n'; }

print_summary() {
  local ip; ip=$(detect_public_ip)
  local sni="$DOMAIN"
  echo
  echo "================ shoes 全家桶部署完成 ================"
  echo " 服务: ${SERVICE_NAME}   版本: $("$BIN_PATH" --version 2>&1 | head -1)"
  echo " 服务器: ${ip}    SNI/伪装域名: ${sni}"
  echo " 配置: ${CONF_FILE}   证书: ${CERT_FILE}"
  echo "------------------------------------------------------"
  printf " %-8s %-6s %-10s %s\n" "协议" "端口" "传输" "说明"
  if enabled hy2; then printf " %-8s %-6s %-10s %s\n" "HY2" "$HY2_PORT" "UDP/QUIC" "Hysteria2"; fi
  if enabled tuic; then printf " %-8s %-6s %-10s %s\n" "TUIC" "$TUIC_PORT" "UDP/QUIC" "TUIC v5"; fi
  if enabled ss; then printf " %-8s %-6s %-10s %s\n" "SS" "$SS_PORT" "TCP" "aes-256-gcm"; fi
  if enabled vless; then printf " %-8s %-6s %-10s %s\n" "VLESS" "$VLESS_PORT" "TCP/TLS" ""; fi
  if enabled vmess; then printf " %-8s %-6s %-10s %s\n" "VMESS" "$VMESS_PORT" "TCP/TLS" "AEAD"; fi
  if enabled trojan; then printf " %-8s %-6s %-10s %s\n" "TROJAN" "$TROJAN_PORT" "TCP/TLS" ""; fi
  if enabled reality; then printf " %-8s %-6s %-10s %s\n" "REALITY" "$REALITY_PORT" "TCP" "VLESS+Reality"; fi
  echo "------------------------------------------------------"
  echo " 凭据与分享链接:"
  if enabled hy2; then echo " [HY2]
   hysteria2://${HY2_PASSWORD}@${ip}:${HY2_PORT}/?sni=${sni}&insecure=1#shoes-hy2"
  fi
  if enabled tuic; then echo " [TUIC]
   tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?sni=${sni}&allow_insecure=1&congestion_control=bbr&udp_relay_mode=native#shoes-tuic"
  fi
  if enabled ss; then echo " [SS]
   ss://$(b64 "aes-256-gcm:${SS_PASSWORD}")@${ip}:${SS_PORT}#shoes-ss"
  fi
  if enabled vless; then echo " [VLESS]
   vless://${VLESS_UUID}@${ip}:${VLESS_PORT}?security=tls&sni=${sni}&allowInsecure=1&type=tcp#shoes-vless"
  fi
  if enabled vmess; then echo " [VMESS]
   vmess://$(b64 "{\"v\":\"2\",\"ps\":\"shoes-vmess\",\"add\":\"${ip}\",\"port\":\"${VMESS_PORT}\",\"id\":\"${VMESS_UUID}\",\"aid\":\"0\",\"net\":\"tcp\",\"type\":\"none\",\"host\":\"${sni}\",\"path\":\"\",\"tls\":\"tls\",\"sni\":\"${sni}\"}")"
  fi
  if enabled trojan; then echo " [TROJAN]
   trojan://${TROJAN_PASSWORD}@${ip}:${TROJAN_PORT}?security=tls&sni=${sni}&allowInsecure=1#shoes-trojan"
  fi
  if enabled reality; then echo " [REALITY]
   vless://${REALITY_UUID}@${ip}:${REALITY_PORT}?security=reality&sni=${REALITY_DEST%%:*}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&flow=xtls-rprx-vision#shoes-reality"
  fi
  echo "------------------------------------------------------"
  echo " 管理命令:"
  if [ "$INIT_SYS" = "systemd" ]; then
    echo "   systemctl status/restart ${SERVICE_NAME}   journalctl -u ${SERVICE_NAME} -f"
  else
    echo "   rc-service ${SERVICE_NAME} status/restart   tail -f /var/log/${SERVICE_NAME}.log"
  fi
  echo "   shoes-all info | logs [N] | uninstall"
  echo "======================================================"
}

validate_plan() {
  local dup
  dup=$(echo "$HY2_PORT $TUIC_PORT $SS_PORT $VLESS_PORT $VMESS_PORT $TROJAN_PORT $REALITY_PORT" | tr ' ' '\n' | sort | uniq -d)
  # hy2/tuic 是 UDP 其余是 TCP，同号可共存，这里只提示
  if [ -n "$dup" ]; then warn "存在相同端口号(UDP 与 TCP 可共存): $dup"; fi
  log "端口计划: hy2=${HY2_PORT}/udp tuic=${TUIC_PORT}/udp ss=${SS_PORT} vless=${VLESS_PORT} vmess=${VMESS_PORT} trojan=${TROJAN_PORT} reality=${REALITY_PORT}"
}

install_self() {
  cp -f "$0" /usr/local/bin/shoes-all 2>/dev/null && chmod +x /usr/local/bin/shoes-all || true
}

# ---- 子命令 ----
do_install() {
  detect_platform; check_deps; validate_plan
  load_or_init_creds; ensure_cert
  install_binary
  ensure_reality_keys
  write_config || die "配置写入失败"
  write_service
  open_firewall
  start_service
  install_self
  print_summary
}

cmd_update() {
  detect_platform; install_binary; start_service; install_self
  log "升级完成: $("$BIN_PATH" --version 2>&1 | head -1)"
}

cmd_status() {
  detect_platform
  if [ "$INIT_SYS" = "systemd" ]; then systemctl status "$SERVICE_NAME" --no-pager -l || true
  else rc-service "$SERVICE_NAME" status || true; fi
  if [ -f "$CONF_FILE" ]; then
    echo "--- 监听端口 ---"
    grep -E '^\s+- address:' "$CONF_FILE" | sed 's/^ *//'
  fi
}

cmd_info() {
  [ -f "$CREDS_FILE" ] || die "未找到凭据文件 $CREDS_FILE，请先安装"
  . "$CREDS_FILE"
  CERT_FILE="${CERT_FILE:-$CERT_FILE_DEFAULT}"
  print_summary
}

cmd_logs() {
  local n="${1:-100}"
  if [ "$INIT_SYS" = "systemd" ]; then journalctl -u "$SERVICE_NAME" -n "$n" --no-pager
  else tail -n "$n" /var/log/"${SERVICE_NAME}".log 2>/dev/null || die "无日志文件"; fi
}

cmd_uninstall() {
  detect_platform
  log "停止并删除服务..."
  if [ "$INIT_SYS" = "systemd" ]; then
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"; systemctl daemon-reload
  else
    rc-service "$SERVICE_NAME" stop 2>/dev/null || true
    rc-update del "$SERVICE_NAME" default 2>/dev/null || true
    rm -f "$SERVICE_FILE"
  fi
  if [ "${KEEP_CONFIG:-0}" = "1" ]; then
    log "保留配置: $CONF_DIR"
  else
    rm -rf "$CONF_DIR"; log "已删除 $CONF_DIR (KEEP_CONFIG=1 可保留)"
  fi
  rm -f /usr/local/bin/shoes-all "$BIN_PATH"
  log "卸载完成"
}

main() {
  case "${1:-install}" in
    install)    do_install ;;
    plan)       validate_plan ;;
    status)     cmd_status ;;
    info)       cmd_info ;;
    logs)       shift; cmd_logs "$@" ;;
    update)     cmd_update ;;
    uninstall)  cmd_uninstall ;;
    help|-h|--help)
      sed -n '2,27p' "$0" ;;
    *) die "未知命令: $1 (可用: install/plan/status/info/logs/update/uninstall/help)" ;;
  esac
}

main "$@"
