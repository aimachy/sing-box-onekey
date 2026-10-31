#!/usr/bin/env bash
# sing-box one-key server installer for denny's fleet
# - VLESS + REALITY (TCP 443) + Hysteria2 (UDP 443)
# - Binary + systemd, no Docker. BBR check/enable for the TCP path.
# Usage:
#   sudo bash install.sh            # install or re-install (keeps old creds if present)
#   sudo bash install.sh links      # print client share links again
#   sudo bash install.sh uninstall  # stop service and remove sing-box + config
# Optional env:
#   SINGBOX_VER=1.14.4 PORT=443 REALITY_SERVER=www.microsoft.com PUBLIC_IP=1.2.3.4 NODE_NAME=mynode
set -euo pipefail

SINGBOX_VER="${SINGBOX_VER:-1.14.4}"
PORT="${PORT:-443}"
REALITY_SERVER="${REALITY_SERVER:-www.microsoft.com}"
NODE_NAME="${NODE_NAME:-sing-box}"
CONF_DIR="/etc/sing-box"
CONF="$CONF_DIR/config.json"
CRED="$CONF_DIR/credentials.txt"
BIN="/usr/local/bin/sing-box"
SERVICE="sing-box"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
info() { printf '%s\n' "$*"; }

need_root() {
  if [ "$(id -u)" != "0" ]; then red "请用 root 运行： sudo bash install.sh"; exit 1; fi
}

detect_os_arch() {
  if [ -r /etc/os-release ]; then . /etc/os-release; else red "无法识别系统"; exit 1; fi
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) red "只支持 Debian / Ubuntu（当前：${ID:-unknown}）。CentOS 7 等老系统请先升级。"; exit 1 ;;
  esac
  case "$(uname -m)" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) red "不支持的架构：$(uname -m)"; exit 1 ;;
  esac
}

install_deps() {
  local pkgs="curl tar openssl ca-certificates"
  if ! command -v curl >/dev/null || ! command -v openssl >/dev/null; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs
  fi
}

enable_bbr() {
  local cur
  cur="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  if [ "$cur" = "bbr" ]; then
    grn "BBR 已开启，跳过。"
  else
    info "当前拥塞控制为 $cur，正在开启 BBR（只影响 TCP，对 REALITY 有效）..."
    modprobe tcp_bbr 2>/dev/null || true
    cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system >/dev/null 2>&1 || true
    cur="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    if [ "$cur" = "bbr" ]; then grn "BBR 开启成功。"; else red "BBR 开启失败（内核可能太老），不影响安装，继续。"; fi
  fi
}

install_binary() {
  if [ -x "$BIN" ] && [ "$("$BIN" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" = "$SINGBOX_VER" ]; then
    grn "sing-box $SINGBOX_VER 已安装，跳过下载。"
    return
  fi
  local url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/sing-box-${SINGBOX_VER}-linux-${ARCH}.tar.gz"
  local tmp
  tmp="$(mktemp -d)"
  info "下载 sing-box $SINGBOX_VER ($ARCH) ..."
  curl -fL --retry 3 -o "$tmp/sb.tar.gz" "$url"
  tar -xzf "$tmp/sb.tar.gz" -C "$tmp"
  install -m 755 "$tmp/sing-box-${SINGBOX_VER}-linux-${ARCH}/sing-box" "$BIN"
  rm -rf "$tmp"
  grn "sing-box 安装完成：$($BIN version | head -1)"
}

gen_credentials() {
  mkdir -p "$CONF_DIR"
  if [ -f "$CRED" ]; then
    info "发现已有凭据 $CRED，本次沿用（重装不换钥匙，客户端不用改）。"
    # shellcheck disable=SC1090
    . "$CRED"
    return
  fi
  UUID="$("$BIN" generate uuid)"
  local kp priv pub
  kp="$("$BIN" generate reality-keypair)"
  priv="$(printf '%s\n' "$kp" | awk '/PrivateKey/ {print $2}')"
  pub="$(printf '%s\n' "$kp" | awk '/PublicKey/ {print $2}')"
  REALITY_PRIV="$priv"
  REALITY_PUB="$pub"
  SHORT_ID="$("$BIN" generate rand --hex 8)"
  HY2_PASS="$("$BIN" generate rand --hex 16)"
  cat > "$CRED" <<EOF
UUID=$UUID
REALITY_PRIV=$REALITY_PRIV
REALITY_PUB=$REALITY_PUB
SHORT_ID=$SHORT_ID
HY2_PASS=$HY2_PASS
EOF
  chmod 600 "$CRED"
}

