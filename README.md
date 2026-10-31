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
