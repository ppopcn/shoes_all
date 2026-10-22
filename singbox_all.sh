#!/usr/bin/env bash
# =============================================================================
# singbox_all.sh — sing-box 全家桶一键部署脚本 (单进程 / 单配置 / 8 入站)
# 核心: https://github.com/shtorm-7/sing-box-extended (extended 版, 含 MTPROXY)
#
# 平台: Debian 系(systemd+apt) / RHEL 系(systemd+dnf/yum) / Alpine(OpenRC+apk)
#       架构 x86_64 / aarch64 / armv7 / i386 (tar.gz, Alpine 优先取 musl 包)
#
# 默认端口计划 (443 的 TCP 与 UDP 互不冲突, 分别给 MT 与 HY2; TUIC 让出 443 用 8443):
#   MTPROXY 443/tcp   Hysteria2 443/udp   TUIC 8443/udp   Shadowsocks 8388/tcp+udp
#   VLESS 8989/tcp    VMess 8990/tcp      Trojan 8444/tcp  Reality 8899/tcp
#
# 用法:
#   sudo bash singbox_all.sh install    # 安装(默认全部协议)
#   sudo bash singbox_all.sh plan       # 只打印端口计划
#   sudo bash singbox_all.sh status     # 服务状态
#   sudo bash singbox_all.sh info       # 重新打印凭据与分享链接
#   sudo bash singbox_all.sh logs [N]   # 日志
#   sudo bash singbox_all.sh update     # 升级到上游最新内核并重启 (配置不变)
#   sudo bash singbox_all.sh uninstall  # 卸载 (KEEP_CONFIG=1 保留配置)
#
# 环境变量:
#   PROTOCOLS=mt,hy2,tuic,ss,vless,vmess,trojan,reality   选择启用的协议(逗号分隔)
#   MT_PORT=443 HY2_PORT=443 TUIC_PORT=8443 SSR_PORT=8388
#   VLESS_PORT=8989 VMESS_PORT=8990 TROJAN_PORT=8444 REALITY_PORT=8899
#   DOMAIN=xxx.com                  全部 TLS 协议共用的 SNI/证书域名(默认随机伪装域名)
#   REALITY_DEST=www.microsoft.com:443   Reality 握手目标(借用其 TLS 指纹)
#   MT_USER_NAME=user1 MT_CONCURRENCY=8192
#   HY2_OBFS=xxx                    Hysteria2 salamander 混淆密码(默认关闭)
#   TUIC_CONGESTION=bbr SSR_METHOD=aes-256-gcm VLESS_PATH=/vless VMESS_PATH=/vmess
#   SINGBOX_TAG=v1.14.3-extended-2.7.3  锁定版本(默认即该版本; 传 latest 则联网取最新)
#   MIRROR=https://ghfast.top/      GitHub 下载镜像前缀
#   CERT_FILE/KEY_FILE=...          使用已有证书
#   SERVER_ADDR=1.2.3.4             手动指定对外 IP
#   FORCE_BIN=1                     强制重新下载内核
# =============================================================================
set -euo pipefail

SINGBOX_TAG_DEFAULT="v1.14.3-extended-2.7.3"
REPO="shtorm-7/sing-box-extended"
SERVICE_NAME="singbox-all"
BIN_PATH="/usr/local/bin/sing-box"
CMD_PATH="/usr/local/bin/singbox-all"
CONF_DIR="/etc/sing-box"
CONF_FILE="${CONF_DIR}/all.json"
CREDS_FILE="${CONF_DIR}/creds.env"
CERT_FILE="${CERT_FILE:-${CONF_DIR}/cert.pem}"
KEY_FILE="${KEY_FILE:-${CONF_DIR}/key.pem}"
LOG_LEVEL="${LOG_LEVEL:-info}"
FORCE_BIN="${FORCE_BIN:-0}"
KEEP_CONFIG="${KEEP_CONFIG:-0}"

# ---- 默认端口 / 协议 ----
PROTOCOLS="${PROTOCOLS:-mt,hy2,tuic,ss,vless,vmess,trojan,reality}"
MT_PORT="${MT_PORT:-443}"
HY2_PORT="${HY2_PORT:-443}"
TUIC_PORT="${TUIC_PORT:-8443}"
SSR_PORT="${SSR_PORT:-8388}"
VLESS_PORT="${VLESS_PORT:-8989}"
VMESS_PORT="${VMESS_PORT:-8990}"
TROJAN_PORT="${TROJAN_PORT:-8444}"
REALITY_PORT="${REALITY_PORT:-8899}"

# ---- 非凭据类协议参数 ----
MT_USER_NAME="${MT_USER_NAME:-user1}"
MT_CONCURRENCY="${MT_CONCURRENCY:-8192}"
TUIC_CONGESTION="${TUIC_CONGESTION:-bbr}"
SSR_METHOD="${SSR_METHOD:-aes-256-gcm}"
VLESS_PATH="${VLESS_PATH:-/vless}"
VMESS_PATH="${VMESS_PATH:-/vmess}"
REALITY_DEST="${REALITY_DEST:-www.microsoft.com:443}"   # Reality 握手目标(需为支持 TLS1.3+H2 的真实站点)

# 远端脚本地址: 用于 curl | bash 场景自装本地命令 (GitHub 直连)
SINGBOX_RAW_URL="${SINGBOX_RAW_URL:-https://raw.githubusercontent.com/ppopcn/shoes_all/refs/heads/main/singbox_all.sh}"

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
  have tar  || pkgs="$pkgs tar"
  if need_cert && ! have openssl; then pkgs="$pkgs openssl"; fi
  case "$OS_FAMILY" in
    debian) [ -n "$pkgs" ] && apt-get update -y >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null ;;
    rhel)   [ -n "$pkgs" ] && { have dnf && dnf install -y $pkgs >/dev/null || yum install -y $pkgs >/dev/null; } ;;
    alpine) [ -n "$pkgs" ] && apk add --no-cache $pkgs >/dev/null ;;
  esac
  have curl || die "缺少 curl，请手动安装"
  have tar  || die "缺少 tar"
  if need_cert; then have openssl || die "缺少 openssl"; fi
}

