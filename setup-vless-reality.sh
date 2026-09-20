#!/usr/bin/env bash
set -Eeuo pipefail

# One-click VLESS + Reality (Vision) installer.
# Run as root on a fresh Ubuntu/Debian/RHEL-like server.
# Optional environment overrides (useful for automation):
#   DOMAIN=example.com NODE_NAME=MyNode SNI=m.media-amazon.com bash setup-vless-reality.sh

DOMAIN="${DOMAIN:-}"
NODE_NAME="${NODE_NAME:-}"
SNI="${SNI:-}"
XRAY_PORT="${XRAY_PORT:-443}"
SUB_PORT="${SUB_PORT:-8443}"
EMAIL="${EMAIL:-}"
INSTALL_SUBSCRIPTION_SERVER="${INSTALL_SUBSCRIPTION_SERVER:-1}"

XRAY_DIR="/usr/local/etc/xray"
STATE_DIR="/var/lib/xray-vless-reality"
SUB_DIR="/var/lib/xray-subscription"
SUB_TOKEN_FILE="${STATE_DIR}/subscription_token"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die() { printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

prompt_required() {
  local var_name="$1" prompt="$2" current="$3" value
  if [[ -n "$current" ]]; then
    value="$current"
  else
    [[ -t 0 ]] || die "缺少交互输入：${prompt}。也可以通过环境变量传入。"
    read -r -p "${prompt}: " value || die "读取输入失败。"
  fi
  [[ -n "$value" ]] || die "输入不能为空：${prompt}。"
  printf -v "$var_name" '%s' "$value"
}

prompt_default() {
  local var_name="$1" prompt="$2" current="$3" default_value="$4" value
  if [[ -n "$current" ]]; then
    value="$current"
  elif [[ -t 0 ]]; then
    read -r -p "${prompt} [${default_value}]: " value || die "读取输入失败。"
    value="${value:-$default_value}"
  else
    value="$default_value"
  fi
  printf -v "$var_name" '%s' "$value"
}

prompt_required DOMAIN "服务器域名（已解析到本机 IP）" "$DOMAIN"
prompt_default NODE_NAME "节点名称" "$NODE_NAME" "VLESS-Reality-Vision"
prompt_default SNI "Reality SNI" "$SNI" "m.media-amazon.com"

[[ "$NODE_NAME" != *$'\n'* && "$NODE_NAME" != *$'\r'* ]] || die "节点名称不能包含换行。"
[[ "${#NODE_NAME}" -le 100 ]] || die "节点名称不能超过 100 个字符。"

[[ "${EUID}" -eq 0 ]] || die "请以 root 身份运行此脚本。"
command -v systemctl >/dev/null 2>&1 || die "需要 systemd。"

valid_host() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
  [[ "$1" != *..* ]]
}
valid_host "$DOMAIN" || die "DOMAIN 不是有效域名：${DOMAIN}"
valid_host "$SNI" || die "SNI 不是有效域名：${SNI}"
[[ "$XRAY_PORT" =~ ^[0-9]+$ && "$XRAY_PORT" -ge 1 && "$XRAY_PORT" -le 65535 ]] || die "XRAY_PORT 无效。"
[[ "$SUB_PORT" =~ ^[0-9]+$ && "$SUB_PORT" -ge 1 && "$SUB_PORT" -le 65535 ]] || die "SUB_PORT 无效。"

umask 077
export DEBIAN_FRONTEND=noninteractive

detect_pkg() {
  if command -v apt-get >/dev/null 2>&1; then echo apt; return; fi
  if command -v dnf >/dev/null 2>&1; then echo dnf; return; fi
  if command -v yum >/dev/null 2>&1; then echo yum; return; fi
  die "未识别的发行版，请使用 Debian/Ubuntu/RHEL 系列系统。"
}
PKG="$(detect_pkg)"

install_packages() {
  log "安装基础依赖"
  case "$PKG" in
    apt)
      apt-get update -y
      apt-get install -y --no-install-recommends ca-certificates curl openssl jq unzip iproute2 procps
      ;;
    dnf)
      dnf install -y ca-certificates curl openssl jq unzip iproute procps-ng
      ;;
    yum)
      yum install -y ca-certificates curl openssl jq unzip iproute procps-ng
      ;;
  esac
}

install_packages
mkdir -p "$XRAY_DIR" "$STATE_DIR" "$SUB_DIR"
chmod 700 "$XRAY_DIR" "$STATE_DIR" "$SUB_DIR"

