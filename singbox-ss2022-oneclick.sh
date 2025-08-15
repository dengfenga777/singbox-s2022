#!/usr/bin/env bash
# singbox-ss2022-oneclick.sh (CLI interactive, fixed full version)
# 一键安装/更新 sing-box（仅 Shadowsocks 2022 入站），纯命令行交互（无弹窗）。
# - 方法选择菜单仅把“选择结果”写到 stdout（菜单文字走 stderr），避免被错误捕获
# - 生成 ss:// 与 Surge 配置片段（保存到 /etc/sing-box/surge-ss2022.conf）
# - 支持 NONINTERACTIVE=1 环境变量无人值守模式
# - 若检测到非交互执行（如 curl | bash），会提示改为下载后运行，或使用 NONINTERACTIVE 变量

set -euo pipefail
export LC_ALL=C
export LANG=C

SB_DIR="/etc/sing-box"
SB_BIN="/usr/local/bin/sing-box"
SB_SERVICE="/etc/systemd/system/sing-box.service"
LOG_DIR="/var/log/sing-box"

DEFAULT_PORT="${DEFAULT_PORT:-30001}"
DEFAULT_METHOD="${DEFAULT_METHOD:-2022-blake3-aes-256-gcm}"
DEFAULT_LISTEN="${DEFAULT_LISTEN:-::}"

color() { echo -e "\033[$1m$2\033[0m"; }
ok() { color "32" "✓ $1"; }
warn() { color "33" "⚠ $1"; }
err() { color "31" "✗ $1"; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    err "请使用 root 运行（sudo -i）"
    exit 1
  fi
}

detect_pkg() {
  if command -v apt-get >/dev/null 2>&1; then PKG=apt; INSTALL="apt-get update && apt-get install -y"
  elif command -v dnf >/dev/null 2>&1; then PKG=dnf; INSTALL="dnf install -y"
  elif command -v yum >/dev/null 2>&1; then PKG=yum; INSTALL="yum install -y"
  else PKG=unknown; fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) err "暂不支持的架构: $(uname -m)"; exit 1 ;;
  esac
}

install_deps() {
  if [[ "$PKG" == "unknown" ]]; then
    warn "未检测到包管理器，将尝试仅使用静态下载方式（需要 curl、tar、jq、openssl）"
  else
    eval "$INSTALL curl tar jq openssl"
  fi
}

fetch_latest_singbox() {
  local fallback_tag="v1.12.1"
  local tag
  tag="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name || true)"
  if [[ -z "${tag:-}" || "${tag}" == "null" ]]; then
    warn "获取最新版本失败，使用回退版本 ${fallback_tag}"
    tag="$fallback_tag"
  fi
  SB_VER="$tag"
  SB_TARBALL="sing-box-${SB_VER#v}-linux-${ARCH}.tar.gz"
  SB_URL="https://github.com/SagerNet/sing-box/releases/download/${SB_VER}/${SB_TARBALL}"
}

install_singbox() {
  mkdir -p "$SB_DIR" "$LOG_DIR"
  local tmpdir; tmpdir="$(mktemp -d)"
  pushd "$tmpdir" >/dev/null
  curl -fL "$SB_URL" -o "$SB_TARBALL"
  tar zxf "$SB_TARBALL"
  install -m 0755 "sing-box-${SB_VER#v}-linux-${ARCH}/sing-box" "$SB_BIN"
  popd >/dev/null
  rm -rf "$tmpdir"
  ok "sing-box 安装完成：$($SB_BIN version | head -n 1 || true)"
}

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p>=1 && p<=65535 ))
}

gen_password() {
  local method="$1"
  case "$method" in
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) openssl rand -base64 32 ;;
    2022-blake3-aes-128-gcm) openssl rand -base64 16 ;;
    *) echo "";;
  esac
}

read_with_default() {
  local v
  read -r -p "$1 [$2]: " v || true
  echo "${v:-$2}"
}

choose_method_cli() {
  { echo "请选择 Shadowsocks 2022 方法:"
    echo "  1) 2022-blake3-aes-256-gcm   (默认)"
    echo "  2) 2022-blake3-chacha20-poly1305"
    echo "  3) 2022-blake3-aes-128-gcm"
  } >&2
  local n
  read -r -p "输入序号 [1]: " n >&2 || true
  case "${n:-1}" in
    1) echo "2022-blake3-aes-256-gcm" ;;
    2) echo "2022-blake3-chacha20-poly1305" ;;
    3) echo "2022-blake3-aes-128-gcm" ;;
    *) echo "2022-blake3-aes-256-gcm" ;;
  esac
}