# ---- 随机工具 ----
rand_uuid() { have uuidgen && uuidgen || cat /proc/sys/kernel/random/uuid; }
rand_pass() { head -c 16 /dev/urandom | base64 | tr -d '/+=' | head -c 22; }
rand_hex()  { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

check_selinux() {
  have getenforce || return 0
  [ "$(getenforce 2>/dev/null)" = "Enforcing" ] || return 0
  warn "SELinux 处于 Enforcing (RHEL/CentOS 常见)"
  warn "若服务起不来, 先看 /var/log/audit/audit.log; 可用 setenforce 0 临时验证是否 SELinux 拦截"
}

# ---- 凭据生成 / 复用 ----
# 与 shoes/xray 一致: 全部凭据落在一份 creds.env, 重装自动复用, 客户端配置不会失效
load_or_init_creds() {
  # HY2_OBFS 是行为开关(客户端必须同步), 显式传入时优先于旧凭据文件
  local obfs_env="${HY2_OBFS:-}"
  mkdir -p "$CONF_DIR"
  if [ -f "$CREDS_FILE" ]; then . "$CREDS_FILE"; fi
  local out=""
  out="DOMAIN='${DOMAIN:-$(pick_sni)}'
SECRET='${SECRET:-$(_mt_gen_secret)}'
HY2_PASSWORD='${HY2_PASSWORD:-$(rand_pass)}'
HY2_OBFS='${obfs_env:-${HY2_OBFS:-}}'
TUIC_UUID='${TUIC_UUID:-$(rand_uuid)}'
TUIC_PASSWORD='${TUIC_PASSWORD:-$(rand_pass)}'
SSR_PASSWORD='${SSR_PASSWORD:-$(rand_pass)}'
VLESS_UUID='${VLESS_UUID:-$(rand_uuid)}'
VMESS_UUID='${VMESS_UUID:-$(rand_uuid)}'
TROJAN_PASSWORD='${TROJAN_PASSWORD:-$(rand_pass)}'
REALITY_UUID='${REALITY_UUID:-$(rand_uuid)}'
REALITY_PRIVATE_KEY='${REALITY_PRIVATE_KEY:-}'
REALITY_PUBLIC_KEY='${REALITY_PUBLIC_KEY:-}'
REALITY_SHORT_ID='${REALITY_SHORT_ID:-$(rand_hex 8)}'
"
  # 用 <名字>_V 环境变量显式覆盖凭据 (如 HY2_PASSWORD_V=xxx VLESS_UUID_V=yyy DOMAIN_V=example.com)
  local v val
  for v in DOMAIN SECRET HY2_PASSWORD HY2_OBFS TUIC_UUID TUIC_PASSWORD SSR_PASSWORD \
           VLESS_UUID VMESS_UUID TROJAN_PASSWORD REALITY_UUID REALITY_SHORT_ID; do
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

# MTProxy secret: ee + 16 字节随机(hex) + 伪装域名(hex), 长度固定 34+2*len(domain)
_mt_gen_secret() {
  printf 'ee%s' "$(rand_hex 16)"
  printf '%s' "${DOMAIN:-www.bing.com}" | od -An -tx1 | tr -d ' \n'
}

ensure_cert() {
  local user_cert="${CERT_FILE:-}"
  if [ -s "$CERT_FILE" ] && [ -s "$KEY_FILE" ]; then ok "复用已有证书: $CERT_FILE"; return 0; fi
  if [ -n "$user_cert" ] && [ "$CERT_FILE" != "${CONF_DIR}/cert.pem" ]; then die "指定证书不存在: $CERT_FILE"; fi
  info "生成自签证书 (CN=${DOMAIN}, 10 年有效期)..."
  mkdir -p "$(dirname "$CERT_FILE")" "$(dirname "$KEY_FILE")"
  local san="DNS:${DOMAIN},DNS:*.${DOMAIN}"
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
    if ! openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
         -config "$cnf" -keyout "$KEY_FILE" -out "$CERT_FILE" >/dev/null 2>&1; then
      rm -f "$cnf" "$KEY_FILE" "$CERT_FILE"
      die "证书生成失败 (老版 OpenSSL 分支)"
    fi
    rm -f "$cnf"
  fi
  chmod 600 "$KEY_FILE"
  ok "证书已生成: $CERT_FILE"
}

need_cert() {
  enabled hy2 || enabled tuic || enabled vless || enabled vmess || enabled trojan
}

# ---- 二进制安装 ----
detect_arch_asset() {
  case "$(uname -m)" in
    x86_64|amd64)        echo "amd64" ;;
    aarch64|arm64)       echo "arm64" ;;
    armv7l|armv7)        echo "armv7" ;;
    i386|i486|i586|i686) echo "386" ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
}

resolve_tag() {
  # $1 可选: SINGBOX_TAG 未设置时的默认目标 —— install 传锁定版本, update 传 latest
  local tag="${SINGBOX_TAG:-${1:-$SINGBOX_TAG_DEFAULT}}"
  if [ "$tag" != "latest" ]; then printf '%s' "$tag"; return; fi
  local t
  # 取 releases 列表第 1 条而不是 /releases/latest —— 上游若把新版标为 prerelease
  # (Xray 从 v26.6 起全部如此), /latest 会永远停在最后一个非 prerelease 版本上
  t=$(curl -fsSL --max-time 10 "https://api.github.com/repos/${REPO}/releases?per_page=5" 2>/dev/null \
      | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -n '1s/.*"\([^"]*\)"$/\1/p' || true)
  [ -n "$t" ] || { warn "无法解析最新版本(网络受限?), 回退到 ${SINGBOX_TAG_DEFAULT}"; t="$SINGBOX_TAG_DEFAULT"; }
  printf '%s' "$t"
}

