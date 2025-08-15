#!/usr/bin/env bash
# singbox-ss2022-oneclick.sh (interactive)
# 功能：一键安装/更新 sing-box，仅启用 Shadowsocks 2022 入站；用 whiptail 弹窗交互选择端口/方法/密钥/监听地址
# 适配：Debian/Ubuntu/CentOS/Alma/Rocky；x86_64 / aarch64；需要 TTY（SSH 终端）
# 作者提示：如未安装 whiptail，将自动尝试安装（fallback: dialog）

set -euo pipefail

SB_DIR="/etc/sing-box"
SB_BIN="/usr/local/bin/sing-box"
SB_SERVICE="/etc/systemd/system/sing-box.service"
LOG_DIR="/var/log/sing-box"

default_port=30001
default_method="2022-blake3-aes-256-gcm"
default_listen="::"

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

need_tty() {
  if [[ ! -t 1 ]]; then
    err "需要在交互式终端中运行（TTY）。请直接在 SSH 里执行本脚本。"
    exit 1
  fi
}

detect_pkg() {
  if command -v apt-get >/dev/null 2>&1; then PKG=apt; INSTALL="apt-get update && apt-get install -y"
  elif command -v dnf >/dev/null 2>&1; then PKG=dnf; INSTALL="dnf install -y"
  elif command -v yum >/dev/null 2>&1; then PKG=yum; INSTALL="yum install -y"
  else PKG=unknown; fi
}

install_ui() {
  if command -v whiptail >/dev/null 2>&1; then UI="whiptail"; return; fi
  if command -v dialog >/dev/null 2>&1;  then UI="dialog"; return; fi
  if [[ "$PKG" == "unknown" ]]; then
    warn "未检测到包管理器，无法自动安装 whiptail/dialog。将尝试以纯文本 fallback。"
    UI=""
    return
  fi
  # 优先 whiptail
  set +e
  eval "$INSTALL whiptail" >/dev/null 2>&1
  if command -v whiptail >/dev/null 2>&1; then UI="whiptail"; set -e; return; fi
  eval "$INSTALL dialog" >/dev/null 2>&1
  if command -v dialog   >/dev/null 2>&1; then UI="dialog"; set -e; return; fi
  set -e
  warn "whiptail / dialog 安装失败，将使用纯文本交互。"
  UI=""
}

ui_menu() {
  # $1 title, $2 text, rest pairs tag item
  if [[ "$UI" == "whiptail" ]]; then
    whiptail --clear --title "$1" --menu "$2" 20 70 10 "${@:3}" 3>&1 1>&2 2>&3
  elif [[ "$UI" == "dialog" ]]; then
    dialog --clear --title "$1" --menu "$2" 20 70 10 "${@:3}" 3>&1 1>&2 2>&3
  else
    # text fallback: print options and read
    echo -e "\n== $1 ==\n$2"
    local i=3; local idx=1; local opt; declare -a tags
    while [[ $i -le $# ]]; do
      opt="${!i}"; i=$((i+1)); # tag
      echo " [$idx] ${opt} - ${!i}"; i=$((i+1)); # item
      tags+=("$opt")
      idx=$((idx+1))
    done
    read -rp "选择序号: " n
    echo "${tags[$((n-1))]}"
  fi
}

ui_input() {
  # $1 title, $2 text, $3 default
  if [[ "$UI" == "whiptail" ]]; then
    whiptail --clear --title "$1" --inputbox "$2" 10 70 "$3" 3>&1 1>&2 2>&3
  elif [[ "$UI" == "dialog" ]]; then
    dialog --clear --title "$1" --inputbox "$2" 10 70 "$3" 3>&1 1>&2 2>&3
  else
    echo -e "\n== $1 ==\n$2（默认: $3）"
    read -rp "> " v; echo "${v:-$3}"
  fi
}

ui_yesno() {
  # $1 title, $2 text -> 0 yes, 1 no
  if [[ "$UI" == "whiptail" ]]; then
    if whiptail --clear --title "$1" --yesno "$2" 10 70; then return 0; else return 1; fi
  elif [[ "$UI" == "dialog" ]]; then
    if dialog --clear --title "$1" --yesno "$2" 10 70; then return 0; else return 1; fi
  else
    echo -e "\n== $1 ==\n$2 [y/N]"
    read -rp "> " a; [[ "${a,,}" =~ ^y(es)?$ ]]
  fi
}

ui_msg() {
  # $1 title, $2 text
  if [[ "$UI" == "whiptail" ]]; then
    whiptail --clear --title "$1" --msgbox "$2" 12 70
  elif [[ "$UI" == "dialog" ]]; then
    dialog --clear --title "$1" --msgbox "$2" 12 70
  else
    echo -e "\n== $1 ==\n$2\n"
  fi
}

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p>=1 && p<=65535 ))
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
    warn "未检测到包管理器，将尝试仅使用静态下载方式（需要 curl、tar、jq）"
  else
    eval "$INSTALL curl tar jq"
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
  tmpdir="$(mktemp -d)"
  pushd "$tmpdir" >/dev/null
  curl -fL "$SB_URL" -o "$SB_TARBALL"
  tar zxf "$SB_TARBALL"
  install -m 0755 "sing-box-${SB_VER#v}-linux-${ARCH}/sing-box" "$SB_BIN"
  popd >/dev/null
  rm -rf "$tmpdir"
  ok "sing-box 安装完成：$($SB_BIN version | head -n 1 || true)"
}

