# NetShape Manager

面向 Linux 中转机、Emby/Jellyfin 反代和高 RTT 链路的 SSH 交互式网络调优工具。它会根据你选择的简单方案、到本地的大致延迟、机器内存和内核能力生成保守的 TCP 参数，并自动选择 VPS 支持的限速队列，减少排队、重传和播放断流。

> 本项目不会上传硬件、IP、域名或运行数据，也不包含作者或使用者的个人信息。

## 能做什么

- SSH 中文交互面板；安装后直接运行 `netshape`
- 自动识别 CPU、RAM、Swap、默认出口网卡、MTU、内核和 BBR 支持
- 双层限速：单条 TCP 连接压在观看设备家宽以下（500M 家宽→430/450，1G 家宽→850/900），整机总出口按 VPS 端口保护（2.5G 口→2300，1G 口→900，可设 0 不限）
- 多设备在不同家宽环境同时观看时各自跑满自己的带宽，互不挤占；单条流不会打爆"VPS 到家"的跨境路径（这是重传暴涨和断流的根源）
- HTB + fq maxrate 实现；HTB 不可用自动回退 TBF，再不行仅保留单连接上限
- 可选不限速自适应，仅推荐丢包极少的干净直连线路（选择时需二次确认）
- 询问到本地的大致延迟；不知道可直接使用默认值
- 自定义单连接上限、整机上限或 RTT 时同步重算 TCP 参数
- 使用独立 sysctl 文件，不覆盖 `/etc/sysctl.conf`
- 检测旧 sysctl 和旧 `tc` 服务冲突，但不会擅自删除其他工具的配置
- 本机装有 Nginx 时生成 Emby 不限流片段并只读审计限速项；未装 Nginx（纯中转）自动跳过
- systemd 开机恢复、状态查看、重传计数和完整卸载

## 支持环境

- 使用 systemd 的 Linux 发行版
- root 或 sudo 权限
- `bash`、`ip`、`tc`、`sysctl`
- `ip`/`tc` 通常由 `iproute2` 提供，`sysctl` 通常由 `procps` 提供
- 内核支持 BBR 时自动启用；不支持时回退到 Cubic，不会强行安装或更换内核

OpenVZ/LXC 等受限容器可能不允许修改 sysctl 或 qdisc。脚本会报告失败，不会声称已经生效。

安装时若检测到会直接覆盖 root qdisc 的旧 `netshape.service`、`tc-fq-maxrate.service` 或 `netpace.service`，会将其停用并记录；不会删除对应文件。其他 sysctl 或网络服务只报告，不自动修改。

## 安装

### 一键交互安装（推荐）

在目标 Linux VPS 上执行：

```bash
curl -fsSL --retry 3 https://raw.githubusercontent.com/bear4f/netshape-manager/main/netshape-manager.sh -o /tmp/netshape-manager.sh && sudo bash /tmp/netshape-manager.sh install
```

安装完成后直接运行 SSH 面板：

```bash
sudo netshape
```

### 一键无人值守安装

2.5G 口 VPS、观看设备 500M 家宽、160ms RTT 示例：

```bash
curl -fsSL --retry 3 https://raw.githubusercontent.com/bear4f/netshape-manager/main/netshape-manager.sh -o /tmp/netshape-manager.sh && sudo bash /tmp/netshape-manager.sh install --non-interactive --rate 430 --total 2300 --rtt 160
```

### 本地文件安装

下载后在服务器执行：

```bash
chmod +x netshape-manager.sh
sudo ./netshape-manager.sh install
```

向导会询问：

1. 你本地连接 VPS 大约多少毫秒；不知道可直接回车；
2. VPS 端口多大（2.5G/1G/500M/不限），决定整机总出口保护；
3. 观看设备的家宽档位（500M→430/450，1G→850/900），决定单条连接上限。

无人值守安装示例（2.5G 口、500M 家宽稳定档）：

```bash
sudo ./netshape-manager.sh install \
  --non-interactive \
  --rate 430 \
  --total 2300 \
  --rtt 160
```

