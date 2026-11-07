# Xray Setup — VLESS + TCP + REALITY + Vision 独立安装脚本

只装一个东西：Xray 核心的 VLESS+TCP+REALITY+Vision 入站。独立 systemd 服务 `xray-reality`、独立目录 `/usr/local/etc/xray-reality`，不修改机器上已有的 sing-box / 其他 Xray 安装和它们的配置。

> 版本：v1.6（新增可选 Hysteria2 入站 `XRAY_HY2=on`：与 VLESS 同一个 Xray 进程、官方 finalmask 方案，详见下文专节；`xr` 菜单第 8 项可开关）
> v1.5：Xray 核心可自助升级：`xr` 菜单第 6 项或 `XRAY_VERSION=latest` 直接查 GitHub 最新版并升级，官方哈希照常校验；装过的核心版本记入 state，重跑永不静默降级。另修复 v1.4 的 state 读回 bug——回落站选择此前实际记不住，v1.5 起真正生效。
> v1.4 起：可选 nginx 回落站（`XRAY_FALLBACK=nginx`）+ 快捷命令 `xr` 管理菜单。
> v1.3 起一步到位：缺证书自动签发（含自动装 acme.sh）、缺工具自动 apt 安装、ufw 已启用时自动放行端口。
> v1.2 新增 both 组合模式：external 与 self 两个入站一次装好。
> v1.1 起 `minClientVer` 默认为 26.0.0（严格，只收 Xray 内核客户端）；需要放行 sing-box 系客户端（Karing）时用 `XRAY_MIN_CLIENT_VER=1.0.0` 重跑。

## 安装命令

前置要求：

- root 权限；Debian/Ubuntu 等带 systemd 的 Linux
- 能直连 GitHub（脚本要下载 Xray 官方包并验哈希）
- 云面板/防火墙放行要用的 TCP 端口（默认 443）
- self/both 模式另需：域名 A 记录已指向本机（CF 灰云仅 DNS）。证书**不用预先准备**：没有时脚本自动用 acme.sh 签发（acme.sh 没装也会自动装；签发走 standalone，需要 TCP 80 临时空闲且云面板放行 80）。缺 curl/unzip/python3 时脚本会尝试 apt 安装

### 方式一：从 GitHub 下载（推荐）

```bash
curl -fsSLO https://raw.githubusercontent.com/signyf/xray-reality-setup/main/xray-setup.sh
less xray-setup.sh   # 先审后跑，不要管道直接执行
```

默认 external 模式（dest = files.pythonhosted.org）：

```bash
sudo bash xray-setup.sh
```

self 模式（自己的域名当 SNI/dest）：

```bash
sudo XRAY_DEST_MODE=self XRAY_DOMAIN=node.example.com bash xray-setup.sh
```

both 组合模式（external + self 一次装好，两个入站共用一套凭据）：

```bash
sudo XRAY_DEST_MODE=both XRAY_DOMAIN=node.example.com bash xray-setup.sh
```

### 方式二：用离线 zip 包

```bash
unzip Xray_Setup_v1.6.zip
cd Xray_Setup_v1.6
sudo bash xray-setup.sh
```

### 装完验证与取链接

```bash
systemctl status xray-reality        # 应为 active (running)
sudo bash xray-setup.sh --print-link # 重新打印客户端分享链接
```

或直接看 `/usr/local/etc/xray-reality/client-info.txt`。

## 三种 dest 模式

1. **external（默认）**：借 files.pythonhosted.org 的握手。

   ```bash
   sudo bash xray-setup.sh
   ```