install_binary() {
  local tag; tag=$(resolve_tag "$@")
  local arch; arch=$(detect_arch_asset)
  if [ -x "$BIN_PATH" ]; then
    local cur; cur=$("$BIN_PATH" version 2>/dev/null | head -1 || true)
    # 版本已锁定且本地就是该版本: 直接复用, 完全不碰网络
    if [ "$FORCE_BIN" != "1" ] && [ -n "$cur" ] && printf '%s' "$cur" | grep -q "${tag#v}"; then
      ok "已安装 ${cur}, 跳过下载"; return
    fi
    if [ -n "$cur" ]; then warn "现有版本: ${cur}, 准备安装 ${tag}"; fi
  fi
  if [ "$FORCE_BIN" = "1" ]; then warn "FORCE_BIN=1, 强制重新下载"; fi
  local ver="${tag#v}"
  local base="sing-box-${ver}-linux-${arch}"
  # 个别架构只发 glibc/musl 变体, 依次试三种命名, 取第一个下载成功的
  local cands=("${base}.tar.gz" "${base}-glibc.tar.gz" "${base}-musl.tar.gz")
  if [ "$OS_FAMILY" = "alpine" ]; then cands=("${base}-musl.tar.gz" "${base}.tar.gz" "${base}-glibc.tar.gz"); fi
  local tmp; tmp=$(mktemp -d)
  local url got=0 c
  for c in "${cands[@]}"; do
    url="https://github.com/${REPO}/releases/download/${tag}/${c}"
    if [ -n "${MIRROR:-}" ]; then url="${MIRROR%/}/${url}"; fi
    info "下载: ${url}"
    if curl -fSL --retry 2 --connect-timeout 15 -o "$tmp/sb.tar.gz" "$url" 2>/dev/null; then got=1; break; fi
    warn "下载失败, 换下一个命名: ${c}"
  done
  [ "$got" = "1" ] || { rm -rf "$tmp"; die "下载失败(可用 MIRROR= 换镜像或 SINGBOX_TAG= 锁版本)"; }
  tar -xzf "$tmp/sb.tar.gz" -C "$tmp" || { rm -rf "$tmp"; die "解包失败"; }
  local b; b=$(find "$tmp" -maxdepth 2 -type f -name sing-box | head -1)
  [ -n "$b" ] || { rm -rf "$tmp"; die "压缩包内未找到 sing-box 二进制"; }
  install -m 755 "$b" "${BIN_PATH}.new" && mv -f "${BIN_PATH}.new" "$BIN_PATH"
  rm -rf "$tmp"
  local nver; nver=$("$BIN_PATH" version 2>/dev/null | head -1 || true)
  ok "已安装: ${nver:-$tag}"
}

# ---- Reality 密钥 (依赖 sing-box 二进制, 需在 install_binary 之后调用) ----
ensure_reality_keys() {
  enabled reality || return 0
  if [ -n "${REALITY_PRIVATE_KEY:-}" ] && [ -n "${REALITY_PUBLIC_KEY:-}" ]; then
    ok "复用已有 Reality 密钥"; return 0
  fi
  info "生成 Reality X25519 密钥对..."
  local kp pk="" pub=""
  kp=$("$BIN_PATH" generate reality-keypair 2>/dev/null) || die "Reality 密钥生成失败"
  # 兼容两种输出: "PrivateKey: xxx" (新版) / "Private key: xxx" (旧版)
  pk=$(printf '%s\n' "$kp" | sed -n 's/^[Pp]rivate[Kk ]*[Kk]ey:[[:space:]]*//p' | head -1 | tr -d '\r')
  pub=$(printf '%s\n' "$kp" | sed -n 's/^[Pp]ublic[Kk ]*[Kk]ey:[[:space:]]*//p' | head -1 | tr -d '\r')
  [ -n "$pk" ] && [ -n "$pub" ] || die "Reality 密钥解析失败: ${kp}"
  REALITY_PRIVATE_KEY="$pk"
  REALITY_PUBLIC_KEY="$pub"
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

# 协议 -> 端口变量名 / 入站 tag / 传输层协议族
port_var() {
  case "$1" in
    mt) echo MT_PORT ;; hy2) echo HY2_PORT ;; tuic) echo TUIC_PORT ;; ss) echo SSR_PORT ;;
    vless) echo VLESS_PORT ;; vmess) echo VMESS_PORT ;; trojan) echo TROJAN_PORT ;; reality) echo REALITY_PORT ;;
  esac
}
tag_of() {
  case "$1" in
    mt) echo mtp-in ;; hy2) echo hy2-in ;; tuic) echo tuic-in ;; ss) echo ss-in ;;
    vless) echo vless-in ;; vmess) echo vmess-in ;; trojan) echo trojan-in ;; reality) echo reality-in ;;
  esac
}
nets_of() {
  case "$1" in
    hy2|tuic) echo "udp" ;;
    ss)       echo "tcp udp" ;;
    *)        echo "tcp" ;;
  esac
}

normalize_protocols() {
  # 逐项校验 + 去重, 非法值直接报错(sing-box 同款行为)
  local out="" p
  for p in $(printf '%s' "$PROTOCOLS" | tr ',' ' '); do
    [ -n "$p" ] || continue
    if [ "$p" = "ssr" ]; then p=ss; fi   # 兼容旧写法 ssr, 内部统一用 ss
    case "$p" in
      mt|hy2|tuic|ss|vless|vmess|trojan|reality) out="$out,$p" ;;
      *) die "未知协议: ${p} (可用: mt hy2 tuic ss vless vmess trojan reality)" ;;
    esac
  done
  out=$(printf '%s' "${out#,}" | tr ',' '\n' | awk '!seen[$0]++' | tr '\n' ',')
  out="${out%,}"
  [ -n "$out" ] || die "PROTOCOLS 解析结果为空 (可用: mt hy2 tuic ss vless vmess trojan reality)"
  PROTOCOLS="$out"
}