1G 口 VPS、1G 家宽：

```bash
sudo ./netshape-manager.sh install \
  --non-interactive \
  --rate 850 \
  --total 900 \
  --rtt 160
```

指定非默认路由网卡时可加 `--iface eth0`。默认使用 IPv4 默认路由网卡，找不到时再尝试 IPv6 默认路由。

## 日常使用

打开面板：

```bash
sudo netshape
```

常用快捷命令：

```bash
sudo netshape 430                # 单条连接 ≤430M（500M 家宽·Emby 稳定，推荐）
sudo netshape 450                # 单条连接 ≤450M（500M 家宽·速度优先）
sudo netshape 850                # 单条连接 ≤850M（1G 家宽·稳定）
sudo netshape 900                # 单条连接 ≤900M（1G 家宽·速度优先）
sudo netshape total 2300         # 整机总出口（按 VPS 端口；0 = 不限制）
sudo netshape adaptive           # 不限速自适应（仅干净直连线路）
sudo netshape rtt 160            # 更新到本地的大致延迟
sudo netshape status
sudo netshape diagnose
sudo netshape off                # 暂停限速，保留 fq/fq_codel
sudo netshape apply              # 恢复持久化配置
```

每次修改策略、上限或 RTT，都会重新计算 TCP 缓冲并应用 qdisc。持久化配置位于 `/etc/netshape-manager.conf`。

## Emby + Nginx 不限流

仅当这台 VPS 自己运行 Nginx 反代 Emby 时才需要本节。如果你只是通过中转访问别人的 Emby（无法改动对方服务器），跳过本节即可：Emby 流量经过中转机时就是普通 TCP 连接，前面的 TCP 调优已经覆盖。安装时若未检测到本机 Nginx，脚本会自动跳过片段生成并说明原因。

生成片段：

```bash
sudo netshape nginx-snippet
```

然后在 Emby 的 `location` 块中加入：

```nginx
include /etc/nginx/snippets/netshape-emby-proxy.conf;
```

检查完整 Nginx 配置中是否还有 `limit_rate`、`proxy_limit_rate`、`limit_conn`、`limit_req` 或过短的代理超时：

```bash
sudo netshape nginx-audit
sudo nginx -t
sudo systemctl reload nginx
```

这里的“不限流”指 Nginx 不对单个 Emby 请求设置应用层速率上限；整机总出口档位仍然生效，它保护的是线路不被打爆，两者不冲突。脚本不会自动修改现有站点，因为不同面板和反代模板的结构差异很大。

## 调优原理

### 1. 双层限速：单连接上限＋整机总出口

关键认识：VPS 端口（例如 2.5G）远大于每个观看者的家宽（300M/500M/1G）。重传雪崩发生在"VPS 到某一个家"的路径上——跨境线路普遍有强制限速（policing）与拥塞，BBR 不把丢包当拥塞信号，单条流不设上限时会按探测到的峰值持续超发，撞上 policer 后重传失控（实测 15 秒十几万次），Emby 随之断流。

因此两层限速各管一件事：

- **单条 TCP 连接上限（fq maxrate）**：压在观看设备家宽以下（500M 家宽→430/450，1G 家宽→850/900）。每条流从源头就不超发自己那条到家的路径，这是低重传的根本。
- **整机总出口（HTB）**：按 VPS 端口设置（2.5G 口→2300，1G 口→900），只防止打满物理端口，不参与"分配"带宽。

多设备同时观看时，每台设备的连接各自受单连接上限保护、各自跑满自己的家宽；4–5 人同时用 500M 家宽合计约 2.2G，2.5G 口完全容纳，互不挤占。

不限速自适应模式只适合丢包极少的干净直连线路，选择时需二次确认。

整形只控制服务器发出的流量。它不能修复上游拥塞、入口丢包、源站转码不足或客户端 Wi-Fi 问题。

### 2. TCP 缓冲

脚本使用：

