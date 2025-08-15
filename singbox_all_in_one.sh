#!/usr/bin/env bash
# sing-box 多协议一键：安装 + 配置 + 流量统计 + 每日记录清零 + 月度归档（无 SOCKS/HTTP 入站）
# 兼容 Debian/Ubuntu/CentOS/Rocky/Alma (systemd)

set -euo pipefail

# ===== 全局配置 =====
SB_USER="${SB_USER:-sing-box}"
SB_DIR="${SB_DIR:-/etc/sing-box}"
SB_BIN="${SB_BIN:-/usr/local/bin/sing-box}"
SB_CFG="$SB_DIR/config.json"
SERVICE="/etc/systemd/system/sing-box.service"
LOG_FILE="/var/log/singbox-traffic.log"
API_LISTEN="${API_LISTEN:-127.0.0.1:9090}"

# ===== 协议开关 =====
ENABLE_SS_AEAD="${ENABLE_SS_AEAD:-1}"
ENABLE_SS_2022="${ENABLE_SS_2022:-1}"
ENABLE_VMESS="${ENABLE_VMESS:-1}"
ENABLE_VLESS_PLAIN="${ENABLE_VLESS_PLAIN:-1}"
ENABLE_TROJAN="${ENABLE_TROJAN:-0}"
ENABLE_HYSTERIA2="${ENABLE_HYSTERIA2:-0}"
ENABLE_TUIC="${ENABLE_TUIC:-0}"

# ===== 端口与凭据 =====
PORT_SS_AEAD="${PORT_SS_AEAD:-10086}"
SS_AEAD_METHOD="${SS_AEAD_METHOD:-chacha20-ietf-poly1305}"
SS_AEAD_PASSWORD="${SS_AEAD_PASSWORD:-$(openssl rand -base64 16 | tr '+/' '-_' | tr -d '=')}"

PORT_SS_2022="${PORT_SS_2022:-40000}"
SS2022_METHOD="${SS2022_METHOD:-2022-blake3-aes-128-gcm}"
case "$SS2022_METHOD" in
  2022-blake3-aes-128-gcm) SS2022_KEYLEN=16;;
  2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) SS2022_KEYLEN=32;;
  *) echo "[ERR] Unsupported SS2022 method"; exit 1;;
esac
SS2022_PASSWORD="${SS2022_PASSWORD:-$(openssl rand $SS2022_KEYLEN | base64 | tr '+/' '-_' | tr -d '=')}"

PORT_VMESS="${PORT_VMESS:-20001}"
VMESS_USER_ID="${VMESS_USER_ID:-$(uuidgen)}"
VMESS_ALTERID="${VMESS_ALTERID:-0}"

PORT_VLESS_PLAIN="${PORT_VLESS_PLAIN:-20002}"
VLESS_USER_ID="${VLESS_USER_ID:-$(uuidgen)}"

PORT_TROJAN="${PORT_TROJAN:-443}"
TROJAN_PASSWORD="${TROJAN_PASSWORD:-$(openssl rand -hex 16)}"
TLS_CERT_PATH="${TLS_CERT_PATH:-/etc/ssl/certs/fullchain.pem}"
TLS_KEY_PATH="${TLS_KEY_PATH:-/etc/ssl/private/privkey.pem}"

PORT_HYSTERIA2="${PORT_HYSTERIA2:-8443}"
HY2_PASSWORD="${HY2_PASSWORD:-$(openssl rand -hex 16)}"
HY2_OBFS="${HY2_OBFS:-}"
HY2_CERT_PATH="${HY2_CERT_PATH:-$TLS_CERT_PATH}"
HY2_KEY_PATH="${HY2_KEY_PATH:-$TLS_KEY_PATH}"

PORT_TUIC="${PORT_TUIC:-10443}"
TUIC_UUID="${TUIC_UUID:-$(uuidgen)}"
TUIC_PASSWORD="${TUIC_PASSWORD:-$(openssl rand -hex 16)}"
TUIC_CERT_PATH="${TUIC_CERT_PATH:-$TLS_CERT_PATH}"
TUIC_KEY_PATH="${TUIC_KEY_PATH:-$TLS_KEY_PATH}"

# ===== 工具函数 =====
ok(){ echo -e "\e[32m[OK]\e[0m $*"; }
err(){ echo -e "\e[31m[ERR]\e[0m $*" >&2; }
need_root(){ [[ $EUID -ne 0 ]] && err "Run as root" && exit 1; }