collect_inputs() {
  echo "=== SS2022 配置 ==="
  unset METHOD
  METHOD="$(choose_method_cli)"

  PORT="${PORT:-}"
  while [[ -z "${PORT:-}" ]]; do
    PORT="$(read_with_default '设置端口(1-65535)' "$DEFAULT_PORT")"
    if ! validate_port "$PORT"; then
      echo "无效端口：$PORT"
      PORT=""
    fi
  done

  LISTEN_ADDR="${LISTEN_ADDR:-}"
  LISTEN_ADDR="$(read_with_default '监听地址(:: / 0.0.0.0 / 127.0.0.1)' "$DEFAULT_LISTEN")"

  if [[ -z "${PASSWORD:-}" ]]; then
    read -r -p "是否手动输入 base64 密钥？(y/N): " a || true
    if [[ "${a,,}" =~ ^y(es)?$ ]]; then
      while true; do
        read -r -p "请输入 base64 密钥: " PASSWORD || true
        [[ -n "${PASSWORD// /}" ]] && break
        echo "密钥不能为空"
      done
    else
      PASSWORD="$(gen_password "$METHOD")"
    fi
  fi

  echo "---------------------------"
  echo "方法 : $METHOD"
  echo "端口 : $PORT"
  echo "监听 : $LISTEN_ADDR"
  echo "密钥 : $PASSWORD (base64)"
  echo "---------------------------"
  read -r -p "确认开始安装？(Y/n): " okgo || true
  if [[ "${okgo,,}" == "n" ]]; then
    echo "已取消"
    exit 0
  fi
}

write_config() {
  cat > "$SB_DIR/config.json" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss2022-in",
      "listen": "${LISTEN_ADDR}",
      "listen_port": ${PORT},
      "method": "${METHOD}",
      "password": "${PASSWORD}"
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ]
}
EOF
  ok "已写入配置：$SB_DIR/config.json"
}

write_service() {
  cat > "$SB_SERVICE" <<EOF
[Unit]
Description=sing-box (SS2022) Service
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${SB_BIN} run -c ${SB_DIR}/config.json
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now sing-box
  sleep 0.5
  systemctl restart sing-box || true
  systemctl status sing-box --no-pager -l || true
}

print_summary() {
  if [[ -z "${METHOD:-}" || -z "${PASSWORD:-}" || -z "${PORT:-}" ]]; then
    err "生成信息失败：METHOD/PORT/PASSWORD 存在空值"
    exit 1
  fi
  local ip
  ip="$(curl -fsSL https://api.ipify.org || echo "<你的服务器IP>")"
  local surge_line="Proxy = ss, ${ip}, ${PORT}, encrypt-method=${METHOD}, password=${PASSWORD}, udp-relay=true"
  mkdir -p "$SB_DIR"
  echo "$surge_line" > "$SB_DIR/surge-ss2022.conf"

  echo
  echo "=========== SS2022 节点信息 ==========="
  echo "服务器: ${ip}"
  echo "端口:   ${PORT}"
  echo "方法:   ${METHOD}"
  echo "密钥:   ${PASSWORD} (base64)"
  echo
  echo "URI:"
  echo "ss://${METHOD}:${PASSWORD}@${ip}:${PORT}#ss2022-${ip}-${PORT}"
  echo
  echo "[Surge]"
  echo "${surge_line}"
  echo "(已保存到 $SB_DIR/surge-ss2022.conf)"
  echo "======================================"
}

uninstall() {
  systemctl stop sing-box 2>/dev/null || true
  systemctl disable sing-box 2>/dev/null || true
  rm -f "$SB_SERVICE"
  systemctl daemon-reload || true
  rm -f "$SB_BIN"
  rm -rf "$SB_DIR"
  ok "已卸载 sing-box 与相关配置"
}

main_menu() {
  echo "====== 选择操作 ======"
  echo "  1) 安装/更新 sing-box (SS2022)"
  echo "  2) 卸载 sing-box 与配置"
  echo "  3) 退出"
  local n
  read -r -p "输入序号 [1]: " n || true
  case "${n:-1}" in
    1) ACTION="install" ;;
    2) ACTION="uninstall" ;;
    *) ACTION="quit" ;;
  esac
}

main() {
  need_root
  detect_pkg
  detect_arch
  install_deps

  # 如果是非交互（stdin 非 TTY）且未开启无人值守，就提示改为下载再运行
  if [[ ! -t 0 && "${NONINTERACTIVE:-0}" != "1" ]]; then
    warn "检测到非交互执行（例如 curl | bash）。请先下载到本地再运行：
  curl -fsSLo /usr/local/bin/sb2022.sh \"https://raw.githubusercontent.com/dengfenga777/singbox-s2022/main/singbox-ss2022-oneclick.sh\"
  chmod +x /usr/local/bin/sb2022.sh
  sudo /usr/local/bin/sb2022.sh
或使用无人值守：
  sudo NONINTERACTIVE=1 PORT=30001 METHOD=2022-blake3-aes-256-gcm LISTEN_ADDR=:: bash /usr/local/bin/sb2022.sh"
    exit 2
  fi

  main_menu
  case "${ACTION:-install}" in
    install)
      collect_inputs
      fetch_latest_singbox
      install_singbox
      write_config
      write_service
      print_summary
      ok "完成 ✅"
      ;;
    uninstall)
      uninstall
      ;;
    *)
      echo "已退出"
      ;;
  esac
}

# 无人值守模式：提供必要变量即可
if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
  need_root; detect_pkg; detect_arch; install_deps
  : "${PORT:?需要 PORT}"
  : "${METHOD:?需要 METHOD}"
  : "${LISTEN_ADDR:=::}"
  if [[ -z "${PASSWORD:-}" ]]; then PASSWORD="$(gen_password "$METHOD")"; fi
  fetch_latest_singbox; install_singbox; write_config; write_service; print_summary; ok "完成 ✅"; exit 0
fi

main "$@"
