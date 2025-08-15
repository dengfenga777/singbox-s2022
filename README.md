
  
[Uploading README.md…]()
# singbox-ss2022-oneclick

一键安装/更新 **sing-box** 并启用 **Shadowsocks 2022** 入站，支持交互式弹窗设置端口/方法/密钥/监听地址（`whiptail`/`dialog`）。
适配 Debian/Ubuntu/CentOS/Alma/Rocky，x86_64 / aarch64。

## 一键安装
```curl
curl -fsSL "https://raw.githubusercontent.com/dengfenga777/singbox-s2022/main/singbox-ss2022-oneclick.sh" | sudo bash
```

。

## 使用
```bash
chmod +x singbox-ss2022-oneclick.sh
sudo ./singbox-ss2022-oneclick.sh
```
运行后通过弹窗选择：操作（安装/卸载）→ 方法 → 端口 → 监听地址 → 密钥（自动/手动）。

## 支持的方法
- `2022-blake3-aes-256-gcm`（默认）
- `2022-blake3-chacha20-poly1305`
- `2022-blake3-aes-128-gcm`

## 输出
安装完成后会显示：
- `ss://` 连接 URI
- **Surge 配置行**（并保存到 `/etc/sing-box/surge-ss2022.conf`）

Surge 片段示例：
```
Proxy = ss, <IP>, <PORT>, encrypt-method=<METHOD>, password=<BASE64_KEY>, udp-relay=true
```

## 卸载
```bash
sudo ./singbox-ss2022-oneclick.sh   # 弹窗选择“卸载”
```

## CI & Release
- 本仓库包含 GitHub Actions：`ci.yml` 会在 push/PR 时运行 `shellcheck`。
- 打 tag（如 `v1.0.0`）会触发 `release.yml` 自动发布 Release，并上传脚本。

## 许可证
MIT
