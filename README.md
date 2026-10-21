# 一键部署脚本合集

两台「单进程 · 单配置 · 全协议」代理服务端一键部署脚本，都是**一个脚本装完、跑一个进程、出一张凭据表**。

| 脚本 | 内核 | 协议数 | 适用 |
|---|---|---|---|
| [`shoes_all.sh`](shoes_all.sh) | [cfal/shoes](https://github.com/cfal/shoes)（Rust，静态 musl 二进制） | 7 | 轻量，无依赖，跑起来就是一个小二进制 |
| [`singbox_all.sh`](singbox_all.sh) | [shtorm-7/sing-box-extended](https://github.com/shtorm-7/sing-box-extended) | 8 | 需要 MTPROXY / 更多扩展能力时用 |

---

## 一键安装

### shoes 全家桶（7 协议）

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/ppopcn/shoes_all@main/shoes_all.sh | sudo bash
```

<details>
<summary>raw.githubusercontent 地址（有 CDN 缓存，可能拉到旧版）</summary>

```bash
curl -fsSL https://raw.githubusercontent.com/ppopcn/shoes_all/refs/heads/main/shoes_all.sh | sudo bash
```

`raw.githubusercontent.com` 走 Fastly 缓存（`max-age=300`），刚 push 后短时间内可能仍是旧版，`-H 'Cache-Control: no-cache'` 和 `?v=时间戳` 都绕不过去。要立刻拿到指定版本，用 commit sha 固定：

```bash
curl -fsSL https://raw.githubusercontent.com/ppopcn/shoes_all/<commit-sha>/shoes_all.sh | sudo bash
```
</details>

### sing-box 全家桶（8 协议 且支持MTPROXY）

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/ppopcn/shoes_all@main/singbox_all.sh | sudo bash
```

### 装之前先自检（可选）

```bash
# shoes：应该输出 1（脚本里含 generate-reality-keypair）
U=https://cdn.jsdelivr.net/gh/ppopcn/shoes_all@main/shoes_all.sh
curl -fsSL "$U" | grep -q 'generate-reality-keypair' && curl -fsSL "$U" | sudo bash

# sing-box：应该输出 10（脚本里含 10 处 reality-in）
U=https://cdn.jsdelivr.net/gh/ppopcn/shoes_all@main/singbox_all.sh
curl -fsSL "$U" | grep -q 'reality-in' && curl -fsSL "$U" | sudo bash
```

### 只装部分协议

```bash
# shoes：可选 hy2 tuic ss vless vmess trojan reality
curl -fsSL https://cdn.jsdelivr.net/gh/ppopcn/shoes_all@main/shoes_all.sh \
  | sudo PROTOCOLS=hy2,reality bash

# sing-box：可选 mt hy2 tuic ssr vless trojan reality
curl -fsSL https://cdn.jsdelivr.net/gh/ppopcn/shoes_all@main/singbox_all.sh \
  | sudo PROTOCOLS=hy2,tuic,trojan bash
```

---

## 默认端口

**shoes_all.sh**

| 协议 | 端口 | 传输 | 说明 |
|---|---|---|---|
| Hysteria2 | 443/udp | QUIC | 抗封锁首选 |
| TUIC v5 | 8443/udp | QUIC | 需 `alpn=h3` |
| Shadowsocks | 8388/tcp | TCP | aes-256-gcm |
| VLESS | 8989/tcp | TCP + TLS | 自签证书 |
| VMess | 8990/tcp | TCP + TLS | 加密方式须 `aes-128-gcm` |
| Trojan | 8444/tcp | TCP + TLS | |
| Reality | 8899/tcp | TCP | VLESS + XTLS Vision，无需证书 |

**singbox_all.sh**：另有 MTPROXY 443/tcp（与 HY2 的 443/udp 共存），VLESS/VMess 走 TLS + WS，端口同上表。

---

## 常用命令

安装完会把脚本自拷贝成本地命令（shoes 为 `shoes-all`，sing-box 为 `singbox-all`）；用 `curl | bash` 装的时候脚本会自己回源下载一份到 `/usr/local/bin/`，所以本地命令同样可用。

```bash
shoes-all info            # 重新打印凭据与分享链接
shoes-all status          # 服务状态与监听端口
shoes-all logs [N]        # 最近 N 行日志
shoes-all update          # 升级内核并重启（配置不变）
shoes-all plan            # 只打印端口计划，不安装
shoes-all uninstall       # 卸载（KEEP_CONFIG=1 保留配置）

singbox-all info/status/logs/uninstall   # 同上的 sing-box 版本
```

配置文件与凭据位置：

- shoes：`/etc/shoes/all.yaml`、`/etc/shoes/creds.env`（600）、`/etc/shoes/cert.pem`
- sing-box：`/etc/sing-box/all.json`、`/etc/sing-box/reality.json`（Reality 密钥对）

---

## 重装会覆盖吗

**不会冲突，是就地覆盖**：同一个服务先停再起，不会跑出第二个进程。

| 内容 | 行为 |
|---|---|
| 凭据（密码 / UUID / Reality 密钥） | 从旧配置读出来复用，客户端不失效 |
| TLS 证书 | 已存在直接复用 |
| 配置文件 | 覆盖重渲染；旧文件备份为 `.bak.<时间戳>`，只留最近 3 份 |
| 防火墙规则 | 幂等添加，不会重复堆积 |

注意：端口、`DOMAIN`、`REALITY_DEST` 这类参数会在重装时按当前环境变量/默认值重新计算，改过端口的话重装要带上同样的变量。

---

## 支持的平台

| 发行版 | init | 包管理 | 防火墙 |
|---|---|---|---|
| Debian / Ubuntu | systemd | apt | ufw → iptables |
| CentOS / RHEL / Rocky / Alma | systemd | dnf 或 yum | firewalld → iptables |
| Alpine | OpenRC | apk | iptables（规则自动持久化） |

- 架构：x86_64 / aarch64（shoes 用官方 musl 静态包，glibc 发行版同样可用；无 32 位 ARM 包）
- RHEL 系若 SELinux 为 Enforcing，脚本会提示；服务起不来时先看 `/var/log/audit/audit.log`
- 云服务器安全组需在控制台单独放行，脚本管不到

---

## 踩过的坑（客户端连不上先看这里）

| 现象 | 原因 | 处理 |
|---|---|---|
| VMess 报 `Standard format data stream was not requested` | 客户端 VMess 加密方式选了 `auto / none / zero`，会关闭标准数据流 | 改成 `aes-128-gcm`（脚本生成的链接已固定 `scy=aes-128-gcm`） |
| TUIC 握手失败 | 客户端没带 `alpn=h3`，或服务端开了 0-RTT | 链接已带 `alpn=h3`，服务端 `zero_rtt_handshake=false` |
| Reality 报 `VLESS addons not supported ... VISION` | 客户端带 `flow=xtls-rprx-vision` 但服务端未开 vision | 服务端 `vision: true`，脚本已默认开启 |
| 日志里 `invalid client protocol version ... got 71` | 客户端延迟探测往端口打了明文 `GET`（71 是字母 G） | 忽略，不是故障 |
| `shoes-all logs` 没输出（Alpine） | 旧版 OpenRC 用 start-stop-daemon，忽略 output_log | 已改用 `supervise-daemon`，更新脚本后正常 |
| 拉到的脚本是旧版 | raw 的 Fastly 缓存 300 秒 | 换 jsdelivr，或按 commit sha 拉 |

---

## 安全提示

- 脚本以 root 运行，会写 `/etc`、注册系统服务、改防火墙规则，先读一遍再用
- 自签证书需要客户端开「允许不安全证书」；有域名的话建议挂真证书（`CERT_FILE` / `KEY_FILE`）
- 凭据文件权限 600，分享链接等同于账号密码，别贴到公开渠道
- 仅供个人自建代理、内网穿透等合规用途，请遵守当地法律法规

---

## License

MIT