install_xray() {
  if command -v xray >/dev/null 2>&1; then
    log "检测到已有 Xray：$(xray version 2>/dev/null | head -1 || true)"
    return
  fi
  log "安装 Xray（官方安装脚本）"
  local installer
  installer="$(mktemp)"
  curl -fsSL --retry 3 --proto '=https' --tlsv1.2 \
    https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$installer"
  bash "$installer" install
  rm -f "$installer"
  command -v xray >/dev/null 2>&1 || die "Xray 安装失败。"
}
install_xray

log "生成 Reality 密钥、UUID 和 shortId"
UUID="$(cat /proc/sys/kernel/random/uuid)"
SHORT_ID="$(openssl rand -hex 8)"
KEY_OUTPUT="$(xray x25519 2>/dev/null)" || die "无法生成 Reality 密钥。"
PRIVATE_KEY="$(printf '%s\n' "$KEY_OUTPUT" | awk -F': ' '/Private key:/ {print $2; exit}')"
PUBLIC_KEY="$(printf '%s\n' "$KEY_OUTPUT" | awk -F': ' '/Public key:/ {print $2; exit}')"
[[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || die "Reality 密钥解析失败。"

cat >"${STATE_DIR}/node.env" <<EOF
DOMAIN=${DOMAIN}
NODE_NAME=${NODE_NAME}
SNI=${SNI}
XRAY_PORT=${XRAY_PORT}
SUB_PORT=${SUB_PORT}
UUID=${UUID}
SHORT_ID=${SHORT_ID}
PUBLIC_KEY=${PUBLIC_KEY}
EOF
chmod 600 "${STATE_DIR}/node.env"

log "写入 Xray 配置"
cat >"${XRAY_DIR}/config.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {"id": "${UUID}", "flow": "xtls-rprx-vision"}
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": ["${SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "blocked"}
  ]
}
EOF
chmod 600 "${XRAY_DIR}/config.json"
xray run -test -config "${XRAY_DIR}/config.json" >/dev/null || die "Xray 配置校验失败。"

log "应用网络与文件句柄优化"
cat >/etc/sysctl.d/99-xray-reality.conf <<'EOF'
fs.file-max = 1000000
net.core.default_qdisc = fq
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
EOF
sysctl --system >/dev/null 2>&1 || true
if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
  sed -i '/tcp_congestion_control = bbr/d' /etc/sysctl.d/99-xray-reality.conf
  sysctl --system >/dev/null 2>&1 || true
fi

mkdir -p /etc/systemd/system/xray.service.d
cat >/etc/systemd/system/xray.service.d/override.conf <<'EOF'
[Service]
LimitNOFILE=1048576
TasksMax=infinity
Restart=on-failure
RestartSec=2s
EOF
systemctl daemon-reload
systemctl enable --now xray
systemctl restart xray
sleep 1
systemctl is-active --quiet xray || { journalctl -u xray --no-pager -n 50; die "Xray 启动失败。"; }

open_firewall() {
  log "开放必要端口"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q active; then
    ufw allow "${XRAY_PORT}/tcp" >/dev/null
    [[ "$INSTALL_SUBSCRIPTION_SERVER" == 1 ]] && ufw allow 80/tcp >/dev/null || true
    [[ "$INSTALL_SUBSCRIPTION_SERVER" == 1 ]] && ufw allow "${SUB_PORT}/tcp" >/dev/null || true
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${XRAY_PORT}/tcp" >/dev/null
    [[ "$INSTALL_SUBSCRIPTION_SERVER" == 1 ]] && firewall-cmd --permanent --add-port=80/tcp >/dev/null || true
    [[ "$INSTALL_SUBSCRIPTION_SERVER" == 1 ]] && firewall-cmd --permanent --add-port="${SUB_PORT}/tcp" >/dev/null || true
    firewall-cmd --reload >/dev/null
  fi
}
open_firewall

NODE_NAME_JSON="$(jq -n --arg value "$NODE_NAME" '$value')"
NODE_NAME_URI="$(jq -nr --arg value "$NODE_NAME" '$value|@uri')"
VLESS_URI="vless://${UUID}@${DOMAIN}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${NODE_NAME_URI}"
printf '%s\n' "$VLESS_URI" >"${SUB_DIR}/vless.txt"
printf '%s' "$VLESS_URI" | base64 | tr -d '\n' >"${SUB_DIR}/vless.base64"

cat >"${SUB_DIR}/clash.yaml" <<EOF
proxies:
  - name: ${NODE_NAME_JSON}
    type: vless
    server: ${DOMAIN}
    port: ${XRAY_PORT}
    uuid: ${UUID}
    udp: true
    tls: true
    servername: ${SNI}
    flow: xtls-rprx-vision
    network: tcp
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
    client-fingerprint: chrome
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - ${NODE_NAME_JSON}
      - DIRECT