# ---- 配置渲染 (单文件 JSON, 多入站并存) ----
render_config() {
  local inb="" obfs=""

  add_in() {  # 从 stdin 读入一个入站片段, 自动补逗号
    local body; body=$(cat)
    if [ -z "$inb" ]; then inb="$body"; else inb="${inb}"$',\n'"${body}"; fi
  }

  if enabled mt; then
    add_in <<EOF
    {
      "type": "mtproxy",
      "tag": "mtp-in",
      "listen": "::",
      "listen_port": ${MT_PORT},
      "users": [
        {
          "name": "${MT_USER_NAME}",
          "secret": "${SECRET}"
        }
      ],
      "concurrency": ${MT_CONCURRENCY},
      "domain_fronting_port": 443,
      "prefer_ip": "prefer-ipv4",
      "auto_update": false,
      "allow_fallback_on_unknown_dc": false,
      "tolerate_time_skewness": "5m",
      "idle_timeout": "5m",
      "handshake_timeout": "10s"
    }
EOF
  fi

  if enabled hy2; then
    if [ -n "$HY2_OBFS" ]; then
      obfs='      "obfs": {
        "type": "salamander",
        "password": "'"${HY2_OBFS}"'"
      },
'
    else
      obfs=""
    fi
    add_in <<EOF
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [
        {
          "password": "${HY2_PASSWORD}"
        }
      ],
      "ignore_client_bandwidth": true,
      "masquerade": "https://${DOMAIN}",
${obfs}      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "alpn": [
          "h3"
        ],
        "min_version": "1.3",
        "certificate_path": "${CERT_FILE}",
        "key_path": "${KEY_FILE}"
      }
    }
EOF
  fi

  if enabled tuic; then
    add_in <<EOF
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": ${TUIC_PORT},
      "users": [
        {
          "uuid": "${TUIC_UUID}",
          "password": "${TUIC_PASSWORD}"
        }
      ],
      "congestion_control": "${TUIC_CONGESTION}",
      "auth_timeout": "3s",
      "zero_rtt_handshake": false,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "alpn": [
          "h3"
        ],
        "min_version": "1.3",
        "certificate_path": "${CERT_FILE}",
        "key_path": "${KEY_FILE}"
      }
    }
EOF
  fi

  if enabled ss; then
    add_in <<EOF
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": ${SSR_PORT},
      "network": [
        "tcp",
        "udp"
      ],
      "method": "${SSR_METHOD}",
      "password": "${SSR_PASSWORD}"
    }
EOF
  fi

  if enabled vless; then
    add_in <<EOF
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${VLESS_PORT},
      "users": [
        {
          "uuid": "${VLESS_UUID}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "alpn": [
          "http/1.1"
        ],
        "min_version": "1.2",
        "certificate_path": "${CERT_FILE}",
        "key_path": "${KEY_FILE}"
      },
      "transport": {
        "type": "ws",
        "path": "${VLESS_PATH}"
      }
    }
EOF
  fi

  if enabled vmess; then
    add_in <<EOF
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "::",
      "listen_port": ${VMESS_PORT},
      "users": [
        {
          "uuid": "${VMESS_UUID}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "alpn": [
          "http/1.1"
        ],
        "min_version": "1.2",
        "certificate_path": "${CERT_FILE}",
        "key_path": "${KEY_FILE}"
      },
      "transport": {
        "type": "ws",
        "path": "${VMESS_PATH}"
      }
    }
EOF
  fi

  if enabled trojan; then
    add_in <<EOF
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "::",
      "listen_port": ${TROJAN_PORT},
      "users": [
        {
          "password": "${TROJAN_PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "alpn": [
          "http/1.1"
        ],
        "min_version": "1.2",
        "certificate_path": "${CERT_FILE}",
        "key_path": "${KEY_FILE}"
      }
    }
EOF
  fi

  if enabled reality; then
    local dest_host="${REALITY_DEST%%:*}" dest_port="${REALITY_DEST##*:}"
    case "$dest_port" in ''|*[!0-9]*) dest_port=443 ;; esac
    add_in <<EOF
    {
      "type": "vless",
      "tag": "reality-in",
      "listen": "::",
      "listen_port": ${REALITY_PORT},
      "users": [
        {
          "uuid": "${REALITY_UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${dest_host}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${dest_host}",
            "server_port": ${dest_port}
          },
          "private_key": "${REALITY_PRIVATE_KEY}",
          "short_id": [
            "${REALITY_SHORT_ID}"
          ]
        }
      }
    }
EOF
  fi

  cat <<EOF
{
  "log": {
    "level": "${LOG_LEVEL}",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "default"
      }
    ]
  },
  "inbounds": [
${inb}
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct",
    "default_domain_resolver": {
      "server": "default",
      "strategy": "prefer_ipv4"
    }
  }
}
EOF
}

write_config() {
  mkdir -p "$CONF_DIR"
  local bak=""
  if [ -f "$CONF_FILE" ]; then
    bak="${CONF_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp -f "$CONF_FILE" "$bak" && warn "旧配置已备份: ${bak}"
    # 备份只保留最近 3 份
    ls -t "${CONF_FILE}".bak.* 2>/dev/null | tail -n +4 | xargs -r rm -f
  fi
  render_config > "$CONF_FILE"
  chmod 600 "$CONF_FILE"
  ok "配置已写入: ${CONF_FILE}"
  # 校验失败则回滚, 避免留下坏配置把服务弄挂
  if "$BIN_PATH" check -c "$CONF_FILE" >/dev/null 2>&1; then
    ok "配置校验通过"
  else
    warn "配置校验失败, 输出详情:"
    "$BIN_PATH" check -c "$CONF_FILE" 2>&1 | sed -n '1,10p' || true
    if [ -n "$bak" ]; then
      cp -f "$bak" "$CONF_FILE" && warn "已回滚到备份配置: ${bak}"
    else
      rm -f "$CONF_FILE"; warn "无历史配置可回滚, 已删除无效配置"
    fi
    return 1
  fi
}

