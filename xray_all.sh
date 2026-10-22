#!/usr/bin/env bash
# =============================================================================
# xray_all.sh — Xray-core 全家桶一键部署脚本 (参考 shoes_all.sh / singbox_all.sh 架构)
# 核心: https://github.com/XTLS/Xray-core
#
# 说明: 不含 Hysteria2 / TUIC / MTProto (Xray 官方不支持 QUIC 系协议与 MTProto),
#       只装 TCP/TLS 系 5 个入站, 单进程单配置。
#
# 平台: Debian 系(systemd+apt) / RHEL 系(systemd+dnf/yum) / Alpine(OpenRC+apk)
#       架构 x86_64 / aarch64 (官方 zip 包)
#
# 用法:
#   sudo bash xray_all.sh install    # 安装(默认全部协议)
#   sudo bash xray_all.sh plan       # 只打印端口计划
#   sudo bash xray_all.sh status     # 服务状态
#   sudo bash xray_all.sh info       # 重新打印凭据与分享链接
#   sudo bash xray_all.sh logs [N]   # 日志
#   sudo bash xray_all.sh update     # 升级二进制并重启 (配置不变)
#   sudo bash xray_all.sh uninstall  # 卸载 (KEEP_CONFIG=1 保留配置)
#
# 环境变量:
#   PROTOCOLS=reality,vless,vmess,trojan,ss   选择启用的协议(逗号分隔)
#   REALITY_PORT=443 VLESS_PORT=8989 VMESS_PORT=8990 TROJAN_PORT=8444 SS_PORT=8388
#   REALITY_DEST=www.cloudflare.com:443  Reality 握手目标(借用其 TLS 指纹; 勿用 microsoft.com, 证书超 8192 上限)
#   DOMAIN=xxx.com                  SNI/证书域名(默认随机伪装域名)
#   XRAY_TAG=v26.3.27               锁定版本(默认即该版本; 传 latest 则联网取最新 release)
#   MIRROR=https://ghfast.top/      GitHub 下载镜像前缀
#   CERT_FILE/KEY_FILE=...          使用已有证书
#   SERVER_ADDR=1.2.3.4             手动指定对外 IP
# =============================================================================
set -euo pipefail

SERVICE_NAME="xray-all"
BIN_PATH="/usr/local/bin/xray"
CONF_DIR="/usr/local/etc/xray"
CONF_FILE="${CONF_DIR}/config.json"
CREDS_FILE="${CONF_DIR}/creds.env"
CERT_FILE_DEFAULT="${CONF_DIR}/cert.pem"
KEY_FILE_DEFAULT="${CONF_DIR}/key.pem"
LOG_LEVEL="${LOG_LEVEL:-warning}"

# ---- 默认端口 / 协议 ----
PROTOCOLS="${PROTOCOLS:-reality,vless,vmess,trojan,ss}"
REALITY_PORT="${REALITY_PORT:-443}"
VLESS_PORT="${VLESS_PORT:-8989}"
VMESS_PORT="${VMESS_PORT:-8990}"
TROJAN_PORT="${TROJAN_PORT:-8444}"
SS_PORT="${SS_PORT:-8388}"
# 注意: 不要用 www.microsoft.com 做 dest —— 其证书记录 8273 字节超过 REALITY
#       解析器硬编码的 8192 上限, 握手必然失败 (Xray-core #6356)
REALITY_DEST="${REALITY_DEST:-www.cloudflare.com:443}"   # Reality 握手目标(需为支持 TLS1.3+H2 的真实站点)

# 远端脚本地址: 用于 curl | bash 场景自装本地命令 (GitHub 直连, 不走 jsdelivr)
XRAY_RAW_URL="${XRAY_RAW_URL:-https://raw.githubusercontent.com/ppopcn/shoes_all/refs/heads/main/xray_all.sh}"

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

# ---- 输出样式 ----
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_CYA=$'\033[36m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_CYA=''; C_BLD=''; C_RST=''
fi

info() { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
log()  { info "$*"; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }
have() { command -v "$1" >/dev/null 2>&1; }

check_root() {
  [ "$(id -u)" = "0" ] || die "请用 root 运行: sudo bash $0 ${1:-install}"
}

check_deps() {
  local pkgs=""
  have curl || pkgs="$pkgs curl"
  have unzip || pkgs="$pkgs unzip"
  have openssl || pkgs="$pkgs openssl"
  case "$OS_FAMILY" in
    debian) [ -n "$pkgs" ] && apt-get update -y >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null ;;
    rhel)   [ -n "$pkgs" ] && { have dnf && dnf install -y $pkgs >/dev/null || yum install -y $pkgs >/dev/null; } ;;
    alpine) [ -n "$pkgs" ] && apk add --no-cache $pkgs >/dev/null ;;
  esac
  have curl || die "缺少 curl，请手动安装"
  have unzip || die "缺少 unzip，请手动安装"
  have openssl || die "缺少 openssl"
}