gen_password() {
  local method="$1"
  case "$method" in
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) openssl rand -base64 32 ;;
    2022-blake3-aes-128-gcm) openssl rand -base64 16 ;;
    *) echo "";;
  esac
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
  local ip
  ip="$(curl -fsSL https://api.ipify.org || echo "<你的服务器IP>")"

  # 生成 Surge 配置行
  local surge_line="Proxy = ss, ${ip}, ${PORT}, encrypt-method=${METHOD}, password=${PASSWORD}, udp-relay=true"
  mkdir -p "$SB_DIR"
  echo "$surge_line" > "$SB_DIR/surge-ss2022.conf"

  local info="服务器: ${ip}
端口: ${PORT}
方法: ${METHOD}
密钥(base64): ${PASSWORD}

ss://${METHOD}:${PASSWORD}@${ip}:${PORT}#ss2022-${ip}-${PORT}

[Surge]
${surge_line}
(已保存到 $SB_DIR/surge-ss2022.conf)"
  ui_msg "安装完成" "$info"
  echo -e "$info"
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
  local choice
  choice="$(ui_menu "选择操作" "请选择你要执行的操作" \
    install "安装/更新 sing-box (SS2022)" \
    uninstall "卸载 sing-box 与配置" \
    quit "退出")"
  echo "${choice:-quit}"
}

collect_inputs() {
  # method
  METHOD="$(ui_menu "选择加密方法" "请选择 Shadowsocks 2022 方法" \
    2022-blake3-aes-256-gcm "（默认）更通用，AES-256-GCM" \
    2022-blake3-chacha20-poly1305 "移动端友好，ChaCha20-Poly1305" \
    2022-blake3-aes-128-gcm "轻量 AES-128-GCM")"
  [[ -z "${METHOD:-}" ]] && METHOD="$default_method"

  # port
  while true; do
    PORT="$(ui_input "设置端口" "输入监听端口（1-65535）" "$default_port")"
    if validate_port "$PORT"; then break; fi
    ui_msg "端口无效" "请输入 1-65535 之间的数字端口"
  done

  # listen address
  LISTEN_ADDR="$(ui_input "监听地址" "输入监听地址（默认 :: 同时监听 IPv4/IPv6；或 0.0.0.0 / 127.0.0.1）" "$default_listen")"

  # key
  if ui_yesno "密钥设置" "是否手动输入 base64 密钥？（选择“否”将自动生成合适长度）"; then
    while true; do
      PASSWORD="$(ui_input "输入密钥" "请输入 base64 编码的密钥（建议与方法匹配长度）" "")"
      if [[ -n "${PASSWORD// /}" ]]; then break; fi
      ui_msg "密钥为空" "密钥不能为空，或选择自动生成。"
    done
  else
    PASSWORD="$(gen_password "$METHOD")"
  fi

  # confirm
  local summary="方法: ${METHOD}\n端口: ${PORT}\n监听: ${LISTEN_ADDR}\n密钥(base64): ${PASSWORD}"
  if ui_yesno "确认配置" "请确认以下设置：\n\n${summary}\n\n是否继续安装？"; then
    return 0
  else
    ui_msg "已取消" "未进行任何更改。"
    exit 0
  fi
}

main() {
  need_root
  need_tty
  detect_pkg
  detect_arch
  install_deps
  install_ui

  case "$(main_menu)" in
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
      ui_msg "退出" "再见 👋"
      ;;
  esac
}

main "$@"
