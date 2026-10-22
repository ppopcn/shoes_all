# 一键部署脚本合集

三台「单进程 · 单配置 · 全协议」代理服务端一键部署脚本，都是**一个脚本装完、跑一个进程、出一张凭据表**。

| 脚本                                 | 内核                                                                          | 协议数 | 适用                                                  |
| ---------------------------------- | --------------------------------------------------------------------------- | --- | --------------------------------------------------- |
| [`shoes_all.sh`](shoes_all.sh)     | [cfal/shoes](https://github.com/cfal/shoes)                                 | 7   | 轻量，无依赖，跑起来就是一个小二进制                                  |
| [`singbox_all.sh`](singbox_all.sh) | [shtorm-7/sing-box-extended](https://github.com/shtorm-7/sing-box-extended) | 8   | 需要 MTPROXY / 更多扩展能力时用                               |
| [`xray_all.sh`](xray_all.sh)       | [XTLS/Xray-core](https://github.com/XTLS/Xray-core)                         | 5   | Xray 生态正统实现，Reality/Vision 本家；不支持 QUIC 系协议与 MTProto |

---

## 一键安装

### shoes 全家桶（7 协议）

```bash
curl -fsSL https://raw.githubusercontent.com/ppopcn/shoes_all/refs/heads/main/shoes_all.sh | sudo bash
```

### sing-box 全家桶（8 协议 且支持MTPROXY）

```bash
curl -fsSL https://raw.githubusercontent.com/ppopcn/shoes_all/refs/heads/main/singbox_all.sh | sudo bash
```

### Xray 全家桶（5 协议，TCP/TLS 系）

```bash
curl -fsSL https://raw.githubusercontent.com/ppopcn/shoes_all/refs/heads/main/xray_all.sh | sudo bash
```

### 装之前先自检（可选）

```bash
# 关键字命中说明脚本是含目标特性的新版（grep -q 无输出是正常的）
U=https://raw.githubusercontent.com/ppopcn/shoes_all/refs/heads/main/shoes_all.sh
curl -fsSL "$U" | grep -q 'generate-reality-keypair' && curl -fsSL "$U" | sudo bash

U=https://raw.githubusercontent.com/ppopcn/shoes_all/refs/heads/main/singbox_all.sh
curl -fsSL "$U" | grep -q 'reality-in' && curl -fsSL "$U" | sudo bash

U=https://raw.githubusercontent.com/ppopcn/shoes_all/refs/heads/main/xray_all.sh
curl -fsSL "$U" | grep -q 'x25519' && curl -fsSL "$U" | sudo bash
```

### 只装部分协议

```bash
# shoes：可选 hy2 tuic ss vless vmess trojan reality
curl -fsSL https://raw.githubusercontent.com/ppopcn/shoes_all/refs/heads/main/shoes_all.sh \
  | sudo PROTOCOLS=hy2,tuic,ss,vless,vmess,trojan,reality bash

# sing-box：可选 mt hy2 tuic ss vless vmess trojan reality（旧写法 ssr 也兼容）
curl -fsSL https://raw.githubusercontent.com/ppopcn/shoes_all/refs/heads/main/singbox_all.sh \
  | sudo PROTOCOLS=mt,hy2,tuic,ss,vless,vmess,trojan,reality bash

# xray：可选 reality vless vmess trojan ss
curl -fsSL https://raw.githubusercontent.com/ppopcn/shoes_all/refs/heads/main/xray_all.sh \
  | sudo PROTOCOLS=reality,vless,vmess,trojan,ss bash
```

---

## 环境变量参数

三个脚本都用**环境变量**传参（前缀形式），注意不是位置参数——`sh xxx.sh PROTOCOLS=vless` 会把 `PROTOCOLS=vless` 当子命令报错：

```bash
sudo PROTOCOLS=vless bash shoes_all.sh              # 本地文件
curl -fsSL .../shoes_all.sh | sudo PROTOCOLS=hy2 bash   # curl | bash
sudo env PROTOCOLS=vless bash shoes_all.sh          # 已 sudo 时
```

### PROTOCOLS 可选值

| 协议          | shoes_all.sh | singbox_all.sh | xray_all.sh         |
| ----------- | ------------ | -------------- | ------------------- |
| MTPROXY     | ❌ 不支持        | `mt`           | ❌ 不支持               |
| Hysteria2   | `hy2`        | `hy2`          | ❌ 不支持               |
| TUIC v5     | `tuic`       | `tuic`         | ❌ 不支持               |
| Shadowsocks | `ss`         | `ss`           | `ss`                |
| VLESS       | `vless`（独立）  | `vless`（独立）    | `vless`（TLS+WS）     |
| VMess       | `vmess`（独立）  | `vmess`（独立）    | `vmess`（TLS+WS）     |
| Trojan      | `trojan`     | `trojan`       | `trojan`            |
| Reality     | `reality`    | `reality`      | `reality`（含 Vision） |

- 不传 `PROTOCOLS` 时默认全部安装：shoes 为 `hy2,tuic,ss,vless,vmess,trojan,reality`；sing-box 为 `mt,hy2,tuic,ss,vless,vmess,trojan,reality`；xray 为 `reality,vless,vmess,trojan,ss`
- 传其他值会直接报错；逗号分隔、可任意组合；sing-box 兼容旧写法 `ssr`

### 通用参数（两边风格一致）

| 变量                                                           | 默认                                                                         | 说明                                                                                                         |
| ------------------------------------------------------------ | -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `HY2_PORT` / `TUIC_PORT` / `SS_PORT`                         | 443 / 8443 / 8388                                                          | 各协议端口                                                                                                      |
| `VLESS_PORT` / `VMESS_PORT` / `TROJAN_PORT` / `REALITY_PORT` | 8989 / 8990 / 8444 / 8899                                                  | 各协议端口（xray 的 Reality 默认占 443）                                                                              |
| `REALITY_DEST`                                               | shoes/sing-box: `www.microsoft.com:443`；**xray: `www.cloudflare.com:443`** | Reality 握手目标（需支持 TLS1.3+H2）。⚠️ Xray 别用 microsoft.com：其证书记录 8273 字节超过 REALITY 解析器 8192 上限，握手必失败（XTLS #6356） |
| `DOMAIN`                                                     | 随机伪装域名                                                                     | SNI / 自签证书域名                                                                                               |
| `MIRROR`                                                     | （空）                                                                        | GitHub 下载镜像前缀，如 `https://ghfast.top/`                                                                      |
| `SERVER_ADDR`                                                | 自动探测                                                                       | 手动指定对外 IP（生成链接用）                                                                                           |
| `LOG_LEVEL`                                                  | `info`（xray: `warning`）                                                    | 日志级别，排错可设 `debug`                                                                                          |
| `CERT_FILE` / `KEY_FILE`                                     | （自动生成）                                                                     | 使用已有证书                                                                                                     |
| `HY2_PASSWORD` / `TUIC_UUID` / `VLESS_UUID` 等凭据              | 随机生成                                                                       | 已有配置会自动复用，无需每次传                                                                                            |

### 脚本专属参数

| 变量            | 适用           | 说明                                                        |
| ------------- | ------------ | --------------------------------------------------------- |
| `SHOES_TAG`   | shoes        | 默认 `v0.3.3`（已验证）；传 `latest` 联网取最新 release                 |
| `SINGBOX_TAG` | sing-box     | 默认 `v1.14.1-extended-2.7.2`（已验证）；传 `latest` 取最新（API 失败报错） |
| `XRAY_TAG`    | xray         | 默认 `v26.3.27`（已验证）；传 `latest` 取最新（API 失败回退默认）             |
| `FORCE_BIN=1` | sing-box     | 强制重新下载二进制                                                 |
| `<NAME>_V`    | shoes / xray | 显式覆盖凭据，如 `HY2_PASSWORD_V=xxx`（重装想固定密码时用）                  |

> 三个脚本统一策略：**默认锁死脚本内已验证的版本**（部署结果可复现），需要尝鲜时显式 `XXX_TAG=latest`。

### 组合示例

```bash
# 只装 Reality，指定镜像
sudo PROTOCOLS=reality MIRROR=https://ghfast.top/ bash singbox_all.sh

# 只装 hy2，固定密码与端口
sudo PROTOCOLS=hy2 HY2_PORT=443 HY2_PASSWORD_V=mypass123 bash shoes_all.sh

# 只装 VLESS+VMess，指定域名
sudo PROTOCOLS=vless,vmess DOMAIN=foo.example.com bash shoes_all.sh
```

---

## 默认端口

**shoes_all.sh**

| 协议          | 端口       | 传输        | 说明                       |
| ----------- | -------- | --------- | ------------------------ |
| Hysteria2   | 443/udp  | QUIC      | 抗封锁首选                    |
| TUIC v5     | 8443/udp | QUIC      | 需 `alpn=h3`              |
| Shadowsocks | 8388/tcp | TCP       | aes-256-gcm；**仅 TCP，内核不支持 UDP 转发** |
| VLESS       | 8989/tcp | TCP + TLS | 自签证书                     |
| VMess       | 8990/tcp | TCP + TLS | 加密方式须 `aes-128-gcm`      |
| Trojan      | 8444/tcp | TCP + TLS |                          |
| Reality     | 8899/tcp | TCP       | VLESS + XTLS Vision，无需证书 |

**singbox_all.sh**：另有 MTPROXY 443/tcp（与 HY2 的 443/udp 共存），VLESS/VMess 走 TLS + WS，端口同上表。sing-box 的 Shadowsocks 是 `8388/tcp+udp`，UDP 转发可用。

**xray_all.sh**

| 协议          | 端口           | 传输        | 说明                       |
| ----------- | ------------ | --------- | ------------------------ |
| Reality     | 443/tcp      | TCP       | VLESS + XTLS Vision，无需证书 |
| VLESS       | 8989/tcp     | TLS + WS  | 路径 `/vless`              |
| VMess       | 8990/tcp     | TLS + WS  | 路径 `/vmess`，aid=0        |
| Trojan      | 8444/tcp     | TCP + TLS |                          |
| Shadowsocks | 8388/tcp+udp | TCP+UDP   | aes-256-gcm              |

---

## 常用命令

安装完会把脚本自拷贝成本地命令（shoes 为 `shoes-all`，sing-box 为 `singbox-all`，xray 为 `xray-all`）；用 `curl | bash` 装的时候脚本会自己回源下载一份到 `/usr/local/bin/`，所以本地命令同样可用。

```bash
shoes-all info            # 重新打印凭据与分享链接
shoes-all status          # 服务状态与监听端口
shoes-all logs [N]        # 最近 N 行日志
shoes-all update          # 升级到上游最新内核并重启（SHOES_TAG=vX.Y.Z 可钉版本，配置不变）
shoes-all plan            # 只打印端口计划，不安装
shoes-all uninstall       # 卸载（KEEP_CONFIG=1 保留配置）

singbox-all info/status/logs/uninstall   # 同上的 sing-box 版本（没有 update，升级走 install）
xray-all info/status/logs/update/uninstall   # 同上的 xray 版本
```

配置文件与凭据位置：

- shoes：`/etc/shoes/all.yaml`、`/etc/shoes/creds.env`（600）、`/etc/shoes/cert.pem`
- sing-box：`/etc/sing-box/all.json`、`/etc/sing-box/reality.json`（Reality 密钥对）
- xray：`/usr/local/etc/xray/config.json`、`/usr/local/etc/xray/creds.env`（600）、`/usr/local/etc/xray/cert.pem`

---

## 内核版本与升级

**安装永远锁定已验证版本**：三脚本各锁一个测试过的版本（见下表），重复 install 已装同版本会直接跳过下载，保证部署结果可复现。

**`update` 默认拉上游最新版**（仅 shoes / xray 有此子命令），想钉版本时显式带 `XXX_TAG=`：

```bash
# shoes / xray：一条命令升级到上游最新 release（配置与凭据不变，装完自动重启）
sudo shoes-all update
sudo xray-all update

# 钉住某个版本（退化为"按版本修复/重装"，不再追新）
sudo SHOES_TAG=v0.3.3 shoes-all update
sudo XRAY_TAG=v26.3.27 xray-all update

# sing-box：没有 update 子命令，带 latest 重跑 install（配置/凭据复用）
sudo SINGBOX_TAG=latest bash singbox_all.sh install
sudo SINGBOX_TAG=v1.14.3-extended-2.7.3 bash singbox_all.sh install
```

| 脚本       | 安装锁定默认                     | update 默认      | latest 行为                                    |
| -------- | ------------------------ | --------------- | -------------------------------------------- |
| shoes    | `v0.3.3`                 | 上游最新            | 查 GitHub API，失败回退锁定版本并告警                     |
| sing-box | `v1.14.1-extended-2.7.2` | （无 update 子命令）  | 查 GitHub API，失败直接报错（可 `SINGBOX_TAG=v...` 指定） |
| xray     | `v26.3.27`               | 上游最新            | 查 GitHub API，失败回退锁定版本并告警                     |


> 设计意图：**install 求稳**（新机器装出来的永远是验证过的版本）、**update 求新**（日常一条命令追上游）、**钉版本求可控**（`XXX_TAG=vX.Y.Z` 显式覆盖两者）。显式设置的 `XXX_TAG` 优先级最高，install 和 update 都认。

---

## 重装会覆盖吗

**不会冲突，是就地覆盖**：同一个服务先停再起，不会跑出第二个进程。

| 内容                         | 行为                                 |
| -------------------------- | ---------------------------------- |
| 凭据（密码 / UUID / Reality 密钥） | 从旧配置读出来复用，客户端不失效                   |
| TLS 证书                     | 已存在直接复用                            |
| 配置文件                       | 覆盖重渲染；旧文件备份为 `.bak.<时间戳>`，只留最近 3 份 |
| 防火墙规则                      | 幂等添加，不会重复堆积                        |

注意：端口、`DOMAIN`、`REALITY_DEST` 这类参数会在重装时按当前环境变量/默认值重新计算，改过端口的话重装要带上同样的变量。

---

## 支持的平台

| 发行版                          | init    | 包管理       | 防火墙                  |
| ---------------------------- | ------- | --------- | -------------------- |
| Debian / Ubuntu              | systemd | apt       | ufw → iptables       |
| CentOS / RHEL / Rocky / Alma | systemd | dnf 或 yum | firewalld → iptables |
| Alpine                       | OpenRC  | apk       | iptables（sing-box 自动持久化；shoes/xray 仅插入规则，重启后可能丢失）    |

- 架构：x86_64 / aarch64（shoes 用官方 musl 静态包，glibc 发行版同样可用；无 32 位 ARM 包）
- RHEL 系若 SELinux 为 Enforcing，脚本会提示；服务起不来时先看 `/var/log/audit/audit.log`
- 云服务器安全组需在控制台单独放行，脚本管不到
- **实测范围**：主要验证在 Debian 13（systemd）上完成；RHEL / Alpine 分支做了静态审查与单元渲染校验，未逐一实机跑通，用前建议先 `plan` 看一眼端口计划
- sing-box 脚本重装复用旧凭据依赖 `python3`（解析 JSON）；python3 不可用时脚本只打警告，重装会重新生成凭据导致客户端失效——Alpine/RHEL 最小系统请先装 python3

---

## 实测记录

环境：Debian GNU/Linux 12 (bookworm) / x86_64 / OpenSSL 3.0.22。

方法：服务端装全家桶后，客户端在**同一台机器的 127.0.0.1** 上回环直连各入站（xray 26.3.27 充当 TCP 系客户端、sing-box 充当 QUIC 系客户端），逐协议独立建连并请求 `https://www.gstatic.com/generate_204`，返回 204 才记为通过。

| 脚本                | 通过 / 总数 | 明细                                                       |
| ----------------- | ------- | -------------------------------------------------------- |
| `shoes_all.sh`    | 5 / 5   | ss、vless、vmess、trojan、reality 全通（hy2/tuic 仅确认 UDP 监听就绪，未做 QUIC 客户端验证） |
| `singbox_all.sh`  | 7 / 7   | ss、vless、vmess、trojan、reality、hy2、tuic 全通                 |
| `xray_all.sh`     | 5 / 5   | ss、vless(WS)、vmess(WS)、trojan、reality 全通                  |

补充验证：

- **Shadowsocks UDP 中转**：xray 版实测通过（`dokodemo-door` → SS UDP → `8.8.8.8:53` 解析成功）；shoes 版内核不支持，sing-box 版监听 `8388/udp`。
- **二次 install**：三个脚本都会打印「已安装 x.y.z, 跳过下载」，不重复拉二进制。
- **卸载**：服务单元、配置目录、二进制均清除；用户用 `CERT_FILE` 指定的证书会被保留；防火墙规则保留但给出清理命令。
- **未覆盖**：MTPROXY 的端到端登录需要真实 Telegram 账号，本轮只验证了入站工作正常（连接被接住并走伪装逻辑）与配置合法性；hy2/tuic 的 QUIC 回环在 sing-box 版做过，shoes 版因缺客户端未做。

---

## 踩过的坑（客户端连不上先看这里）

| 现象                                                                                          | 原因                                                                                                                       | 处理                                                             |
| ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------- |
| VMess 报 `Standard format data stream was not requested`                                     | 客户端 VMess 加密方式选了 `auto / none / zero`，会关闭标准数据流                                                                           | 改成 `aes-128-gcm`（脚本生成的链接已固定 `scy=aes-128-gcm`）                 |
| TUIC 握手失败                                                                                   | 客户端没带 `alpn=h3`，或服务端开了 0-RTT                                                                                             | 链接已带 `alpn=h3`，服务端 `zero_rtt_handshake=false`                  |
| Reality 报 `VLESS addons not supported ... VISION`                                           | 客户端带 `flow=xtls-rprx-vision` 但服务端未开 vision                                                                               | 服务端 `vision: true`，脚本已默认开启                                     |
| 日志里 `invalid client protocol version ... got 71`                                            | 客户端延迟探测往端口打了明文 `GET`（71 是字母 G）                                                                                           | 忽略，不是故障                                                        |
| `shoes-all logs` 没输出（Alpine）                                                                | 旧版 OpenRC 用 start-stop-daemon，忽略 output_log                                                                              | 已改用 `supervise-daemon`，更新脚本后正常                                 |
| 拉到的脚本是旧版                                                                                    | raw 的 Fastly 缓存 300 秒                                                                                                    | 等 5 分钟，或按 commit sha 拉                                         |
| xray Reality 握手失败，日志 `REALITY: processed invalid connection ... handshake did not complete` | `REALITY_DEST` 用了 [www.microsoft.com，其证书记录](http://www.microsoft.com，其证书记录) 8273 字节超过 REALITY 解析器 8192 硬编码上限（XTLS #6356） | 换 dest，如 `www.cloudflare.com:443`（xray 脚本已默认），服务端和客户端 SNI 要同步改 |
| Xray 26.x 客户端报 `The feature "allowInsecure" has been removed`                               | 新版 Xray 客户端移除了 allowInsecure，迁到 `pinnedPeerCertSha256`（hex 编码的证书 DER sha256）                                             | 客户端改用 pin，或用支持 insecure 的客户端内核；有域名建议挂真证书一劳永逸                   |
| xray 版 VLESS/VMess 连上但没流量，服务端日志 `http2: server: error reading preface ... bogus greeting` | 这两个入站是 **WS 传输**，客户端漏配 `path` / `Host` 时，TLS 层通了但 HTTP Upgrade 不成立                                                              | 客户端补上 `path=/vless`（或 `/vmess`）与 `Host`=SNI；这一点和 shoes 版的裸 TCP 不同 |
| sing-box 的 443 端口「连上了但没数据」                                                              | MTPROXY 用 `domain_fronting_port=443` + secret 尾部域名做伪装，非 MTPROXY 流量会被转发到 `www.cloudflare.com:443`（返回 TLS Alert）。这是设计行为，不是串线 | 检查 secret 是否用完整 `ee...` 串、客户端是否开了 MTPROXY 类型；抓包会看到目标域名是 cloudflare |
| shoes 的 Shadowsocks 没有 UDP 中转                                                              | shoes 内核的 shadowsocks 入站只支持 `type/cipher/password`，无 UDP 配置项（见上游 CONFIG.md）                                              | 需要 SS UDP（游戏、DNS）就用 sing-box 或 xray 版；shoes 版只能代理 TCP            |
| 卸载后 `ufw status` 里端口还在放行                                                                | 卸载**不会自动删防火墙规则**（避免误删你自建的规则），只打印可复制的删除命令                                                                                     | 按卸载输出的 `ufw delete allow <port>` 逐条清；换内核前先清一次能避免规则越积越多      |

---

## 安全提示

- 脚本以 root 运行，会写 `/etc`、注册系统服务、改防火墙规则，先读一遍再用
- 自签证书需要客户端开「允许不安全证书」；有域名的话建议挂真证书（`CERT_FILE` / `KEY_FILE`）
- 凭据文件权限 600，分享链接等同于账号密码，别贴到公开渠道
- 仅供个人自建代理、内网穿透等合规用途，请遵守当地法律法规

### 供应链与信任边界（务必了解）

- **安装方式可变**：`curl ... | sudo bash` 拉的是 `main` 分支最新提交，仓库没有 tag/签名；想要可复现安装，用 commit sha 固定：`https://raw.githubusercontent.com/ppopcn/shoes_all/<sha>/xxx.sh`。脚本自装的本地命令（如 `xray-all`）也从 `main` 拉取，可能与本次执行的版本不同
- **镜像风险**：`MIRROR`（如 `https://ghfast.top`）能解决 GitHub 不通的问题，但等于多信任一个中间方；配合哈希校验才安全，而目前 **shoes / xray 下载二进制未做 sha256 校验**（sing-box 有，但依赖 GitHub API 可用）。敏感环境建议不要用镜像
- **自签证书 + 随机 SNI 不等于伪装**：这类 TLS 配置能被主动探测识别，抗探测请优先用 Reality；另外三个脚本的 systemd 单元均以 root 运行，未做 hardening
- **sing-box 用的是第三方 fork**（`shtorm-7/sing-box-extended`，为了 MTPROXY 能力），需要额外信任该 fork 的发布链；对供应链敏感的场景改用官方 sing-box + `PROTOCOLS` 里去掉 `mt`

---

## License

MIT