# ---- 随机工具 ----
rand_uuid() { have uuidgen && uuidgen || cat /proc/sys/kernel/random/uuid; }
rand_pass() { openssl rand -base64 24 | tr -d '/+=' | head -c 24; }
rand_hex()  { openssl rand -hex "$1"; }

check_selinux() {
  have getenforce || return 0
  [ "$(getenforce 2>/dev/null)" = "Enforcing" ] || return 0
  warn "SELinux 处于 Enforcing (RHEL/CentOS 常见)"
  warn "若服务起不来, 先看 /var/log/audit/audit.log; 可用 setenforce 0 临时验证是否 SELinux 拦截"
}

# ---- 凭据生成 / 复用 ----
load_or_init_creds() {
  mkdir -p "$CONF_DIR"
  local need=0
  [ -f "$CREDS_FILE" ] || need=1
  if [ "$need" = "0" ]; then . "$CREDS_FILE"; fi
  local out=""
  out="DOMAIN='${DOMAIN:-$(pick_sni)}'
SS_PASSWORD='${SS_PASSWORD:-$(rand_pass)}'
VLESS_UUID='${VLESS_UUID:-$(rand_uuid)}'
VMESS_UUID='${VMESS_UUID:-$(rand_uuid)}'
TROJAN_PASSWORD='${TROJAN_PASSWORD:-$(rand_pass)}'
REALITY_UUID='${REALITY_UUID:-$(rand_uuid)}'
REALITY_PRIVATE_KEY='${REALITY_PRIVATE_KEY:-}'
REALITY_PUBLIC_KEY='${REALITY_PUBLIC_KEY:-}'
REALITY_SHORT_ID='${REALITY_SHORT_ID:-$(rand_hex 8)}'
"
  # 用 <名字>_V 环境变量显式覆盖凭据 (如 TROJAN_PASSWORD_V=xxx VLESS_UUID_V=yyy)
  local v val
  for v in DOMAIN SS_PASSWORD VLESS_UUID VMESS_UUID TROJAN_PASSWORD REALITY_UUID REALITY_SHORT_ID; do
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
  [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ] && { ok "复用已有证书: $CERT_FILE"; return; }
  [ -n "$user_cert" ] && [ "$CERT_FILE" != "$CERT_FILE_DEFAULT" ] && die "指定证书不存在: $CERT_FILE"
  info "生成自签证书 (CN=${DOMAIN}, 10 年有效期)..."
  local san="DNS:${DOMAIN},DNS:*.${DOMAIN},IP:0.0.0.0"
  if openssl req -help 2>&1 | grep -q -- '-addext'; then
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
      -subj "/CN=${DOMAIN}" -addext "subjectAltName=${san}" \
      -keyout "$KEY_FILE" -out "$CERT_FILE" >/dev/null 2>&1 \
      || die "证书生成失败"
  else
    # 老版本 OpenSSL(<1.1.1, 如 CentOS 7) 没有 -addext, 用配置文件方式
    local cnf; cnf=$(mktemp)
    cat > "$cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=${DOMAIN}
[v3]
subjectAltName=${san}
EOF
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
      -config "$cnf" -keyout "$KEY_FILE" -out "$CERT_FILE" >/dev/null 2>&1
    local rc=$?
    rm -f "$cnf"
    [ "$rc" = "0" ] || die "证书生成失败"
  fi
  chmod 600 "$KEY_FILE"
  ok "证书已生成: $CERT_FILE"
}

need_cert() {
  enabled vless || enabled vmess || enabled trojan
}

# ---- 二进制安装 ----
detect_arch_asset() {
  case "$(uname -m)" in
    x86_64)          echo "Xray-linux-64.zip" ;;
    aarch64|arm64)   echo "Xray-linux-arm64-v8a.zip" ;;
    i686|i386)       echo "Xray-linux-32.zip" ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
}

XRAY_TAG_DEFAULT="v26.3.27"