rules:
  - MATCH,PROXY
EOF
chmod 600 "${SUB_DIR}/"*

setup_https_subscription() {
  [[ "$INSTALL_SUBSCRIPTION_SERVER" == 1 ]] || return 0
  command -v nginx >/dev/null 2>&1 || {
    case "$PKG" in
      apt) apt-get install -y --no-install-recommends nginx certbot ;;
      dnf|yum) "$PKG" install -y nginx certbot ;;
    esac
  }
  command -v nginx >/dev/null 2>&1 || { warn "无法安装 nginx，跳过公网订阅地址。"; return 0; }
  command -v certbot >/dev/null 2>&1 || { warn "无法安装 certbot，跳过公网订阅地址。"; return 0; }

  SUB_TOKEN="$(openssl rand -hex 16)"
  printf '%s\n' "$SUB_TOKEN" >"$SUB_TOKEN_FILE"
  chmod 600 "$SUB_TOKEN_FILE"
  mkdir -p "${SUB_DIR}/${SUB_TOKEN}"
  cp "${SUB_DIR}/vless.base64" "${SUB_DIR}/${SUB_TOKEN}/vless.txt"
  cp "${SUB_DIR}/clash.yaml" "${SUB_DIR}/${SUB_TOKEN}/clash.yaml"
  chmod 600 "${SUB_DIR}/${SUB_TOKEN}"/*

  mkdir -p /var/www/acme
  systemctl stop nginx 2>/dev/null || true
  local cert_args=(certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$DOMAIN")
  [[ -n "$EMAIL" ]] && cert_args=(certonly --standalone --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN")
  if ! certbot "${cert_args[@]}"; then
    warn "Let's Encrypt 证书申请失败；保留本地文件，不启用公网订阅。请确认 DNS 已解析且 80/tcp 可访问。"
    systemctl start nginx 2>/dev/null || true
    return 0
  fi

  cat >/etc/nginx/conf.d/xray-subscription.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    location ^~ /.well-known/acme-challenge/ { root /var/www/acme; }
    location / { return 301 https://\$host:${SUB_PORT}\$request_uri; }
}
server {
    listen ${SUB_PORT} ssl;
    server_name ${DOMAIN};
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    location = /${SUB_TOKEN}/vless.txt {
        default_type text/plain;
        alias ${SUB_DIR}/${SUB_TOKEN}/vless.txt;
        add_header Cache-Control "no-store";
    }
    location = /${SUB_TOKEN}/clash.yaml {
        default_type text/yaml;
        alias ${SUB_DIR}/${SUB_TOKEN}/clash.yaml;
        add_header Cache-Control "no-store";
    }
    location / { return 404; }
}
EOF
  if ! nginx -t; then
    warn "nginx 配置校验失败，跳过公网订阅。"
    systemctl start nginx 2>/dev/null || true
    return 0
  fi
  systemctl enable --now nginx
  systemctl reload nginx
  cat >"${STATE_DIR}/subscription_urls" <<EOF
Base64/VLESS 订阅（Clash Meta）：https://${DOMAIN}:${SUB_PORT}/${SUB_TOKEN}/vless.txt
Clash YAML 配置：https://${DOMAIN}:${SUB_PORT}/${SUB_TOKEN}/clash.yaml
EOF
  chmod 600 "${STATE_DIR}/subscription_urls"
}
setup_https_subscription

log "部署完成"
printf '\n节点参数（请妥善保存）：\n'
printf '  名称: %s\n  地址: %s\n  端口: %s\n  UUID: %s\n  SNI: %s\n  PublicKey: %s\n  ShortID: %s\n  Flow: xtls-rprx-vision\n' "$NODE_NAME" "$DOMAIN" "$XRAY_PORT" "$UUID" "$SNI" "$PUBLIC_KEY" "$SHORT_ID"
printf '\nVLESS 链接：\n%s\n' "$VLESS_URI"
printf '\nClash YAML 文件：%s\nBase64 订阅内容：%s\n' "${SUB_DIR}/clash.yaml" "${SUB_DIR}/vless.base64"
if [[ -f "${STATE_DIR}/subscription_urls" ]]; then
  printf '\nHTTPS 订阅地址：\n'
  cat "${STATE_DIR}/subscription_urls"
else
  printf '\n未启用公网 HTTPS 订阅；可将上述文件上传到你信任的 HTTPS 静态文件服务。\n'
fi
printf '\n服务状态：\n'
systemctl --no-pager --full status xray | sed -n '1,8p'