gen_cert() {
  if [ -f "$CONF_DIR/cert.pem" ] && [ -f "$CONF_DIR/key.pem" ]; then
    info "已有 Hy2 证书，沿用。"
    return
  fi
  info "为 Hysteria2 生成自签证书（客户端需开启 insecure/跳过验证，或后续换域名真证书）..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$CONF_DIR/key.pem" -out "$CONF_DIR/cert.pem" -days 3650 \
    -subj "/CN=${REALITY_SERVER}" \
    -addext "subjectAltName=DNS:${REALITY_SERVER}" >/dev/null 2>&1
  chmod 600 "$CONF_DIR/key.pem"
}

public_ip() {
  if [ -n "${PUBLIC_IP:-}" ]; then printf '%s' "$PUBLIC_IP"; return; fi
  local ip=""
  ip="$(curl -fs4 --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$ip" ]; then ip="$(curl -fs4 --max-time 8 https://ifconfig.me 2>/dev/null || true)"; fi
  if [ -z "$ip" ]; then ip="$(hostname -I | awk '{print $1}')"; fi
  printf '%s' "$ip"
}

check_port_free() {
  if command -v ss >/dev/null && ss -tuln | awk '{print $5}' | grep -qE "[:.]${PORT}$"; then
    if systemctl is-active --quiet "$SERVICE"; then
      info "端口 $PORT 已被 sing-box 自己占用（重装场景），继续。"
    else
      red "端口 $PORT 已被其他程序占用（多半是 Nginx/网站）。换端口重跑：PORT=8443 sudo bash install.sh，或先处理占用。"
      exit 1
    fi
  fi
}

write_config() {
  cat > "$CONF" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": $PORT,
      "users": [ { "name": "main", "uuid": "$UUID", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SERVER",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$REALITY_SERVER", "server_port": 443 },
          "private_key": "$REALITY_PRIV",
          "short_id": [ "$SHORT_ID" ]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $PORT,
      "users": [ { "name": "main", "password": "$HY2_PASS" } ],
      "tls": {
        "enabled": true,
        "alpn": [ "h3" ],
        "certificate_path": "$CONF_DIR/cert.pem",
        "key_path": "$CONF_DIR/key.pem"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" }, { "type": "block", "tag": "block" } ]
}
EOF
  "$BIN" check -c "$CONF"
}

write_service() {
  cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=$BIN run -c $CONF
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$SERVICE"
  systemctl restart "$SERVICE"
}

open_firewall() {
  if command -v ufw >/dev/null && ufw status | grep -qi "status: active"; then
    ufw allow "${PORT}/tcp" >/dev/null || true
    ufw allow "${PORT}/udp" >/dev/null || true
    grn "ufw 已放行 ${PORT}/tcp 和 ${PORT}/udp。"
  fi
  info "提醒：云厂商控制台的安全组也要放行 ${PORT}/tcp + ${PORT}/udp，脚本改不了云控制台。"
}

print_links() {
  # shellcheck disable=SC1090
  [ -f "$CRED" ] && . "$CRED"
  local ip
  ip="$(public_ip)"
  local vless="vless://${UUID}@${ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&type=tcp#${NODE_NAME}-REALITY"
  local hy2="hysteria2://${HY2_PASS}@${ip}:${PORT}?insecure=1&sni=${REALITY_SERVER}#${NODE_NAME}-Hy2"
  cat > "$CONF_DIR/client-links.txt" <<EOF
$vless
$hy2
EOF
  chmod 600 "$CONF_DIR/client-links.txt"
  echo
  grn "==== 客户端链接（导入 Hiddify / V2Box / Happ 用，勿外传）===="
  echo "VLESS+REALITY:"
  echo "$vless"
  echo "Hysteria2:"
  echo "$hy2"
  echo
  info "链接同时存在服务器 $CONF_DIR/client-links.txt（600 权限）。"
  info "Hiddify 导入：复制链接 -> App 里从剪贴板新建配置 -> 连接后允许添加 VPN 配置。"
}

uninstall() {
  need_root
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE}.service"
  systemctl daemon-reload || true
  rm -f "$BIN"
  rm -rf "$CONF_DIR"
  grn "已卸载 sing-box 并删除配置。BBR 设置保留（如需删除：rm /etc/sysctl.d/99-bbr.conf）。"
}

main() {
  case "${1:-install}" in
    links)
      need_root; print_links ;;
    uninstall)
      uninstall ;;
    install|"")
      need_root
      detect_os_arch
      install_deps
      enable_bbr
      install_binary
      gen_credentials
      gen_cert
      check_port_free
      write_config
      write_service
      open_firewall
      sleep 1
      if systemctl is-active --quiet "$SERVICE"; then grn "sing-box 已启动。"; else red "服务未正常启动，看日志：journalctl -u $SERVICE -n 50"; exit 1; fi
      print_links
      ;;
    *)
      red "未知参数：$1（可用：install | links | uninstall）"; exit 1 ;;
  esac
}

main "$@"