# ---- 服务 ----
write_service() {
  if [ "$INIT_SYS" = "systemd" ]; then
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box all-in-one proxy server
Documentation=https://github.com/${REPO}
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} run -c ${CONF_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  else
    # OpenRC(Alpine): 用 supervise-daemon 才能把 stdout/stderr 落到 output_log,
    # 旧的 command_background + start-stop-daemon 会忽略 output_log(日志丢失)
    cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run
name="${SERVICE_NAME}"
description="sing-box all-in-one proxy server"
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
  enabled mt      && ports="$ports ${MT_PORT}" || true
  enabled hy2     && ports="$ports ${HY2_PORT}/udp" || true
  enabled tuic    && ports="$ports ${TUIC_PORT}/udp" || true
  enabled ss      && ports="$ports ${SSR_PORT} ${SSR_PORT}/udp" || true
  enabled vless   && ports="$ports ${VLESS_PORT}" || true
  enabled vmess   && ports="$ports ${VMESS_PORT}" || true
  enabled trojan  && ports="$ports ${TROJAN_PORT}" || true
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

service_active() {
  if [ "$INIT_SYS" = "systemd" ]; then
    systemctl is-active --quiet "$SERVICE_NAME"
  else
    rc-service "$SERVICE_NAME" status 2>/dev/null | grep -q "status: started"
  fi
}

start_service() {
  info "启动服务..."
  if [ "$INIT_SYS" = "systemd" ]; then
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    # restart 失败时不直接退出(否则 set -e 抢先终止, 日志和提示都看不到)
    systemctl restart "$SERVICE_NAME" || true
  else
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
    rc-service "$SERVICE_NAME" restart || rc-service "$SERVICE_NAME" start
  fi
  sleep 2

  # 双栈监听个别网络环境下起不来, 回退 IPv4
  if ! service_active && grep -q '"listen": "::"' "$CONF_FILE"; then
    warn "启动失败, 尝试改用 IPv4 监听..."
    sed -i 's/"listen": "::"/"listen": "0.0.0.0"/g' "$CONF_FILE"
    if [ "$INIT_SYS" = "systemd" ]; then systemctl restart "$SERVICE_NAME" || true
    else rc-service "$SERVICE_NAME" restart >/dev/null 2>&1 || true; fi
    sleep 2
  fi

  if ! service_active; then
    if [ "$INIT_SYS" = "systemd" ]; then
      journalctl -u "$SERVICE_NAME" -n 30 --no-pager 2>/dev/null || true
    else
      tail -n 30 "/var/log/${SERVICE_NAME}.log" 2>/dev/null || true
    fi
    die "服务启动失败。常见原因: ① 未先 install(服务单元不存在); ② 端口被占用(三个全家桶端口重叠, 同机只能跑一个, 用 ss -lntup 确认)"
  fi
  ok "服务运行中: ${SERVICE_NAME}"
}

detect_public_ip() {
  if [ -n "${SERVER_ADDR:-}" ]; then echo "$SERVER_ADDR"; return; fi
  curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null \
    || echo "<YOUR_IP>"
}

b64() { printf '%s' "$1" | base64 2>/dev/null | tr -d '\n'; }

# 从配置里按入站 tag 取监听端口(不依赖 python)
port_of_tag() {
  [ -f "$CONF_FILE" ] || return 0
  awk -v want="\"$1\"" '
    /"tag":/ { cur = $0 }
    index(cur, want) && /"listen_port"/ { gsub(/[^0-9]/, ""); print; exit }
  ' "$CONF_FILE"
}

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
  printf '  %-44s %s\n' "singbox-all info" "重新打印凭据与分享链接"
  printf '  %-44s %s\n' "singbox-all status" "服务状态与监听端口"
  printf '  %-44s %s\n' "singbox-all logs [N]" "最近 N 行日志"
  printf '  %-44s %s\n' "singbox-all update" "升级到上游最新内核 (SINGBOX_TAG=vX 钉版本)"
  printf '  %-44s %s\n' "singbox-all uninstall" "卸载 (KEEP_CONFIG=1 保留配置)"
  echo
  printf '  %s· 排错命令%s\n' "$C_BLD" "$C_RST"
  printf '  %-44s %s\n' "sing-box check -c ${CONF_FILE}" "校验配置合法性"
  printf '  %-44s %s\n' "ss -tlnp | grep sing-box" "查看 TCP 监听"
  printf '  %-44s %s\n' "ss -ulnp | grep sing-box" "查看 UDP 监听"
  printf '  %-44s %s\n' "cat ${CONF_FILE}" "查看渲染后的配置"
  echo
  printf '  %s提示:%s 客户端连不上时先看 singbox-all logs；\n' "$C_YEL" "$C_RST"
  printf '  需要更细的握手日志: LOG_LEVEL=debug sudo -E bash singbox_all.sh install\n'
  echo
}

