Xray_Setup v1 — Xray VLESS + TCP + REALITY + Vision 独立安装脚本
================================================================

干什么
------
只装一个东西：Xray 核心的 VLESS+TCP+REALITY+Vision 入站。
独立 systemd 服务 xray-reality、独立目录 /usr/local/etc/xray-reality，
不修改机器上已有的 sing-box / 其他 Xray 安装和它们的配置。

与 v2ray-agent 的区别（为什么另写一个）
--------------------------------------
- Xray 版本写死 26.10.31，下载后先用官方 .dgst 校验 SHA2-256 再安装，
  不追滚动 master，脚本本身版本固定、可全文审计（468 行）。
- dest 默认 files.pythonhosted.org（Fastly，不在任何已知脚本默认池），
  不从域名池里随机抽；shortId 首次运行随机生成，不用全网同款模板值。
- minClientVer 默认 1.0.0：新版 Xray 服务端默认会拒绝 sing-box 系客户端
  （Karing 测速显示 -1 就是这个），放宽后 Karing 可以连。代价是放回旧
  客户端指纹，隐蔽性略降——明码标价，自己权衡（见下面开关）。
- UUID / REALITY 密钥 / shortId 首次生成后存盘（state.env，0600），
  重跑不换，已导入的客户端不会失效。

两种 dest 模式
--------------
1) external（默认）：借 files.pythonhosted.org 的握手。
   sudo bash xray-setup.sh

2) self（自己的域名）：域名解析指向本机（Cloudflare 托管可以，必须
   灰云“仅 DNS”；开小黄云代理不行），脚本在本机 127.0.0.1:10443 起一个
   回落 HTTPS 小站（python3，独立服务 xray-fallback），挂你域名的真证书，
   REALITY 的 dest 指向它。证书按顺序找：XRAY_CERT/XRAY_KEY 显式路径 >
   ~/.acme.sh/<域名>_ecc > ~/.acme.sh/<域名> > /etc/letsencrypt/live/<域名>，
   找不到直接报错，不默默退自签。
   sudo XRAY_DEST_MODE=self XRAY_DOMAIN=node.example.com bash xray-setup.sh
   回落站的页面在 /usr/local/etc/xray-reality/webroot/index.html，可替换。
   注意：该子域名不要留 AAAA 记录（机器没有公网 IPv6 时客户端会撞墙）；
   域名若设了 CAA，需允许 letsencrypt.org 签发。

常用开关（环境变量）
--------------------
XRAY_PORT=443               监听端口（443 被占会拒绝覆盖，要求先处理）
XRAY_MIN_CLIENT_VER=1.0.0   默认放宽；设为 ""（空）= 不写该字段，走新版
                            Xray 的严格默认（只收新版 Xray 客户端）
XRAY_ADDR=1.2.3.4           客户端链接里的地址（默认自动识别公网 IPv4；
                            self 模式默认用域名）
XRAY_VERSION=26.10.31       核心版本（写死，升级时改这里并重新校验）
XRAY_DEST_HOST=deb.debian.org  external 模式换 dest（须过 TLS1.3/X25519/h2）

管理
----
查看链接：  sudo bash xray-setup.sh --print-link
            或看 /usr/local/etc/xray-reality/client-info.txt（0600）
状态：      systemctl status xray-reality
日志：      journalctl -u xray-reality -n 50
卸载：      sudo bash xray-setup.sh --uninstall
            （只删本包的服务/配置/二进制，不动其他东西）

注意事项
--------
- 新机器记得在云厂商面板/防火墙放行 TCP 监听端口（脚本不碰防火墙）。
- 服务带内存帽子（GOMEMLIMIT=80MiB + GOGC=50，与机队调优口径一致）。
- 客户端导入链接时 fingerprint 必须 chrome、flow 必须 xtls-rprx-vision，
  链接里已带好，原样导入 v2rayN / v2rayNG / Karing 即可。
- 链接含完整凭据，不要公开转发。

本地验证记录（交付前已实测）
----------------------------
- bash -n 语法通过；用官方 v26.10.31 二进制对脚本生成的 external/self
  两种配置跑 xray run -test 均 OK；重跑复用凭据验证通过。
- 用脚本模板配置实机起服务端+客户端对连：REALITY 握手完成、经隧道
  成功取回数据（沙箱环境公网目标因假 IP DNS 不可达，只验了本地目标，
  隧道与握手本身无问题）。