```text
BDP(bytes) = rate(Mbps) × RTT(ms) × 125
目标缓冲   = 2 × BDP（按 1 MiB 取整）
```

并按 RAM 档位限制在 8–128 MiB。缓冲刻意不取过大的整数倍：过大的缓冲会允许 BBR 在被限速的线路上囤积巨大的拥塞窗口，正是重传暴涨的来源之一。TCP 自动调优按需增长缓冲，并不在每个连接建立时立即分配最大值。

`net.ipv4.tcp_mem` 按内存档位设置（1–4 GiB 档采用在 2 GiB 中转机上长期验证稳定的数值），而不是固定复制某一台机器的页数，避免小内存 VPS 过度分配或大内存机器过早进入内存压力。

另外并入一组在跨境中转链路上实测更稳的开关：关闭 ECN、F-RTO 和 TCP Fast Open（部分中间设备会把它们变成黑洞），`tcp_no_metrics_save` 避免缓存坏路径的旧指标，`tcp_rmem` 初始值收敛到 87380 避免视频拖动时突发过猛，`tcp_tw_reuse`/`tcp_fin_timeout` 加快中转短连接回收，`vm.min_free_kbytes` 为网络分配保留内存余量。

### 3. BBR 与兼容性

脚本尝试加载内核已有的 `tcp_bbr`，随后读取内核公布的可用拥塞控制算法。存在 BBR 才启用，否则回退 Cubic。它不会下载第三方内核，也不会绕过容器限制。

## 排障建议

先收集：

```bash
sudo netshape status
sudo netshape diagnose
```

重点观察：

- 队列是否为 HTB + fq maxrate（class 的 rate/ceil = 整机总出口，fq 的 maxrate = 单连接上限）；
- qdisc/class 的 `dropped`、`overlimits` 是否持续快速增长；
- TCP 重传计数是否在播放时快速增加；
- Nginx error log 是否出现 upstream timeout、client prematurely closed；
- Emby 是否正在转码，CPU、磁盘或源站上行是否成为瓶颈；
- MTU/PMTU、隧道封装和跨境线路是否造成黑洞或持续丢包。

若当前档位仍断流或重传高，先降一档（450→430，900→850）观察，再排查客户端路径丢包、MTU、Nginx/Emby 日志和转码负载。只用一次测速结果不能证明流媒体长连接稳定。

## 开发自检

仓库内置不需要 root、也不会修改系统的计算测试：

```bash
bash -n netshape-manager.sh
bash tests/self-test.sh
```

## 卸载

```bash
sudo netshape uninstall
```

卸载会：

- 停用并删除自身 systemd 服务；
- 删除自身命令、持久化配置和 sysctl 文件；
- 尝试将出口恢复为 `fq`，不支持时回退 `fq_codel`；
- 重新加载剩余系统 sysctl。

Nginx 片段和历史备份会保留，避免意外破坏正在使用的反代。确认不再需要后可手动删除。

## 风险与边界

- 在远程 SSH 会话中修改 qdisc 存在网络短暂抖动风险，建议保留一个备用 SSH 会话或控制台。
- 脚本只处理默认出口网卡的 egress；多出口、策略路由、IFB ingress、WireGuard/OpenVPN 内层接口需要单独设计。
- “稳定”取决于端到端链路。工具可以减少本机排队和突发，但不能保证任何线路绝不掉流。
- 不建议和其他 BBR、`tc`、加速器或主机面板网络优化功能同时使用；先运行 `netshape diagnose` 检查冲突。

## 参考资料

- [Linux kernel IP sysctl documentation](https://docs.kernel.org/networking/ip-sysctl.html)
- [Linux traffic-control netlink specification](https://docs.kernel.org/netlink/specs/tc.html)
- [NGINX proxy module documentation](https://nginx.org/en/docs/http/ngx_http_proxy_module.html)
- [NGINX core module documentation](https://nginx.org/en/docs/http/ngx_http_core_module.html)

## License

MIT