resolve_tag() {
  # 默认用锁定的已验证版本; XRAY_TAG=latest 时才联网取最新 release
  local tag="${XRAY_TAG:-$XRAY_TAG_DEFAULT}"
  if [ "$tag" != "latest" ]; then printf '%s' "$tag"; return; fi
  local t
  t=$(curl -fsSL --max-time 10 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
      | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' || true)
  [ -n "$t" ] || { warn "无法解析最新版本(网络受限?), 回退到 ${XRAY_TAG_DEFAULT}"; t="$XRAY_TAG_DEFAULT"; }
  printf '%s' "$t"
}

install_binary() {
  local tag; tag=$(resolve_tag)
  [ -n "$tag" ] || tag="$XRAY_TAG_DEFAULT"
  if [ -x "$BIN_PATH" ]; then
    local cur; cur=$("$BIN_PATH" version 2>/dev/null | sed -n 1p || true)
    # Xray 的 version 输出不带 v 前缀(Xray 26.3.27 ...), 比较时去掉 tag 的 v
    if echo "$cur" | grep -q "${tag#v}"; then ok "已安装 ${cur:-未知}, 跳过下载"; return; fi
    warn "现有版本: ${cur:-未知}, 准备升级到 ${tag}"
  fi
  local asset url
  asset="$(detect_arch_asset)"
  url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${asset}"
  [ -n "${MIRROR:-}" ] && url="${MIRROR%/}/${url}"
  local tmp; tmp=$(mktemp -d)
  info "下载: ${url}"
  curl -fSL --retry 3 --connect-timeout 15 -o "$tmp/xray.zip" "$url" || die "下载失败(可用 MIRROR= 换镜像或 XRAY_TAG= 锁版本)"
  unzip -oq "$tmp/xray.zip" -d "$tmp" || die "解包失败"
  [ -f "$tmp/xray" ] || die "压缩包内未找到 xray 二进制"
  install -m 755 "$tmp/xray" "${BIN_PATH}.new" && mv -f "${BIN_PATH}.new" "$BIN_PATH"
  # geo 数据一并安装(路由/伪装需要), 缺了不影响基础代理
  for f in geoip.dat geosite.dat; do
    [ -f "$tmp/$f" ] && install -m 644 "$tmp/$f" "$CONF_DIR/$f"
  done
  rm -rf "$tmp"
  ok "已安装: $("$BIN_PATH" version 2>&1 | head -1)"
}

# ---- Reality 密钥 (依赖 xray 二进制, 需在 install_binary 之后调用) ----
ensure_reality_keys() {
  enabled reality || return 0
  [ -n "${REALITY_PRIVATE_KEY:-}" ] && [ -n "${REALITY_PUBLIC_KEY:-}" ] && { ok "复用已有 Reality 密钥"; return; }
  info "生成 Reality X25519 密钥对..."
  local kp
  kp=$("$BIN_PATH" x25519 2>/dev/null) || die "Reality 密钥生成失败"
  # 兼容两种输出格式:
  #   旧: "Private key: xxx" / "Public key: xxx"
  #   新(26.x+): "PrivateKey: xxx" / "Password (PublicKey): xxx" (+ Hash32 行)
  REALITY_PRIVATE_KEY=$(printf '%s\n' "$kp" | sed -n 's/^.*[Pp]rivate *[Kk]ey:[[:space:]]*//p' | head -1 | tr -d '\r')
  REALITY_PUBLIC_KEY=$(printf '%s\n' "$kp" | sed -n 's/^.*[Pp]ublic[K ]*[Kk]ey)\{0,1\}:[[:space:]]*//p' | head -1 | tr -d '\r')
  [ -n "$REALITY_PRIVATE_KEY" ] && [ -n "$REALITY_PUBLIC_KEY" ] || die "Reality 密钥解析失败: $kp"
  # base64url 43 字符校验, 防止解析残留前缀(如 ")")静默写坏凭据
  echo "$REALITY_PRIVATE_KEY" | grep -qE '^[A-Za-z0-9_-]{43}$' || die "Reality 私钥格式异常: $REALITY_PRIVATE_KEY"
  echo "$REALITY_PUBLIC_KEY"  | grep -qE '^[A-Za-z0-9_-]{43}$' || die "Reality 公钥格式异常: $REALITY_PUBLIC_KEY"
  # 持久化到凭据文件, 重装时复用
  if grep -q '^REALITY_PRIVATE_KEY=' "$CREDS_FILE"; then
    sed -i "s|^REALITY_PRIVATE_KEY=.*|REALITY_PRIVATE_KEY='${REALITY_PRIVATE_KEY}'|" "$CREDS_FILE"
    sed -i "s|^REALITY_PUBLIC_KEY=.*|REALITY_PUBLIC_KEY='${REALITY_PUBLIC_KEY}'|" "$CREDS_FILE"
  else
    printf "REALITY_PRIVATE_KEY='%s'\nREALITY_PUBLIC_KEY='%s'\n" "$REALITY_PRIVATE_KEY" "$REALITY_PUBLIC_KEY" >> "$CREDS_FILE"
  fi
  chmod 600 "$CREDS_FILE"
  ok "已生成 Reality X25519 密钥对"
}

enabled() { echo ",${PROTOCOLS}," | grep -q ",$1,"; }

# ---- 配置渲染 (单文件 JSON, 多入站并存) ----
write_config() {
  if [ -f "$CONF_FILE" ]; then
    local bak="${CONF_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp -f "$CONF_FILE" "$bak" && warn "旧配置已备份: ${bak}"
    ls -t "${CONF_FILE}".bak.* 2>/dev/null | tail -n +4 | xargs -r rm -f
  fi
  local sni="$DOMAIN" cert="$CERT_FILE" key="$KEY_FILE"

  cat > "$CONF_FILE" <<EOF
{
  "log": { "loglevel": "${LOG_LEVEL}" },
  "inbounds": [
EOF

  local first=1
  add_in() {  # 入站之间补逗号
    if [ "$first" = "1" ]; then first=0; else printf ',\n' >> "$CONF_FILE"; fi
    cat >> "$CONF_FILE"
  }

  if enabled ss; then
    add_in <<EOF
    {
      "listen": "0.0.0.0",
      "port": ${SS_PORT},
      "protocol": "shadowsocks",
      "settings": {
        "method": "aes-256-gcm",
        "password": "${SS_PASSWORD}",
        "network": "tcp,udp"
      }
    }
EOF
  fi

  if enabled vless; then
    add_in <<EOF
    {
      "listen": "0.0.0.0",
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${VLESS_UUID}" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${sni}",
          "certificates": [ { "certificateFile": "${cert}", "keyFile": "${key}" } ]
        },
        "wsSettings": { "path": "/vless" }
      }
    }
EOF
  fi

  if enabled vmess; then
    add_in <<EOF
    {
      "listen": "0.0.0.0",
      "port": ${VMESS_PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [ { "id": "${VMESS_UUID}", "alterId": 0 } ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${sni}",
          "certificates": [ { "certificateFile": "${cert}", "keyFile": "${key}" } ]
        },
        "wsSettings": { "path": "/vmess" }
      }
    }
EOF
  fi

  if enabled trojan; then
    add_in <<EOF
    {
      "listen": "0.0.0.0",
      "port": ${TROJAN_PORT},
      "protocol": "trojan",
      "settings": {
        "clients": [ { "password": "${TROJAN_PASSWORD}" } ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${sni}",
          "certificates": [ { "certificateFile": "${cert}", "keyFile": "${key}" } ]
        }
      }
    }
EOF
  fi

  if enabled reality; then
    add_in <<EOF
    {
      "listen": "0.0.0.0",
      "port": ${REALITY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${REALITY_UUID}", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": [ "${REALITY_DEST%%:*}" ],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": [ "${REALITY_SHORT_ID}", "" ]
        }
      }
    }
EOF
  fi

  cat >> "$CONF_FILE" <<EOF
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

  chmod 600 "$CONF_FILE"
  ok "配置已写入: ${CONF_FILE}"
  # 配置自检: 失败则回滚, 避免留下坏配置把服务弄挂
  if ! "$BIN_PATH" run -test -c "$CONF_FILE" >/dev/null 2>&1; then
    warn "配置校验失败, 输出详情:"
    "$BIN_PATH" run -test -c "$CONF_FILE" 2>&1 | sed -n '1,10p' || true
    local lastbak; lastbak=$(ls -t "${CONF_FILE}".bak.* 2>/dev/null | sed -n 1p || true)
    if [ -n "$lastbak" ]; then
      cp -f "$lastbak" "$CONF_FILE" && warn "已回滚到上一份有效配置: ${lastbak}"
    else
      rm -f "$CONF_FILE"; warn "无历史配置可回滚, 已删除无效配置"
    fi
    return 1
  fi
  ok "配置校验通过"
}