print_summary() {
  local ip sni ver rows=() r n l d
  ip=$(detect_public_ip)
  sni="$DOMAIN"
  ver=$("$BIN_PATH" version 2>/dev/null | head -1 || true)

  echo
  printf '  %s============================================================%s\n' "$C_BLD$C_BLU" "$C_RST"
  printf '   %s sing-box 全家桶部署完成 %s\n' "$C_BLD$C_GRN" "$C_RST"
  printf '  %s============================================================%s\n' "$C_BLD$C_BLU" "$C_RST"

  # ---- 服务器信息 ----
  printf '\n  %s▍服务器信息%s\n' "$C_BLD$C_YEL" "$C_RST"
  printf '  服务器 IP     : %s%s%s\n' "$C_BLD" "$ip" "$C_RST"
  printf '  服务名        : %s (单进程)\n' "$SERVICE_NAME"
  printf '  内核版本      : %s\n' "${ver:-未知}"
  printf '  配置文件      : %s (单文件含全部入站)\n' "$CONF_FILE"
  printf '  凭据文件      : %s (权限 600)\n' "$CREDS_FILE"
  printf '  初始化系统    : %s\n' "$INIT_SYS"
  if need_cert; then
    printf '  证书          : %s (自签, 客户端需跳过校验)\n' "$CERT_FILE"
    printf '  SNI / 域名    : %s\n' "$sni"
  fi
  if enabled reality; then
    printf '  Reality 目标  : %s (借用其 TLS 指纹)\n' "$REALITY_DEST"
  fi

  # ---- 入站总览表 ----
  if enabled mt;      then rows+=("MTPROXY|${MT_PORT}/tcp|FakeTLS 伪装"); fi
  if enabled hy2;     then rows+=("Hysteria2|${HY2_PORT}/udp|QUIC"); fi
  if enabled tuic;    then rows+=("TUIC v5|${TUIC_PORT}/udp|QUIC + ${TUIC_CONGESTION}"); fi
  if enabled ss;      then rows+=("Shadowsocks|${SSR_PORT}/tcp+udp|${SSR_METHOD}"); fi
  if enabled vless;   then rows+=("VLESS|${VLESS_PORT}/tcp|TLS + WS, 路径 ${VLESS_PATH}"); fi
  if enabled vmess;   then rows+=("VMess|${VMESS_PORT}/tcp|TLS + WS, 路径 ${VMESS_PATH}"); fi
  if enabled trojan;  then rows+=("Trojan|${TROJAN_PORT}/tcp|TLS 直连"); fi
  if enabled reality; then rows+=("Reality|${REALITY_PORT}/tcp|VLESS + XTLS Vision"); fi

  printf '\n  %s▍入站总览%s\n' "$C_BLD$C_YEL" "$C_RST"
  printf '  协议            监听端口       说明\n'
  printf '  %s\n' "────────────────────────────────────────────"
  for r in "${rows[@]}"; do
    IFS='|' read -r n l d <<<"$r"
    printf '  %-15s %-14s %s\n' "$n" "$l" "$d"
  done

  # ---- 各协议凭据与链接 ----
  printf '\n  %s▍连接信息%s\n' "$C_BLD$C_YEL" "$C_RST"
  if enabled mt; then
    _sec_head "[1]" "MTPROXY" "${MT_PORT}/tcp"
    printf '  Secret : %s\n' "$SECRET"
    printf '  User   : %s\n' "$MT_USER_NAME"
    printf '  链接   : %shttps://t.me/proxy?server=%s&port=%s&secret=%s%s\n' \
      "$C_GRN" "$ip" "$MT_PORT" "$SECRET" "$C_RST"
  fi
  if enabled hy2; then
    _sec_head "[2]" "Hysteria2" "${HY2_PORT}/udp"
    printf '  密码 : %s\n' "$HY2_PASSWORD"
    if [ -n "$HY2_OBFS" ]; then
      printf '  混淆 : salamander / %s\n' "$HY2_OBFS"
      _link_line "hysteria2://${HY2_PASSWORD}@${ip}:${HY2_PORT}/?sni=${sni}&insecure=1&obfs=salamander&obfs-password=${HY2_OBFS}#singbox-hy2"
    else
      _link_line "hysteria2://${HY2_PASSWORD}@${ip}:${HY2_PORT}/?sni=${sni}&insecure=1#singbox-hy2"
    fi
  fi
  if enabled tuic; then
    _sec_head "[3]" "TUIC v5" "${TUIC_PORT}/udp"
    printf '  UUID : %s\n' "$TUIC_UUID"
    printf '  密码 : %s\n' "$TUIC_PASSWORD"
    _link_line "tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=${TUIC_CONGESTION}&udp_relay_mode=native&alpn=h3&sni=${sni}&allow_insecure=1#singbox-tuic"
  fi
  if enabled ss; then
    _sec_head "[4]" "Shadowsocks" "${SSR_PORT}/tcp+udp"
    printf '  加密 : %s\n' "$SSR_METHOD"
    printf '  密码 : %s\n' "$SSR_PASSWORD"
    _link_line "ss://$(b64 "${SSR_METHOD}:${SSR_PASSWORD}" | tr '+/' '-_' | tr -d '=')@${ip}:${SSR_PORT}#singbox-ss"
  fi
  if enabled vless; then
    _sec_head "[5]" "VLESS" "${VLESS_PORT}/tcp"
    printf '  UUID : %s\n' "$VLESS_UUID"
    printf '  路径 : %s\n' "$VLESS_PATH"
    _link_line "vless://${VLESS_UUID}@${ip}:${VLESS_PORT}?encryption=none&security=tls&sni=${sni}&fp=chrome&type=ws&host=${sni}&path=$(printf '%s' "$VLESS_PATH" | sed 's|/|%2F|g')&allowInsecure=1#singbox-vless"
  fi
  if enabled vmess; then
    _sec_head "[6]" "VMess" "${VMESS_PORT}/tcp"
    printf '  UUID : %s\n' "$VMESS_UUID"
    printf '  路径 : %s\n' "$VMESS_PATH"
    _link_line "vmess://$(b64 "{\"v\":\"2\",\"ps\":\"singbox-vmess\",\"add\":\"${ip}\",\"port\":\"${VMESS_PORT}\",\"id\":\"${VMESS_UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${sni}\",\"path\":\"${VMESS_PATH}\",\"tls\":\"tls\",\"sni\":\"${sni}\",\"alpn\":\"http/1.1\",\"fp\":\"chrome\",\"allowInsecure\":\"1\"}")"
  fi
  if enabled trojan; then
    _sec_head "[7]" "Trojan" "${TROJAN_PORT}/tcp"
    printf '  密码 : %s\n' "$TROJAN_PASSWORD"
    _link_line "trojan://${TROJAN_PASSWORD}@${ip}:${TROJAN_PORT}?security=tls&sni=${sni}&allowInsecure=1#singbox-trojan"
  fi
  if enabled reality; then
    _sec_head "[8]" "Reality" "${REALITY_PORT}/tcp"
    printf '  UUID : %s\n' "$REALITY_UUID"
    printf '  SNI  : %s\n' "${REALITY_DEST%%:*}"
    printf '  PBK  : %s\n' "$REALITY_PUBLIC_KEY"
    printf '  SID  : %s\n' "$REALITY_SHORT_ID"
    _link_line "vless://${REALITY_UUID}@${ip}:${REALITY_PORT}?encryption=none&security=reality&sni=${REALITY_DEST%%:*}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&flow=xtls-rprx-vision#singbox-reality"
  fi

  # ---- 客户端提示 ----
  printf '\n  %s▍客户端提示%s\n' "$C_BLD$C_YEL" "$C_RST"
  printf '  · TLS 类协议记得开 "允许不安全证书 / allowInsecure"\n'
  printf '  · Reality 无需证书, 客户端填 SNI 与公钥即可; 删掉 short_id 也能连\n'
  printf '  · Shadowsocks 客户端请选 "Shadowsocks", 不是 "ShadowsocksR"\n'
  printf '  · VLESS/VMess 走 WebSocket, 客户端传输层选 ws, 路径分别为 %s 和 %s\n' "$VLESS_PATH" "$VMESS_PATH"
  printf '  · MTPROXY 链接需在 Telegram 内打开; 443/tcp 与 443/udp 互不冲突\n'
  print_manage_block
}