detect_pkg(){
  if command -v apt-get >/dev/null; then INSTALL="apt-get update && apt-get install -y";
  elif command -v yum >/dev/null; then INSTALL="yum install -y";
  elif command -v dnf >/dev/null; then INSTALL="dnf install -y";
  else err "Unsupported package manager"; exit 1; fi
}
install_deps(){ eval "$INSTALL curl tar unzip jq socat >/dev/null"; }
arch_map(){
  case "$(uname -m)" in
    x86_64|amd64) echo amd64;;
    aarch64|arm64) echo arm64;;
    armv7l|armv7) echo armv7;;
    i386|i686) echo 386;;
    *) err "Unsupported arch"; exit 1;;
  esac
}
latest_version(){ curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name; }
dl_singbox(){
  local ver="$1" arch="$2" name="sing-box-${ver}-linux-${arch}"
  curl -fL "https://github.com/SagerNet/sing-box/releases/download/${ver}/${name}.tar.gz" -o /tmp/sb.tgz
  tar -xzf /tmp/sb.tgz -C /tmp
  install -m 0755 "/tmp/${name}/sing-box" "$SB_BIN"
}
ensure_user(){
  id -u "$SB_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$SB_USER"
  mkdir -p "$SB_DIR"
  chown -R "$SB_USER:$SB_USER" "$SB_DIR"
}
fw_open(){
  open_port(){ local p="$1";
    if command -v ufw >/dev/null; then ufw allow "$p"/tcp || true; ufw allow "$p"/udp || true;
    elif command -v firewall-cmd >/dev/null; then firewall-cmd --add-port="$p"/tcp --permanent || true; firewall-cmd --add-port="$p"/udp --permanent || true; firewall-cmd --reload || true;
    else iptables -I INPUT -p tcp --dport "$p" -j ACCEPT || true; iptables -I INPUT -p udp --dport "$p" -j ACCEPT || true; fi
  }
  for P in $PORT_SS_AEAD $PORT_SS_2022 $PORT_VMESS $PORT_VLESS_PLAIN $PORT_TROJAN $PORT_HYSTERIA2 $PORT_TUIC; do open_port "$P"; done
}
# ===== 写配置 =====
CFG_START(){
cat > "$SB_CFG" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
EOF
}
CFG_END(){
cat >> "$SB_CFG" <<EOF
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "experimental": {
    "statistics": { "enabled": true },
    "api": { "enabled": true, "listen": "$API_LISTEN" }
  }
}
EOF
  chown "$SB_USER:$SB_USER" "$SB_CFG"
  chmod 640 "$SB_CFG"
}
add_ss_aead(){
cat >> "$SB_CFG" <<EOF
    { "type": "shadowsocks", "tag": "in-ss-aead", "listen": "::", "listen_port": $PORT_SS_AEAD,
      "method": "$SS_AEAD_METHOD", "password": "$SS_AEAD_PASSWORD", "network": "tcp,udp",
      "statistics": { "inbound": true } }
EOF
}
add_ss_2022(){
cat >> "$SB_CFG" <<EOF
    { "type": "shadowsocks", "tag": "in-ss2022", "listen": "::", "listen_port": $PORT_SS_2022,
      "method": "$SS2022_METHOD", "password": "$SS2022_PASSWORD", "network": "tcp,udp",
      "statistics": { "inbound": true } }
EOF
}
add_vmess(){
cat >> "$SB_CFG" <<EOF
    { "type": "vmess", "tag": "in-vmess", "listen": "::", "listen_port": $PORT_VMESS,
      "users": [ { "uuid": "$VMESS_USER_ID", "alterId": $VMESS_ALTERID } ],
      "transport": { "type": "tcp" }, "statistics": { "inbound": true } }
EOF
}
add_vless_plain(){
cat >> "$SB_CFG" <<EOF
    { "type": "vless", "tag": "in-vless-plain", "listen": "::", "listen_port": $PORT_VLESS_PLAIN,
      "users": [ { "uuid": "$VLESS_USER_ID" } ], "transport": { "type": "tcp" },
      "decryption": "none", "statistics": { "inbound": true } }
EOF
}
# ===== systemd 服务 =====
write_service(){
cat > "$SERVICE" <<EOF
[Unit]
Description=sing-box Service
After=network-online.target
[Service]
User=$SB_USER
Group=$SB_USER
ExecStart=$SB_BIN run -c $SB_CFG
Restart=on-failure
LimitNOFILE=51200
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now sing-box
}
# ===== 流量统计工具 =====
install_traffic_tools(){
  cat > /usr/local/bin/ss2022-traffic <<'EOT'
#!/bin/bash
API_URL="http://127.0.0.1:9090"
curl -s "$API_URL/stats/inbounds" | jq -r '.inbounds[] | "\(.tag): 上行=\(.uplink/1048576|floor)MB 下行=\(.downlink/1048576|floor)MB 总计=\((.uplink+.downlink)/1048576|floor)MB"'
EOT
  chmod +x /usr/local/bin/ss2022-traffic
}
# ===== 主程序 =====
main(){
  need_root
  detect_pkg
  install_deps
  VER=$(latest_version)
  ARCH=$(arch_map)
  dl_singbox "$VER" "$ARCH"
  ensure_user
  CFG_START
  first=1
  [[ $ENABLE_SS_AEAD -eq 1 ]] && [[ $first -eq 0 ]] && echo , >>"$SB_CFG" || true; [[ $ENABLE_SS_AEAD -eq 1 ]] && add_ss_aead && first=0
  [[ $ENABLE_SS_2022 -eq 1 ]] && [[ $first -eq 0 ]] && echo , >>"$SB_CFG" || true; [[ $ENABLE_SS_2022 -eq 1 ]] && add_ss_2022 && first=0
  [[ $ENABLE_VMESS -eq 1 ]] && [[ $first -eq 0 ]] && echo , >>"$SB_CFG" || true; [[ $ENABLE_VMESS -eq 1 ]] && add_vmess && first=0
  [[ $ENABLE_VLESS_PLAIN -eq 1 ]] && [[ $first -eq 0 ]] && echo , >>"$SB_CFG" || true; [[ $ENABLE_VLESS_PLAIN -eq 1 ]] && add_vless_plain && first=0
  CFG_END
  write_service
  fw_open
  install_traffic_tools
  ok "安装完成"
}
main "$@"
