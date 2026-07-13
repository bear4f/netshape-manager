# NetShape Manager

面向 Linux 中转机、Emby/Jellyfin 反代和高 RTT 链路的 SSH 交互式网络调优工具。它会根据你选择的简单方案、到本地的大致延迟、机器内存和内核能力生成保守的 TCP 参数，并自动选择 VPS 支持的限速队列，减少排队、重传和播放断流。

> 本项目不会上传硬件、IP、域名或运行数据，也不包含作者或使用者的个人信息。

## 能做什么

- SSH 中文交互面板；安装后直接运行 `netshape`
- 自动识别 CPU、RAM、Swap、默认出口网卡、MTU、内核和 BBR 支持
- 默认使用多设备/多网络自适应，不限制整台机器的合计速度
- 可选 450M、950M 或自定义的单条 TCP 连接上限，多设备不共享这个上限
- 仅在高级模式下才使用 HTB/TBF 限制整台机器合计速度
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

多设备自适应、160ms RTT 示例：

```bash
curl -fsSL --retry 3 https://raw.githubusercontent.com/bear4f/netshape-manager/main/netshape-manager.sh -o /tmp/netshape-manager.sh && sudo bash /tmp/netshape-manager.sh install --non-interactive --mode adaptive --rtt 160
```

### 本地文件安装

下载后在服务器执行：

```bash
chmod +x netshape-manager.sh
sudo ./netshape-manager.sh install
```

向导会询问：

1. 你本地连接 VPS 大约多少毫秒；不知道可直接回车；
2. 使用多设备自适应、单连接上限，还是高级整机合计上限。

无人值守安装示例：

```bash
sudo ./netshape-manager.sh install \
  --non-interactive \
  --mode adaptive \
  --rtt 160 \
```

每条 TCP 连接最多 950 Mbps：

```bash
sudo ./netshape-manager.sh install \
  --non-interactive \
  --mode perflow \
  --rtt 160 \
  --rate 950
```

指定非默认路由网卡时可加 `--iface eth0`。默认使用 IPv4 默认路由网卡，找不到时再尝试 IPv6 默认路由。

## 日常使用

打开面板：

```bash
sudo netshape
```

常用快捷命令：

```bash
sudo netshape adaptive           # 推荐：多设备自适应，无整机总上限
sudo netshape per-flow 450       # 每条 TCP 连接最多 450 Mbps
sudo netshape per-flow 950       # 每条 TCP 连接最多 950 Mbps
sudo netshape total 2300         # 高级：整台机器合计最多 2300 Mbps
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

这里的“不限流”指 Nginx 不对单个 Emby 请求设置应用层速率上限。默认自适应模式也不限制整机总速度；每台设备的 TCP 连接由 BBR 分别适应自己的网络。脚本不会自动修改现有站点，因为不同面板和反代模板的结构差异很大。

## 调优原理

### 1. 多设备独立适应

默认模式只使用 fq 做连接分离与 pacing，不设置总出口上限。BBR 在每条 TCP 连接上分别估计带宽和 RTT，因此不同运营商、不同 Wi-Fi/蜂窝网络的设备不会共同被锁死在 450M 或 950M。

`fq maxrate` 是单条流的上限，不是设备上限；一个播放器如果建立多条 TCP 连接，设备合计速度可能超过该数值。整机合计上限只适合明确需要避免打满物理端口的场景，属于高级功能。

整形只控制服务器发出的流量。它不能修复上游拥塞、入口丢包、源站转码不足或客户端 Wi-Fi 问题。

### 2. TCP 缓冲

脚本使用：

```text
BDP(bytes) = rate(Mbps) × RTT(ms) × 125
目标缓冲   = 2 × BDP
```

结果向上取 2 的幂，并按 RAM 档位限制在 8–128 MiB。TCP 自动调优按需增长缓冲，并不在每个连接建立时立即分配最大值。

脚本故意不写死 `net.ipv4.tcp_mem`。现代 Linux 会在启动时根据可用内存计算全局 TCP 内存阈值，固定复制其他机器的页数反而可能让小内存 VPS 过度分配，或让大内存机器过早进入内存压力。

### 3. BBR 与兼容性

脚本尝试加载内核已有的 `tcp_bbr`，随后读取内核公布的可用拥塞控制算法。存在 BBR 才启用，否则回退 Cubic。它不会下载第三方内核，也不会绕过容器限制。

## 排障建议

先收集：

```bash
sudo netshape status
sudo netshape diagnose
```

重点观察：

- 默认自适应模式是否显示普通 fq；
- 若使用高级整机上限，队列是否为 HTB + fq 或 TBF + fq；
- qdisc/class 的 `dropped`、`overlimits` 是否持续快速增长；
- TCP 重传计数是否在播放时快速增加；
- Nginx error log 是否出现 upstream timeout、client prematurely closed；
- Emby 是否正在转码，CPU、磁盘或源站上行是否成为瓶颈；
- MTU/PMTU、隧道封装和跨境线路是否造成黑洞或持续丢包。

若自适应模式仍断流，应检查对应客户端路径的丢包、MTU、Nginx/Emby 日志和转码负载；不要先用很低的整机总上限掩盖问题。只用一次测速结果不能证明流媒体长连接稳定。

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