# ---- 服务 ----
write_service() {
  if [ "$INIT_SYS" = "systemd" ]; then
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Xray all-in-one proxy server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} run -c ${CONF_FILE}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  else
    # OpenRC(Alpine): 用 supervise-daemon 才能把 stdout/stderr 落到 output_log
    cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run
name="${SERVICE_NAME}"
command="${BIN_PATH}"
command_args="run -c ${CONF_FILE}"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
output_log="/var/log/${SERVICE_NAME}.log"
error_log="/var/log/${SERVICE_NAME}.log"

depend() { need net; after firewall; }
EOF
    chmod +x "$SERVICE_FILE"
  fi
  ok "服务已注册: ${SERVICE_FILE}"
}

open_firewall() {
  local ports="" p pn pr handled=0
  # SS 入站同时监听 tcp+udp, 两个都要放行
  enabled ss && ports="$ports ${SS_PORT} ${SS_PORT}/udp" || true
  enabled vless && ports="$ports ${VLESS_PORT}" || true
  enabled vmess && ports="$ports ${VMESS_PORT}" || true
  enabled trojan && ports="$ports ${TROJAN_PORT}" || true
  enabled reality && ports="$ports ${REALITY_PORT}" || true

  if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    for p in $ports; do
      ufw allow "$p" >/dev/null 2>&1 && ok "ufw 已放行 ${p}" || warn "ufw 放行失败: ${p}"
    done
    handled=1
  fi
  if have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    for p in $ports; do
      firewall-cmd --permanent --add-port="$p" >/dev/null 2>&1 \
        && ok "firewalld 已放行 ${p}" || warn "firewalld 放行失败: ${p}"
    done
    firewall-cmd --reload >/dev/null 2>&1 || true
    handled=1
  fi
  if [ "$handled" = "0" ] && have iptables && iptables -L INPUT -n 2>/dev/null | head -1 | grep -qE 'DROP|REJECT'; then
    for p in $ports; do
      pn=${p%%/*}; pr=tcp
      case "$p" in */udp) pr=udp;; esac
      if iptables -C INPUT -p "$pr" --dport "$pn" -j ACCEPT 2>/dev/null; then
        continue
      fi
      iptables -I INPUT -p "$pr" --dport "$pn" -j ACCEPT 2>/dev/null \
        && ok "iptables 已放行 ${pn}/${pr}" || warn "iptables 放行失败: ${pn}/${pr}"
    done
    handled=1
  fi
  if [ "$handled" = "0" ]; then
    warn "未检测到生效中的 ufw/firewalld/iptables(DROP) 规则, 可能是 nftables 托管"
    warn "请自行确认以下端口已放行: ${ports# }"
  fi
  warn "云服务器安全组不归本脚本管, 以上端口需在控制台手动放行"
}

