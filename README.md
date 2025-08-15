# singbox-ss2022-oneclick

一键安装/更新 **sing-box** 并启用 **Shadowsocks 2022** 入站，  
支持纯命令行交互设置端口、加密方法、监听地址和密钥（无弹窗，SSH 直接输入即可）。

## 使用方法

1. 下载脚本到服务器并赋予执行权限：
   ```bash
   curl -fsSLo singbox-ss2022-oneclick.sh \
     "https://raw.githubusercontent.com/dengfenga777/singbox-s2022/main/singbox-ss2022-oneclick.sh"
   chmod +x singbox-ss2022-oneclick.sh
## 运行脚本
   
   ```bash
   sudo ./singbox-ss2022-oneclick.sh
