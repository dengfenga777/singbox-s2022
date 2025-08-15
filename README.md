# singbox-s2022[README.md](https://github.com/user-attachments/files/21783146/README.md)
# sing-box s2022 一键安装脚本

## 功能
- 安装最新版 sing-box
- 配置 Shadowsocks 2022 协议（2022-blake3-aes-128-gcm）
- 自动生成随机密码
- 开启流量统计
- 提供 `ss2022-traffic` 命令查询流量

## 一键安装命令
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dengfenga777/singbox-s2022/main/s2022_auto.sh)
```

## 查看流量
```bash
ss2022-traffic
```
#!/bin/bash
set -e

# ========== 配置部分 ==========
PORT=40000
PASSWORD=$(openssl rand -base64 16)
CONFIG_PATH="/etc/sing-box/config.json"

echo "开始安装 sing-box s2022 并启用流量统计..."

# 安装 sing-box
if ! command -v sing-box >/dev/null 2>&1; then
    echo "安装 sing-box..."
    bash <(curl -fsSL https://sing-box.app/install.sh)
else
    echo "sing-box 已安装"
fi

# 创建配置目录
mkdir -p /etc/sing-box

# 生成配置文件
cat > $CONFIG_PATH <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "in-s2022",
      "listen": "::",
      "listen_port": $PORT,
      "method": "2022-blake3-aes-128-gcm",
      "password": "$PASSWORD",
      "network": "tcp,udp",
      "statistics": {
        "inbound": true
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ],
  "experimental": {
    "statistics": {
      "enabled": true
    },
    "api": {
      "enabled": true,
      "listen": "127.0.0.1:9090"
    }
  }
}
EOF

# 创建流量统计命令
cat > /usr/local/bin/ss2022-traffic <<'EOFF'
#!/bin/bash
curl -s http://127.0.0.1:9090/stats/inbounds | jq -r '.[] | "\(.name) => 上行: \(.uplink/1048576) MB, 下行: \(.downlink/1048576) MB"'
EOFF
chmod +x /usr/local/bin/ss2022-traffic

# 启动服务
systemctl enable sing-box
systemctl restart sing-box

echo "安装完成!"
echo "=========================="
echo "协议: s2022"
echo "地址: $(curl -s ifconfig.me)"
echo "端口: $PORT"
echo "密码: $PASSWORD"
echo "加密: 2022-blake3-aes-128-gcm"
echo "=========================="
echo "查看流量: ss2022-traffic"