2. **self（自己的域名）**：域名解析指向本机（Cloudflare 托管可以，必须灰云“仅 DNS”；开小黄云代理不行）。脚本在本机 127.0.0.1:10443 起一个回落 HTTPS 小站（默认 python3，可选独立 nginx 实例：`XRAY_FALLBACK=nginx`；独立服务 xray-fallback），挂你域名的真证书，REALITY 的 dest 指向它。证书按顺序找：`XRAY_CERT`/`XRAY_KEY` 显式路径 > `~/.acme.sh/<域名>_ecc` > `~/.acme.sh/<域名>` > `/etc/letsencrypt/live/<域名>`；**都找不到就自动签发**（acme.sh + Let's Encrypt standalone，ECC；acme.sh 没装先自动装），不默默退自签。acme.sh 管理的证书还会登记续期钩子：续期后新证书自动落到脚本配置目录并重启回落站，不用管。

   ```bash
   sudo XRAY_DEST_MODE=self XRAY_DOMAIN=node.example.com bash xray-setup.sh
   ```

   回落站的页面在 `/usr/local/etc/xray-reality/webroot/index.html`，可替换。注意：该子域名不要留 AAAA 记录（机器没有公网 IPv6 时客户端会撞墙）；域名若设了 CAA，需允许 letsencrypt.org 签发。

3. **both（组合）**：上面两个入站一次装进同一个 Xray 进程——external 在 `XRAY_PORT`（默认 443）、self 在 `XRAY_SELF_PORT`（默认 8443），共用同一套 UUID / 密钥 / shortId，装完打印两条链接。一个 REALITY 入站只能带一个 dest，所以“组合”的实现就是两个入站并排（与 v2ray-agent 的组合安装同一思路）。

   ```bash
   sudo XRAY_DEST_MODE=both XRAY_DOMAIN=node.example.com bash xray-setup.sh
   ```

## Hysteria2 入站（可选，v1.6 起）

```bash
sudo XRAY_HY2=on bash xray-setup.sh        # 任意 dest 模式都可叠加
```

- 与 VLESS 装在**同一个 Xray 进程**里（同一个服务、同一份配置多一个入站），用的是 Xray 官方的 Hy2 方案，不是另起 sing-box：协议 `hysteria`（version 2）、QUIC/TLS 传输、**Salamander 混淆走官方 `finalmask`**（旧式协议内 obfs 的官方替代）、外加 HTTP/3 masquerade 伪装代理（探测者会被反代到 bing）。
- 默认 UDP **8443**（`XRAY_HY2_PORT` 可改）。**与 sing-box 的 Hy2 不能共用同一个 UDP 端口**——机器上已有 sing-box-hy2 占着 8443 时，要么给 Xray 的 Hy2 换端口，要么先退掉 sing-box 那个；脚本检测到 UDP 端口被别人占用会直接报错说明。
- 证书按优先级：`XRAY_HY2_CERT`/`XRAY_HY2_KEY` 显式指定 > 本机域名证书（self/both 模式现成的，或 external 模式下显式给 `XRAY_DOMAIN`，同样自动查找/签发） > 自动生成的自签证书（SNI 默认 www.bing.com）。auth 与 obfs 密码首次生成后存 state，重跑不换；关掉再开（`XRAY_HY2=off` 重跑，或 `xr` 菜单第 8 项）密码也保留，旧链接继续有效。
- 客户端链接：域名证书模式不带 pin（证书会续期，钉死会断）；自签/自备证书模式带 `pinSHA256`（叶子证书 DER 的 SHA-256）。客户端须用 **Xray 内核**（v2rayN / v2rayNG）；sing-box 内核客户端要用 Hy2 需贴完整证书 PEM（自签证书在 `/usr/local/etc/xray-reality/hy2-cert.pem`），链接里的 pinSHA256 对它们无效。
- 需要 Xray 核心 ≥ 26.3.27（Hy2 传输 2026 年才进核心），版本不够脚本会直接报错并提示升级核心。
- **手写 Xray JSON 配置的注意**：26.x 起 `allowInsecure` 已被删除（写了直接报错），证书钉扎改用 `pinnedPeerCertSha256`（单个 hex 字符串，逗号可分隔多个）；旧字段 `pinnedPeerCertificateChainSha256` 会被静默忽略——验证会掉回系统 CA 然后失败。分享链接不受影响，客户端自己会翻译。
- 另一个 26.x 行为：freedom 出站对 vless/hysteria 等入站**默认拦截内网目标**（防 SSRF），所以经节点访问局域网/内网地址会被黑洞——这是官方默认，不是配置错误。

## 与 v2ray-agent 的区别（为什么另写一个）