start_service() {
  info "启动服务..."
  if [ "$INIT_SYS" = "systemd" ]; then
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME"
    sleep 1
    systemctl is-active --quiet "$SERVICE_NAME" || { journalctl -u "$SERVICE_NAME" -n 30 --no-pager; die "服务启动失败"; }
    ok "服务运行中: ${SERVICE_NAME}"
  else
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
    rc-service "$SERVICE_NAME" restart || rc-service "$SERVICE_NAME" start
    sleep 1
    rc-service "$SERVICE_NAME" status || true
    ok "服务运行中: ${SERVICE_NAME}"
  fi
}

detect_public_ip() {
  if [ -n "${SERVER_ADDR:-}" ]; then echo "$SERVER_ADDR"; return; fi
  curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null \
    || echo "<YOUR_IP>"
}

b64() { printf '%s' "$1" | base64 2>/dev/null | tr -d '\n'; }

# ---- 输出：小节标题 / 链接行 ----
_sec_head() { # $1=序号 $2=名称 $3=监听
  printf '\n  %s── %s %s ─────────────────────────────%s\n' "$C_BLD$C_BLU" "$1" "$2" "$C_RST"
  printf '  监听 : %s%s%s\n' "$C_YEL" "$3" "$C_RST"
}
_link_line() { printf '  链接 : %s%s%s\n' "$C_GRN" "$1" "$C_RST"; }