validate_plan() {
  local rows=() r1 r2 n1 p1 t1 n2 p2 t2 a b
  enabled mt      && rows+=("MTPROXY|${MT_PORT}|tcp") || true
  enabled hy2     && rows+=("Hysteria2|${HY2_PORT}|udp") || true
  enabled tuic    && rows+=("TUIC|${TUIC_PORT}|udp") || true
  enabled ss      && rows+=("Shadowsocks|${SSR_PORT}|tcp udp") || true
  enabled vless   && rows+=("VLESS|${VLESS_PORT}|tcp") || true
  enabled vmess   && rows+=("VMess|${VMESS_PORT}|tcp") || true
  enabled trojan  && rows+=("Trojan|${TROJAN_PORT}|tcp") || true
  enabled reality && rows+=("Reality|${REALITY_PORT}|tcp") || true

  for r1 in "${rows[@]}"; do
    IFS='|' read -r n1 p1 t1 <<<"$r1"
    for r2 in "${rows[@]}"; do
      IFS='|' read -r n2 p2 t2 <<<"$r2"
      if [ "$n1" = "$n2" ] || [ "$p1" != "$p2" ]; then continue; fi
      # 端口相同且传输层有交集 -> sing-box 同一端口只能一个入站
      for a in $t1; do
        for b in $t2; do
          if [ "$a" = "$b" ]; then
            die "端口冲突: ${n1} 与 ${n2} 都要用 ${p1} 端口, 请用 <协议>_PORT 环境变量错开"
          fi
        done
      done
    done
  done
  ok "端口计划: mt=${MT_PORT}/tcp hy2=${HY2_PORT}/udp tuic=${TUIC_PORT}/udp ss=${SSR_PORT} vless=${VLESS_PORT} vmess=${VMESS_PORT} trojan=${TROJAN_PORT} reality=${REALITY_PORT} (仅列出, 未启用的不生效)"
}

install_self() {
  local src="$0" base
  base="$(basename "$src" 2>/dev/null || echo bash)"
  # 本地文件运行: 直接拷自己; curl | bash 时 $0 是 bash, 需要回源下载一份
  if [ -f "$src" ] && [ "$base" != "bash" ] && [ "$base" != "-bash" ] && [ "$base" != "sh" ]; then
    cp -f "$src" "$CMD_PATH" 2>/dev/null && chmod +x "$CMD_PATH" && { ok "本地命令: $CMD_PATH"; return 0; }
  fi
  info "安装本地命令 ${CMD_PATH} ..."
  if curl -fsSL --retry 2 --max-time 30 -o "${CMD_PATH}.tmp" "$SINGBOX_RAW_URL" 2>/dev/null \
     && bash -n "${CMD_PATH}.tmp" 2>/dev/null; then
    mv -f "${CMD_PATH}.tmp" "$CMD_PATH" && chmod +x "$CMD_PATH" && { ok "本地命令: $CMD_PATH"; return 0; }
  fi
  rm -f "${CMD_PATH}.tmp" 2>/dev/null || true
  warn "未能安装本地命令, 可这样管理: curl -fsSL ${SINGBOX_RAW_URL} | sudo bash -s -- info"
}

# ---- 子命令 ----
do_install() {
  echo
  printf '  %s============================================================%s\n' "$C_BLD$C_BLU" "$C_RST"
  printf '   %s sing-box 全协议服务端 · 一键部署 %s\n' "$C_BLD$C_GRN" "$C_RST"
  printf '  %s============================================================%s\n' "$C_BLD$C_BLU" "$C_RST"
  echo

  info "协议: ${PROTOCOLS}"
  detect_platform
  check_deps
  check_selinux
  validate_plan

  # 重装时先停自身, 避免端口被旧进程占用
  if service_active 2>/dev/null; then
    info "检测到 ${SERVICE_NAME} 正在运行, 先停止..."
    if [ "$INIT_SYS" = "systemd" ]; then systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    else rc-service "$SERVICE_NAME" stop 2>/dev/null || true; fi
  fi
  mkdir -p "$CONF_DIR"

  load_or_init_creds
  ok "域名 / SNI: ${DOMAIN}"
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
  # update 默认拉上游最新版; SINGBOX_TAG=钉版本 时退化为按版本修复
  detect_platform; install_binary latest; start_service; install_self
  local nver; nver=$("$BIN_PATH" version 2>/dev/null | head -1 || true)
  log "升级完成: ${nver:-未知版本}"
}