- Xray 版本写死 26.10.31，下载后先用官方 .dgst 校验 SHA2-256 再安装，不追滚动 master；脚本本身版本固定、可全文审计。
- dest 默认 files.pythonhosted.org（Fastly，不在任何已知脚本默认池），不从域名池里随机抽；shortId 首次运行随机生成，不用全网同款模板值。（脚本行数：v1.5 为 915 行，v1.6 加 Hy2 后 1138 行。）
- minClientVer 默认 26.0.0（严格）：只收当前世代的 Xray 内核客户端，sing-box 系客户端（Karing，其握手里报的是老版本）会被拒绝——旧形状的 ClientHello 在现今流量里更扎眼，这正是要拒的。它不是加密防线（准入靠 REALITY 密钥认证），是伪装新鲜度门槛。注意在 Xray 26.10.31 上把该字段留空等于不检查，所以严格必须写显式版本号。
- UUID / REALITY 密钥 / shortId 首次生成后存盘（state.env，0600），重跑不换，已导入的客户端不会失效。

## 常用开关（环境变量）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `XRAY_PORT` | `443` | 监听端口（被其他程序占用会拒绝覆盖，要求先处理）；both 模式下是 external 入站的端口 |
| `XRAY_SELF_PORT` | `8443` | both 模式下 self 入站的端口 |
| `XRAY_MIN_CLIENT_VER` | `26.0.0` | 严格；`1.0.0` = 放行 sing-box 系客户端（Karing）；`""`（空）= 不写字段 = 完全不检查 |
| `XRAY_ADDR` | 自动识别 | 客户端链接里的地址（默认自动识别公网 IPv4；self 模式默认用域名） |
| `XRAY_VERSION` | 脚本钉的版本 | 核心版本：填版本号，或 `latest` 查 GitHub 最新版；装过的版本记入 state，重跑保持不降级 |
| `XRAY_DEST_HOST` | `files.pythonhosted.org` | external 模式换 dest（须过 TLS1.3 / X25519 / h2） |
| `XRAY_DEST_MODE` | `external` | `external`、`self` 或 `both` |
| `XRAY_AUTO_CERT` | `1` | self/both 缺证书时自动签发（含自动装 acme.sh）；`0` = 不签、直接报错 |
| `XRAY_FALLBACK` | `python` | self/both 回落站实现：`nginx` = 独立 nginx 实例（原生 h2、生产级并发、更像真站）；选择记入 state，重跑可不带 |
| `XRAY_DOMAIN` | — | self 模式的域名（必填）；external 模式下给 Hy2 用域名证书时也填它 |
| `XRAY_HY2` | state 记录/关 | `on` = 叠加 Hysteria2 入站（UDP）；`off` = 关掉（密码保留在 state，重开链接不变） |
| `XRAY_HY2_PORT` | `8443` | Hy2 的 UDP 监听端口 |
| `XRAY_HY2_SNI` | `www.bing.com` | 自签 Hy2 证书的 SNI（用域名证书时忽略） |
| `XRAY_HY2_CERT`/`XRAY_HY2_KEY` | — | Hy2 显式证书路径（须成对给出） |

示例：换端口 + 放行 Karing：

```bash
sudo XRAY_PORT=8443 XRAY_MIN_CLIENT_VER=1.0.0 bash xray-setup.sh
```

## 管理

```bash
sudo bash xray-setup.sh --print-link  # 查看链接
systemctl status xray-reality         # 状态
journalctl -u xray-reality -n 50      # 日志
sudo bash xray-setup.sh --uninstall   # 卸载（只删本包的服务/配置/二进制）
```

## 注意事项

- 云厂商面板的安全组仍要手动放行 TCP 监听端口（脚本管不了云端）；本机 ufw 已启用时，脚本会自动放行监听端口。自动签发证书时另需云面板放行 TCP 80。
- 服务带内存帽子（GOMEMLIMIT=80MiB + GOGC=50，与机队调优口径一致）。
- 客户端导入链接时 fingerprint 必须 chrome、flow 必须 xtls-rprx-vision，链接里已带好，原样导入 v2rayN / v2rayNG（Xray 内核）即可；默认严格模式下 Karing（sing-box 内核）连不上，是预期行为，不是装坏了。
- 链接含完整凭据，不要公开转发。

## 本地验证记录（交付前已实测）