print_manage_block() {
  echo
  printf '  %s──────── 管理命令 ────────────────────────────────────────%s\n' "$C_BLD$C_BLU" "$C_RST"
  echo
  printf '  %s· 服务管理%s\n' "$C_BLD" "$C_RST"
  if [ "$INIT_SYS" = "systemd" ]; then
    printf '  %-44s %s\n' "systemctl status ${SERVICE_NAME}" "查看状态"
    printf '  %-44s %s\n' "systemctl restart ${SERVICE_NAME}" "重启服务"
    printf '  %-44s %s\n' "journalctl -u ${SERVICE_NAME} -f" "实时日志"
    printf '  %-44s %s\n' "journalctl -u ${SERVICE_NAME} -n 200" "最近 200 行日志"
  else
    printf '  %-44s %s\n' "rc-service ${SERVICE_NAME} status" "查看状态"
    printf '  %-44s %s\n' "rc-service ${SERVICE_NAME} restart" "重启服务"
    printf '  %-44s %s\n' "tail -f /var/log/${SERVICE_NAME}.log" "实时日志"
  fi
  echo
  printf '  %s· 内置命令%s\n' "$C_BLD" "$C_RST"
  printf '  %-44s %s\n' "xray-all info" "重新打印凭据与分享链接"
  printf '  %-44s %s\n' "xray-all status" "服务状态与监听端口"
  printf '  %-44s %s\n' "xray-all logs [N]" "最近 N 行日志"
  printf '  %-44s %s\n' "xray-all update" "升级内核并重启"
  printf '  %-44s %s\n' "xray-all uninstall" "卸载 (KEEP_CONFIG=1 保留配置)"
  echo
  printf '  %s· 排错命令%s\n' "$C_BLD" "$C_RST"
  printf '  %-44s %s\n' "xray run -test -c ${CONF_FILE}" "校验配置合法性"
  printf '  %-44s %s\n' "ss -tlnp | grep xray" "查看 TCP 监听"
  printf '  %-44s %s\n' "cat ${CONF_FILE}" "查看渲染后的配置"
  echo
  printf '  %s提示:%s 客户端连不上时先看 xray-all logs；\n' "$C_YEL" "$C_RST"
  printf '  需要更细的握手日志: LOG_LEVEL=debug sudo -E bash xray_all.sh install\n'
  echo
}

print_summary() {
  local ip sni ver rows=() r n l d
  ip=$(detect_public_ip)
  sni="$DOMAIN"
  ver=$( { "$BIN_PATH" version 2>&1 || true; } | sed -n '1p' )

  echo
  printf '  %s============================================================%s\n' "$C_BLD$C_BLU" "$C_RST"
  printf '   %s Xray 全家桶部署完成 %s\n' "$C_BLD$C_GRN" "$C_RST"
  printf '  %s============================================================%s\n' "$C_BLD$C_BLU" "$C_RST"

  # ---- 服务器信息 ----
  printf '\n  %s▍服务器信息%s\n' "$C_BLD$C_YEL" "$C_RST"
  printf '  服务器 IP     : %s%s%s\n' "$C_BLD" "$ip" "$C_RST"
  printf '  服务名        : %s (单进程)\n' "$SERVICE_NAME"
  printf '  内核版本      : %s\n' "$ver"
  printf '  配置文件      : %s\n' "$CONF_FILE"
  printf '  凭据文件      : %s (权限 600)\n' "$CREDS_FILE"
  printf '  初始化系统    : %s\n' "$INIT_SYS"
  if enabled vless || enabled vmess || enabled trojan; then
    printf '  证书          : %s (自签, 客户端需跳过校验)\n' "$CERT_FILE"
    printf '  SNI / 域名    : %s\n' "$sni"
  fi
  if enabled reality; then
    printf '  Reality 目标  : %s (借用其 TLS 指纹)\n' "$REALITY_DEST"
  fi

  # ---- 入站总览表 ----
  if enabled reality; then rows+=("Reality|${REALITY_PORT}/tcp|VLESS + XTLS Vision, 无需证书"); fi
  if enabled vless;   then rows+=("VLESS|${VLESS_PORT}/tcp|TLS + WS, 路径 /vless"); fi
  if enabled vmess;   then rows+=("VMess|${VMESS_PORT}/tcp|TLS + WS, 路径 /vmess"); fi
  if enabled trojan;  then rows+=("Trojan|${TROJAN_PORT}/tcp|TLS 直连"); fi
  if enabled ss;      then rows+=("Shadowsocks|${SS_PORT}/tcp+udp|aes-256-gcm"); fi

  printf '\n  %s▍入站总览%s\n' "$C_BLD$C_YEL" "$C_RST"
  printf '  协议            监听端口       说明\n'
  printf '  %s\n' "────────────────────────────────────────────"
  for r in "${rows[@]}"; do
    IFS='|' read -r n l d <<<"$r"
    printf '  %-15s %-14s %s\n' "$n" "$l" "$d"
  done

  # ---- 各协议凭据与链接 ----
  printf '\n  %s▍连接信息%s\n' "$C_BLD$C_YEL" "$C_RST"
  if enabled reality; then
    _sec_head "[1]" "VLESS + Reality" "${REALITY_PORT}/tcp"
    printf '  UUID : %s\n' "$REALITY_UUID"
    printf '  SNI  : %s\n' "${REALITY_DEST%%:*}"
    printf '  PBK  : %s\n' "$REALITY_PUBLIC_KEY"
    printf '  SID  : %s\n' "$REALITY_SHORT_ID"
    _link_line "vless://${REALITY_UUID}@${ip}:${REALITY_PORT}?security=reality&sni=${REALITY_DEST%%:*}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&flow=xtls-rprx-vision#xray-reality"
  fi
  if enabled vless; then
    _sec_head "[2]" "VLESS (TLS+WS)" "${VLESS_PORT}/tcp"
    printf '  UUID : %s\n' "$VLESS_UUID"
    printf '  路径 : /vless\n'
    _link_line "vless://${VLESS_UUID}@${ip}:${VLESS_PORT}?security=tls&sni=${sni}&allowInsecure=1&type=ws&path=%2Fvless#xray-vless"
  fi
  if enabled vmess; then
    _sec_head "[3]" "VMess (TLS+WS)" "${VMESS_PORT}/tcp"
    printf '  UUID : %s\n' "$VMESS_UUID"
    printf '  路径 : /vmess\n'
    _link_line "vmess://$(b64 "{\"v\":\"2\",\"ps\":\"xray-vmess\",\"add\":\"${ip}\",\"port\":\"${VMESS_PORT}\",\"id\":\"${VMESS_UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${sni}\",\"path\":\"/vmess\",\"tls\":\"tls\",\"sni\":\"${sni}\"}")"
  fi
  if enabled trojan; then
    _sec_head "[4]" "Trojan" "${TROJAN_PORT}/tcp"
    printf '  密码 : %s\n' "$TROJAN_PASSWORD"
    _link_line "trojan://${TROJAN_PASSWORD}@${ip}:${TROJAN_PORT}?security=tls&sni=${sni}&allowInsecure=1#xray-trojan"
  fi
  if enabled ss; then
    _sec_head "[5]" "Shadowsocks" "${SS_PORT}/tcp+udp"
    printf '  加密 : %s\n' "aes-256-gcm"
    printf '  密码 : %s\n' "$SS_PASSWORD"
    _link_line "ss://$(b64 "aes-256-gcm:${SS_PASSWORD}")@${ip}:${SS_PORT}#xray-ss"
  fi

  # ---- 客户端提示 ----
  printf '\n  %s▍客户端提示%s\n' "$C_BLD$C_YEL" "$C_RST"
  printf '  · TLS 类协议记得开 "允许不安全证书 / allowInsecure"\n'
  printf '  · Reality 无需证书, 客户端填 SNI 与公钥即可; 删掉 short_id 也能连\n'
  printf '  · REALITY_DEST 别用 www.microsoft.com: 其证书记录超 8192 字节上限, 握手必失败\n'
  printf '  · VLESS/VMess 走 WebSocket, 客户端传输层选 ws, 路径分别为 /vless 和 /vmess\n'
  printf '  · VMess 加密方式选 auto 即可(内核自动协商 aes-128-gcm/chacha20)\n'
  print_manage_block
}

