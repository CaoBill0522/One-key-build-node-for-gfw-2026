# VLESS + Reality Vision 一键部署脚本

交互式部署 Xray VLESS + Reality 节点，使用 `xtls-rprx-vision` 流控，并生成 Clash Meta 可用的节点配置和 HTTPS 订阅地址。

## 快速安装

在 Debian/Ubuntu 或 RHEL 系列服务器上以 root 执行：

```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  -o /root/setup-vless-reality.sh \
  https://raw.githubusercontent.com/CaoBill0522/One-key-build-node-for-gfw-2026/main/setup-vless-reality.sh

chmod 700 /root/setup-vless-reality.sh
bash /root/setup-vless-reality.sh
```

脚本会交互询问：

1. 服务器域名（需要先解析到服务器 IP）
2. 节点名称
3. Reality SNI，默认值为 `m.media-amazon.com`

也可以使用环境变量运行：

```bash
DOMAIN=example.com \
NODE_NAME=MyNode \
SNI=m.media-amazon.com \
bash /root/setup-vless-reality.sh
```

## 自动完成的工作

- 安装或使用现有 Xray
- 生成 UUID、Reality 私钥、公钥和 shortId
- 配置 VLESS + Reality + Vision
- 启用 BBR、TCP 参数和高文件句柄限制
- 配置 systemd 自动启动和崩溃重启
- 生成 VLESS 分享链接
- 生成 Clash Meta YAML 配置
- 尝试申请 Let’s Encrypt 证书
- 通过 HTTPS 提供 Clash Meta 订阅地址
- Debian 11 Bullseye 自动切换到 Debian Archive 软件源

## 端口和 DNS

请确保：

- 域名的 A 记录指向服务器 IPv4 地址
- TCP 443：VLESS + Reality
- TCP 80：Let’s Encrypt 证书申请和跳转
- TCP 8443：HTTPS Clash 订阅

如果 80 端口无法从公网访问，节点仍会部署成功，但脚本不会生成公网 HTTPS 订阅地址。

## 输出文件

部署完成后，服务器上会生成：

- Xray 配置：`/usr/local/etc/xray/config.json`
- Clash YAML：`/var/lib/xray-subscription/clash.yaml`
- VLESS 文本：`/var/lib/xray-subscription/vless.txt`
- Base64 订阅内容：`/var/lib/xray-subscription/vless.base64`
- 节点参数：`/var/lib/xray-vless-reality/node.env`

脚本结束时会直接打印 VLESS 链接、Clash YAML 地址和 Base64 订阅地址。订阅 URL 包含随机访问令牌，应当视为敏感信息。

## 注意事项

- 每次重新运行脚本都会生成新的 UUID 和 Reality 密钥，旧节点链接会失效。
- Debian 11 已进入归档阶段；建议新装 Debian 12 或 Debian 13。
- Clash 客户端需要支持 VLESS Reality 和 `xtls-rprx-vision`，例如 Clash Meta/Mihomo。
- 不要把服务器私钥、UUID 或带令牌的订阅地址提交到公开仓库。
