# sing-box onekey（自用版）

自己用的 VPS 舰队用的一键服务端脚本：装好就是一个
VLESS+REALITY（TCP 443）+ Hysteria2（UDP 443）双入口节点，顺带检查/开启 BBR。

## 为什么不用现成的轮子

GitHub 上现成的一键脚本确实很多（233boy、eooce/甬哥系列等，都是这个圈子的老项目）。
但它们普遍带面板、带订阅分发、会顺手改 SSH 端口/防火墙/装一堆东西，
版本和协议组合也由作者定。对只有几台自有机器、且要求“二进制+systemd、不装 Docker、
不许动现有服务”的人来说，自己的极简版更可控：脚本全文就一个文件，谁都能看完。

## 用法

在目标 VPS（Debian / Ubuntu，amd64 或 arm64）上：

```bash
curl -fsSL https://raw.githubusercontent.com/aimachy/sing-box-onekey/main/install.sh -o install.sh
sudo bash install.sh
```

装完屏幕上会打印两条客户端链接（也会存到服务器 `/etc/sing-box/client-links.txt`，600 权限）：

- `vless://...` REALITY 入口，粘贴进 Hiddify / V2Box / Happ 即可
- `hysteria2://...` Hy2 入口，同上

其他命令：

```bash
sudo bash install.sh links      # 再打印一次客户端链接
sudo bash install.sh uninstall  # 卸载 sing-box 并删配置（BBR 设置保留，脚本里有说明）
```

可选环境变量：`PORT`（默认 443）、`REALITY_SERVER`（借壳站，默认 www.microsoft.com）、
`NODE_NAME`（链接里显示的节点名）、`PUBLIC_IP`（自动识别不准时手填）、
`SINGBOX_VER`（默认锁 1.14.4）。

## 脚本到底做了什么（就这些，没有别的）

1. 检查系统（只支持 Debian/Ubuntu）和架构
2. BBR 没开就开（写 `/etc/sysctl.d/99-bbr.conf`，只对 TCP/REALITY 起作用）
3. 从 SagerNet/sing-box 官方 GitHub Release 下载二进制到 `/usr/local/bin/sing-box`
4. 用 sing-box 自带命令生成 UUID、REALITY 密钥对、short_id、Hy2 密码，
   存 `/etc/sing-box/credentials.txt`（600）；重跑脚本沿用旧凭据，客户端不用改
5. 为 Hy2 生成一张自签证书（客户端链接里带 insecure=1；有域名后可换真证书）
6. 写 `/etc/sing-box/config.json` 并先 `sing-box check` 校验，再建 systemd 服务启动
7. ufw 开着的话放行端口；**云厂商安全组要自己去控制台放行 TCP+UDP 443**

不做的事：不改 SSH、不装面板、不装 Docker、不上报任何数据、没有自动更新。

## 注意

- 先在 1 台试点机上跑，不要批量对所有 VPS 执行
- 国内 VPS 装了也出不去，不要在国内机上跑
- 跑生产网站的机器先别跑，等确认 443 端口没被网站占用再说（脚本会直接占用 443）
- 客户端链接等于钥匙，不要外传、不要贴到公开地方；这个仓库只放脚本，**不放任何真实节点配置**

## 装完之后要保存什么

服务器上会生成这几个文件，都在 `/etc/sing-box/`：

| 文件 | 是什么 | 要不要存到本地 |
|---|---|---|
| `client-links.txt` | 两条客户端链接（vless:// 和 hysteria2://） | **要，这是唯一必须存的** |
| `credentials.txt` | UUID、REALITY 密钥、Hy2 密码的原件 | 建议和上面一起存，作为灾备 |
| `config.json` | 服务端配置，可由脚本+凭据随时重建 | 不用 |
| `cert.pem` / `key.pem` | Hy2 自签证书，可随时重建 | 不用 |

保存方法：把 `client-links.txt` 的内容存进你的密码管理器（1Password 等）的私密笔记里，
或存成本地一个不联网的文本文件。**链接就等于钥匙**：
不要发到微信/邮件里到处传、不要截图发人、绝对不要提交进任何 GitHub 仓库（包括本仓库）。

忘了存也不用慌：服务器还在的话，SSH 上去跑一次就能再打印出来：

```bash
sudo bash install.sh links
# 或直接看服务器上的文件
sudo cat /etc/sing-box/client-links.txt
```

真正丢数据的只有一种情况：服务器重装/被删且本地没存凭据。那时只能重跑脚本生成一套新钥匙，
所有设备上的旧链接作废、要重新导入一次，就这么大点事。

## iPhone 设置（以 Hiddify 为例）

前提：App Store 里装好 Hiddify（正版认准 Holistic 发布、蓝色 Hi 图标）。

1. 把服务器给你的 `vless://` 那条链接弄到 iPhone 上并复制（整段复制，不要改任何字符）
2. 打开 Hiddify，点右上角 `+`，选「从剪贴板添加 / Add from Clipboard」，会出现一个新配置，名字就是链接末尾的节点名
3. 回到主界面点中这个配置，再点中间的大圆按钮连接；iOS 第一次会弹「Hiddify 想添加 VPN 配置」，点允许、用面容 ID/密码确认
4. 连上后用 Safari 打开 ip.sb 或 ipinfo.io，显示的 IP 是你 VPS 的 IP、国家对得上，就成了；再试打开 Google
5. Hy2 那条 `hysteria2://` 链接同样方法再加一个配置，平时不用，晚高峰 REALITY 慢的时候切到它
6. 想让国内 App 直连、不绕出去：在 Hiddify 的设置里把地区/路由选成中国（China）预设即可；
   第一次先别改，先全走代理确认能通，再回来开这个

注意：iPhone 同时只能开一个 VPN。开 Hiddify 时如果 OpenVPN 还连着，会被顶掉，这是系统限制，正常现象。