validate_plan() {
  local dup ports="" p
  enabled reality && ports="$ports $REALITY_PORT" || true
  enabled vless   && ports="$ports $VLESS_PORT" || true
  enabled vmess   && ports="$ports $VMESS_PORT" || true
  enabled trojan  && ports="$ports $TROJAN_PORT" || true
  enabled ss      && ports="$ports $SS_PORT" || true
  dup=$(echo "$ports" | tr ' ' '\n' | grep -v '^$' | sort | uniq -d)
  if [ -n "$dup" ]; then die "已启用协议存在重复端口, 请调整: $dup"; fi
  ok "端口计划: reality=${REALITY_PORT} vless=${VLESS_PORT} vmess=${VMESS_PORT} trojan=${TROJAN_PORT} ss=${SS_PORT} (仅列出, 未启用的不生效)"
}

install_self() {
  local dest=/usr/local/bin/xray-all src="$0" base
  base="$(basename "$src" 2>/dev/null || echo bash)"
  # 本地文件运行: 直接拷自己; curl | bash 时 $0 是 bash, 需要回源下载一份
  if [ -f "$src" ] && [ "$base" != "bash" ] && [ "$base" != "-bash" ] && [ "$base" != "sh" ]; then
    cp -f "$src" "$dest" 2>/dev/null && chmod +x "$dest" && { ok "本地命令: $dest"; return 0; }
  fi
  info "安装本地命令 ${dest} ..."
  if curl -fsSL --retry 2 --max-time 30 -o "${dest}.tmp" "$XRAY_RAW_URL" 2>/dev/null \
     && bash -n "${dest}.tmp" 2>/dev/null; then
    mv -f "${dest}.tmp" "$dest" && chmod +x "$dest" && { ok "本地命令: $dest"; return 0; }
  fi
  rm -f "${dest}.tmp" 2>/dev/null || true
  warn "未能安装本地命令, 可这样管理: curl -fsSL ${XRAY_RAW_URL} | sudo bash -s -- info"
}