cmd_status() {
  detect_platform
  echo
  printf '  %s▍服务状态%s\n' "$C_BLD$C_YEL" "$C_RST"
  if service_active; then ok "${SERVICE_NAME}: 运行中"; else warn "${SERVICE_NAME}: 未运行"; fi
  if [ -f "$CONF_FILE" ]; then
    local p t v ports=""
    for p in $(printf '%s' "$PROTOCOLS" | tr ',' ' '); do
      t=$(tag_of "$p"); v=$(port_of_tag "$t")
      if [ -n "$v" ]; then ports="$ports $v"; fi
    done
    printf '  配置 : %s\n' "$CONF_FILE"
    printf '  监听 : %s\n' "${ports# }"
    printf '  进程 : %s\n' "$(pgrep -a -f "sing-box run -c ${CONF_FILE}" | head -1 || echo '无')"
  else
    warn "未安装 (未找到 ${CONF_FILE})"
  fi
  echo
}

cmd_info() {
  [ -f "$CONF_FILE" ] || die "未找到配置 $CONF_FILE，请先安装"
  # info 不经过 install 流程, 此处补一次平台探测, 否则"初始化系统"恒为空
  [ -n "$INIT_SYS" ] || detect_platform
  if [ -f "$CREDS_FILE" ]; then . "$CREDS_FILE"; fi
  # 端口以配置为准(环境变量未显式指定时)
  local p t v
  for p in $(printf '%s' "$PROTOCOLS" | tr ',' ' '); do
    t=$(tag_of "$p"); v=$(port_of_tag "$t")
    if [ -n "$v" ]; then printf -v "$(port_var "$p")" '%s' "$v"; fi
  done
  print_summary
}

cmd_logs() {
  local n="${1:-100}"
  # 直接调用 logs 时不经过 install 流程, 需自行探测, 否则 INIT_SYS 为空会误走文件日志分支
  [ -n "$INIT_SYS" ] || detect_platform
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
    rm -f "$SERVICE_FILE" "/var/log/${SERVICE_NAME}.log"
    ok "已移除 OpenRC 服务"
  fi
  if [ "${KEEP_CONFIG:-0}" = "1" ]; then
    warn "保留配置: $CONF_DIR"
  else
    rm -rf "$CONF_DIR"; ok "已删除 $CONF_DIR (KEEP_CONFIG=1 可保留)"
  fi
  rm -f "$CMD_PATH"
  # /usr/local/bin/sing-box 可能被其他 sing-box 服务共用, 先确认没有别的单元引用它
  local others
  others=$(grep -ls "$BIN_PATH" /etc/systemd/system/*.service /etc/init.d/* 2>/dev/null \
             | grep -v "${SERVICE_NAME}" | head -3 | tr '\n' ' ' || true)
  if [ -z "$others" ]; then
    rm -f "$BIN_PATH"; ok "已删除二进制"
  else
    warn "其他服务仍引用 ${BIN_PATH}, 保留二进制: ${others}"
  fi
  # 防火墙规则不自动删除(可能混有用户自建规则), 只给出清理命令
  local fports="" fp
  enabled mt      && fports="$fports ${MT_PORT}" || true
  enabled hy2     && fports="$fports ${HY2_PORT}/udp" || true
  enabled tuic    && fports="$fports ${TUIC_PORT}/udp" || true
  enabled ss      && fports="$fports ${SSR_PORT} ${SSR_PORT}/udp" || true
  enabled vless   && fports="$fports ${VLESS_PORT}" || true
  enabled vmess   && fports="$fports ${VMESS_PORT}" || true
  enabled trojan  && fports="$fports ${TROJAN_PORT}" || true
  enabled reality && fports="$fports ${REALITY_PORT}" || true
  if [ -n "$fports" ]; then
    if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
      warn "防火墙规则未自动删除(避免误删你自建的规则), 需要时手动执行:"
      for fp in $fports; do printf '    ufw delete allow %s\n' "$fp"; done
    elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
      warn "防火墙规则未自动删除(避免误删你自建的规则), 需要时手动执行:"
      for fp in $fports; do printf '    firewall-cmd --permanent --remove-port=%s\n' "$fp"; done
      printf '    firewall-cmd --reload\n'
    fi
  fi
  ok "卸载完成"
}

usage() {
  # 本地文件: 打印头部注释; curl|bash 时 $0 是 bash, 读不到 -> 用内置简版
  if [ -r "$0" ] && sed -n '2,38p' "$0" 2>/dev/null | grep -q 'PROTOCOLS'; then
    sed -n '2,38p' "$0"
  else
    cat <<'EOF'
singbox_all.sh — sing-box 全家桶一键部署 (mt/hy2/tuic/ss/vless/vmess/trojan/reality)

用法:
  sudo bash singbox_all.sh [install|plan|status|info|logs [N]|update|uninstall]

环境变量:
  PROTOCOLS=mt,hy2,tuic,ss,vless,vmess,trojan,reality   选择协议(逗号分隔, 默认全装)
  MT_PORT=443 HY2_PORT=443 TUIC_PORT=8443 SSR_PORT=8388
  VLESS_PORT=8989 VMESS_PORT=8990 TROJAN_PORT=8444 REALITY_PORT=8899
  DOMAIN=xxx.com                       全部 TLS 协议共用的 SNI/证书域名
  REALITY_DEST=www.microsoft.com:443   Reality 握手目标
  HY2_OBFS=xxx                         Hysteria2 salamander 混淆密码
  SINGBOX_TAG=v1.14.3-extended-2.7.3   锁定版本; 传 latest 取上游最新
  MIRROR=https://ghfast.top/           GitHub 下载镜像前缀
  CERT_FILE/KEY_FILE=...               使用已有证书
  SERVER_ADDR=1.2.3.4                  手动指定对外 IP
EOF
  fi
}

main() {
  normalize_protocols
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