- bash -n 语法通过；用官方 v26.10.31 二进制对脚本生成的 external/self 两种配置跑 `xray run -test` 均 OK；重跑复用凭据验证通过。
- 用脚本模板配置实机起服务端+客户端对连：REALITY 握手完成、经隧道成功取回数据（沙箱环境公网目标因假 IP DNS 不可达，只验了本地目标，隧道与握手本身无问题）。
- v1.1 复验：脚本生成的严格配置（minClientVer 26.0.0）+ 最新 Xray 客户端（26.10.31）实连通过、经隧道取回数据。
- v1.2 复验：both 模式生成的双入站配置过 `xray run -test`；两个入站分别用对应客户端实连，均经隧道取回数据；external/self 单模式回归正常、both 重跑复用凭据。
- v1.3 复验：无证书环境下自动签发全流程跑通（用 acme.sh 替身模拟签发与 install-cert：证书落入配置目录、回落站指向新证书、续期钩子登记成功），该路径实连经隧道取回数据；`XRAY_AUTO_CERT=0` 时恢复为直接报错；external/both 回归正常。（真实 LE 签发需域名解析指向目标机，沙箱无法代验，首次实机签发留意脚本输出。）
- v1.3.1 复验：回落站新旧实现 A/B 并发测试（60 并发请求 + 20 个垃圾连接混入）本地均 60/60 通过——回环握手太快，复现不了广域网高延迟下旧实现串行握手的排队问题；本版属预防性加固，不是已实锤的故障修复。注：回落站 ALPN 首选 h2（为像真站），用 curl 探活须加 `--http1.1`，直接 curl 会因 h2 帧不匹配返回 000，那是探针假象、不是回落站故障。
- v1.5 复验：默认钉版真实下载+哈希校验通过；`XRAY_VERSION=latest` 实查 GitHub API 解析出最新版（当时为 26.10.31）并完成安装；state 读回双向验证——把 CORE_VERSION 人为改成 99.0.0 后重跑，脚本确实按 99.0.0 去下载（证明读回生效、不会降级回钉版），回落站 FALLBACK=nginx 读回同样验证通过。此读回在 v1.4 因 subshell 写法失效（选择记不住、靠每次带参数掩盖），v1.5 修复并在此留档。
- v1.4 复验：nginx 模式 dry-run（self/both）产物正确（独立实例 unit、nginx 1.24 走 `listen ... ssl http2` 分支、state 记录 FALLBACK=nginx）；生成的 nginx 实例实起验证：HTTP/2 与 HTTP/1.1 均 200、60 并发+垃圾连接混入 60/60；`xr` 菜单实测渲染与状态/链接/切换项正常。联调中发现并修复一个真 bug：安装器 umask 077 使 webroot 目录 700、文件 600，nginx 的 nobody worker 读不到会 404——nginx 分支现显式放开目录穿越与 webroot 读权限（state/私钥仍 600）。REALITY 全链路在沙箱只验到“服务端认证通过并发出 egress 拨号”一步：沙箱出口网关会 reset 直连（python 回落站 A/B 同样如此），完整取数未在沙箱复现，以实机为准。
- v1.6 复验（Hy2）：字段口径以 v26.10.31 官方源码为准（`infra/conf/hysteria.go`、`transport_security.go`）。助手 VM 出站 UDP 被系统级禁止（sendto: operation not permitted），回环 E2E 改在用户 Mac 上用官方 macOS 版 26.10.31（.dgst 哈希已验）实测四象限：正确 auth+obfs+pin → 经隧道取回公网页面；错 obfs / 错 auth / 错 pin → 全部被拒。过程中两个坑已写进上文专节：`--noproxy '*'` 会让 curl 绕过显式 socks 代理（假阳性教训）；26.x freedom 默认拦截内网目标（测试目标须用公网地址）。脚本侧 dry-run 全过：external+Hy2（自签+pin 链接）、external+Hy2+域名、self+Hy2、both+Hy2、关 Hy2（密码保留）、重跑复用、菜单渲染与第 8 项开关行、核心版本门（26.3.13 被拒）、证书成对校验；生成配置均过真二进制 `xray run -test`。Hy2 生成的入站 JSON 与 Mac 实测通过的配置逐字段一致。