# ---- 子命令 ----
do_install() {
  echo
  printf '  %s============================================================%s\n' "$C_BLD$C_BLU" "$C_RST"
  printf '   %s Xray 全协议服务端 · 一键部署 %s\n' "$C_BLD$C_GRN" "$C_RST"
  printf '  %s============================================================%s\n' "$C_BLD$C_BLU" "$C_RST"
  echo

  info "协议: ${PROTOCOLS}"
  detect_platform
  check_deps
  check_selinux
  validate_plan
  load_or_init_creds
  if need_cert; then ensure_cert; else info "未启用 TLS 类协议, 跳过证书生成"; fi
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
  log "升级完成: $( { "$BIN_PATH" version 2>&1 || true; } | sed -n 1p )"
}

cmd_status() {
  detect_platform
  local active=0
  if [ "$INIT_SYS" = "systemd" ]; then
    systemctl is-active --quiet "$SERVICE_NAME" && active=1
  else
    rc-service "$SERVICE_NAME" status 2>/dev/null | grep -q "status: started" && active=1
  fi
  echo
  printf '  %s▍服务状态%s\n' "$C_BLD$C_YEL" "$C_RST"
  if [ "$active" = "1" ]; then ok "${SERVICE_NAME}: 运行中"; else warn "${SERVICE_NAME}: 未运行"; fi
  if [ -f "$CONF_FILE" ]; then
    printf '  配置 : %s\n' "$CONF_FILE"
    printf '  监听 : %s\n' "$(grep -o '"port": [0-9]*' "$CONF_FILE" | awk '{print $2}' | tr '\n' ' ')"
    printf '  进程 : %s\n' "$(pgrep -a -f "xray run -c ${CONF_FILE}" | head -1 || echo '无')"
  else
    warn "未安装 (未找到 ${CONF_FILE})"
  fi
  echo
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
  info "开始卸载 ${SERVICE_NAME}..."
  if [ "$INIT_SYS" = "systemd" ]; then
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"; systemctl daemon-reload
    ok "已移除 systemd 服务"
  else
    rc-service "$SERVICE_NAME" stop 2>/dev/null || true
    rc-update del "$SERVICE_NAME" default 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    ok "已移除 OpenRC 服务"
  fi
  if [ "${KEEP_CONFIG:-0}" = "1" ]; then
    warn "保留配置: $CONF_DIR"
  else
    rm -rf "$CONF_DIR"; ok "已删除 $CONF_DIR (KEEP_CONFIG=1 可保留)"
  fi
  rm -f /usr/local/bin/xray-all "$BIN_PATH"
  ok "卸载完成"
}

usage() {
  # 本地文件: 直接打印头部注释; curl|bash 时 $0 是 bash, 读不到 -> 用内置简版
  if [ -r "$0" ] && sed -n '2,32p' "$0" 2>/dev/null | grep -q 'PROTOCOLS'; then
    sed -n '2,32p' "$0"
  else
    cat <<'EOF'
xray_all.sh — Xray-core 全家桶一键部署 (reality/vless/vmess/trojan/ss)

用法:
  sudo bash xray_all.sh [install|plan|status|info|logs [N]|update|uninstall]

环境变量:
  PROTOCOLS=reality,vless,vmess,trojan,ss   选择协议(逗号分隔, 默认全装)
  REALITY_PORT=443 VLESS_PORT=8989 VMESS_PORT=8990 TROJAN_PORT=8444 SS_PORT=8388
  REALITY_DEST=www.cloudflare.com:443       Reality 握手目标(勿用 microsoft.com)
  DOMAIN=xxx.com                            SNI/证书域名
  XRAY_TAG=v26.3.27                         锁定版本; 传 latest 取上游最新
  MIRROR=https://ghfast.top/                GitHub 下载镜像前缀
  CERT_FILE/KEY_FILE=...                    使用已有证书
  SERVER_ADDR=1.2.3.4                       手动指定对外 IP
EOF
  fi
}

main() {
  case "${1:-install}" in
    install|update|uninstall) check_root "${1:-install}" ;;&
  esac
  case "${1:-install}" in
    install)    do_install ;;
    plan)       validate_plan ;;
    status)     cmd_status ;;
    info)       cmd_info ;;
    logs)       shift; cmd_logs "$@" ;;
    update)     cmd_update ;;
    uninstall)  cmd_uninstall ;;
    help|-h|--help)
      usage ;;
    *) die "未知命令: $1 (可用: install/plan/status/info/logs/update/uninstall/help)" ;;
  esac
}

main "$@"
