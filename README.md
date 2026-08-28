# NetShape Manager

面向 Linux 中转机、Emby/Jellyfin 反代和高 RTT 链路的 SSH 交互式网络调优工具。它会根据你选择的简单方案、到本地的大致延迟、机器内存和内核能力生成保守的 TCP 参数，并自动选择 VPS 支持的限速队列，减少排队、重传和播放断流。


## 能做什么

- SSH 中文交互面板；安装即进入面板选择机器角色，安装后直接运行 `netshape`
- 两种机器角色：中转/观看机（跨境、双层限速）与落地鸡（约 1ms、固定缓冲 + HTB aggregate 挡上游 policer）
- 自动识别 CPU、RAM、Swap、默认出口网卡、MTU、内核和 BBR 支持
- 双层限速：单条 TCP 连接压在观看设备家宽以下（500M 家宽→430/450，1G 家宽→850/900），整机总出口按 VPS 端口保护（2.5G 口→2300，1G 口→900，可设 0 不限）
- 多设备在不同家宽环境同时观看时各自跑满自己的带宽，互不挤占；单条流不会打爆"VPS 到家"的跨境路径（这是重传暴涨和断流的根源）
- HTB + fq maxrate 实现；HTB 不可用自动回退 TBF，再不行仅保留单连接上限；应用后用 `tc` 复核实际生效速率
- 可选不限速自适应，仅推荐丢包极少的干净直连线路（选择时需二次确认）
- 询问到本地的大致延迟；不知道可直接使用默认值
- 自定义单连接上限、整机上限或 RTT 时同步重算 TCP 参数
- 使用独立 sysctl 文件，不覆盖 `/etc/sysctl.conf`
- 检测旧 sysctl 和旧 `tc` 服务冲突，但不会擅自删除其他工具的配置
- 本机装有 Nginx 时生成 Emby 不限流片段并只读审计限速项；未装 Nginx（纯中转）自动跳过
- `initcwnd/initrwnd 32` 缩短每条新连接的爬坡时间，高 RTT 链路上直接改善起播和拖动
- 整形突发可切换：小突发贴合被限速线路，大突发适合干净直连线路
- systemd 开机恢复、状态查看、实时重传率采样，以及按出厂快照逐项还原内核参数的完整卸载

## 另一个工具：peertune（面向"一群"客户端）

本仓库还有一个独立工具 [`peertune/`](peertune/)，模型正好相反：

|  | netshape-manager | peertune |
|---|---|---|
| 客户端 | **一台**固定容量的家宽设备 | **一群**容量和延迟都在变的设备 |
| 典型场景 | 跨境中转 + 家里固定观看 | 你自己的 5G、多地区的朋友、晚高峰 |
| 核心手段 | 单连接上限压在家宽以下 | **不设单流上限**，CAKE 按客户端公平 + AQM |
| RTT | 问你一个值 | 覆盖值，按最远的客户端定，不实测 |
| 特有能力 | 双层限速、Emby 反代审计 | **逐客户端**看 RTT 分布、抖动、排队膨胀、重传 |

如果你的客户端只有家里那台设备，用 netshape。如果客户端的延迟和速率一直在变（5G、多地区），
`peertune scan` 能告诉你**谁在卡、卡在哪一层**——包括"瓶颈队列在运营商基站里，服务端限速无效"这种
netshape 无法表达的结论。

两者都会接管 root qdisc 和 sysctl，**同一台机器上只装一个**。

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

这条命令会先进入**安装面板**，让你选这台机器是做什么的：

```
  这台机器是做什么的？
    1) 中转/观看机 —— 客户端在家宽另一端，跨境线路
       逐项询问延迟、VPS 端口、家宽档位，套双层限速
    2) 落地鸡 —— 与中转机同区域，RTT 约 1ms，出口前面通常有商家 policer
       直接套用：BBR + 固定 32MiB 缓冲 + HTB aggregate + fq leaf
    3) 只做基础 TCP 调优（BBR + fq，完全不限速）
    0) 退出
```

选 1 进入原来的逐项向导；选 2 只问一个「端口多大」（自动换算成 HTB cap）；选 3 只做 BBR + fq 不限速。

安装完成后直接运行 SSH 面板：

```bash
sudo netshape
```

### 一键无人值守安装

2.5G 口中转机、观看设备 500M 家宽、160ms RTT：

```bash
curl -fsSL --retry 3 https://raw.githubusercontent.com/bear4f/netshape-manager/main/netshape-manager.sh -o /tmp/netshape-manager.sh && sudo bash /tmp/netshape-manager.sh install --non-interactive --rate 430 --total 2300 --rtt 160
```

落地鸡（1G 口 → HTB cap 980；`--total` 填的是最终 HTB 值，0 = 不限）：

```bash
curl -fsSL --retry 3 https://raw.githubusercontent.com/bear4f/netshape-manager/main/netshape-manager.sh -o /tmp/netshape-manager.sh && sudo bash /tmp/netshape-manager.sh install --non-interactive --role landing --total 980
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

面板顶部显示当前策略、延迟参考、队列模式和自开机以来的 TCP 重传率（累计值，判定见下文「重传率怎么看」）。若实际生效的 qdisc 与保存的策略不一致（被其他服务覆盖、或重启后没有应用），面板会直接告警。

除数字档位外，面板还提供：

- `a` 重新应用当前配置；
- `b` 切换整形突发模式（小突发 / 大突发）；
- `l` 切换为落地鸡模式；
- `p` 暂停/恢复人为限速（暂停后仍保留 fq 公平排队）；
- `u` 卸载（按快照还原内核参数、恢复原 qdisc、清掉 initcwnd）；
- `0` 或 `q` 退出。

落地鸡模式下面板会换成一套更简洁的菜单（见下文），按 `3` 切回中转模式。

数字输入处按 `q` 或 Ctrl-D 可以放弃本次修改回到菜单；某一步失败（内核不支持某种队列、Nginx 配置有错等）只会打印原因并返回菜单，不会关掉面板。

常用快捷命令：

```bash
sudo netshape 430                # 单条连接 ≤430M（500M 家宽·Emby 稳定，推荐）
sudo netshape 450                # 单条连接 ≤450M（500M 家宽·速度优先）
sudo netshape 850                # 单条连接 ≤850M（1G 家宽·稳定）
sudo netshape 900                # 单条连接 ≤900M（1G 家宽·速度优先）
sudo netshape per-flow 600       # 同上，任意单条连接上限（rate 是它的别名）
sudo netshape total 2300         # 整机总出口（按 VPS 端口；0 = 不限制）
sudo netshape adaptive           # 不限速自适应（仅干净直连线路）
sudo netshape rtt 160            # 更新到本地的大致延迟
sudo netshape status
sudo netshape diagnose
sudo netshape off                # 暂停限速，保留 fq/fq_codel
sudo netshape on                 # 恢复限速
sudo netshape apply              # 恢复持久化配置
sudo netshape burst policer      # 小突发整形（默认）
sudo netshape burst throughput   # 大突发整形（10ms 令牌）
sudo netshape initcwnd 32        # 初始拥塞窗口（0 = 不修改默认路由）
sudo netshape landing 980        # 切换为落地鸡模式（参数 = HTB aggregate 上限，0 = 不限）
sudo netshape relay              # 切回中转/观看模式
sudo netshape uninstall          # 卸载并按快照还原内核参数
```

裸数字（`netshape 430`）设置的是**单条连接上限**；整机总出口只能通过 `netshape total`。

每次修改策略、上限或 RTT，都会重新计算 TCP 缓冲并应用 qdisc。只改整机总出口时不重写 sysctl，因为缓冲只由单连接上限和 RTT 决定。持久化配置位于 `/etc/netshape-manager.conf`。

## 落地鸡模式

落地鸡（出口节点）和中转机的约束几乎相反，所以它是一个**完全独立**的分支：独立的 sysctl 集合、独立的缓冲计算、独立的整形路径，两边不共用任何一条公式。

|  | 中转/观看机 | 落地鸡 |
|---|---|---|
| 客户端在哪 | 家宽另一端，跨境 | 隔壁的中转机 |
| 到对端延迟 | 100-250ms | **约 1ms** |
| 瓶颈在哪 | 跨境路径上的 policer | **商家自己的上游 egress policer** |
| TCP 缓冲 | 按 2×BDP 推导（8-128 MiB） | **固定 32 MiB**，不看 RTT/BDP |
| 单连接上限 | 压在家宽以下 | 不设 |
| 出口控制 | HTB 总出口 + fq maxrate | **HTB aggregate + fq leaf** |
| HTB 突发 | 可切换 | 固定小突发（约 1ms 令牌） |
| initcwnd | 32 | **关闭** |
| 端口档位 | 500M→430/450 | **500M→490、1G→980、2G→1960、2.5G→2450** |

### 这些数字是实测来的，不是经验推的

一台真实落地鸡，到三台中转机 RTT 都稳定在 1ms：

| | 不整形 | HTB 950M + fq leaf |
|---|---|---|
| 稳定吞吐 | 撞在约 **1.0 Gbps** | **902-908 Mbps** |
| 15 秒重传 | **138000-149000** | **几十** |

同时在落地鸡本机测到：`fq dropped`、`TCPBacklogDrop`、`TCPRcvQDrop`、`softnet_dropped`、`time_squeeze` 增量**全部为 0**，网卡 RX drop 在压测期间只增加个位数。

也就是说：**不是 rmem/wmem 不够，不是 softirq，不是 netdev backlog，不是本机队列。** 是约 1Gbps 的宿主机/上游 policer。

所以落地鸡的方向是**保守 buffer + aggregate shaping**，不是继续扩 buffer。1ms 下 1Gbps 的 BDP 只有约 125KB、2Gbps 约 250KB —— 32 MiB 已经是上百倍余量，再往上只是给 BBR 更多超发空间。

### 落地鸡只写这些 sysctl

```
net.ipv4.tcp_congestion_control = bbr      net.core.default_qdisc = fq
net.core.rmem_max = 33554432               net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432    net.ipv4.tcp_wmem = 4096 16384 33554432
net.ipv4.tcp_moderate_rcvbuf = 1           net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_slow_start_after_idle = 0     net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_fastopen = 3                  net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 0                       net.core.netdev_max_backlog = 16384
net.ipv4.udp_rmem_min = 8192               net.ipv4.udp_wmem_min = 8192
```

内存不足 1 GiB 时缓冲上限降到 16 MiB。

**刻意不碰的**：`tcp_mem`、`tcp_adv_win_scale`、`tcp_notsent_lowat`、`tcp_tw_reuse`、`tcp_fin_timeout`、`tcp_keepalive_*`、`tcp_max_tw_buckets`、`ip_local_port_range`、`somaxconn`、`tcp_max_syn_backlog`、`nf_conntrack_max`、`vm.min_free_kbytes`。这些是系统策略，不是网速旋钮，1ms 路径上动它们买不到任何吞吐。

从旧版本升级时，如果这些参数曾被 NetShape 改过：有出厂快照就**按快照逐项还原**；没有可信快照则**明确告知需要重启**，绝不猜内核默认值。

### 为什么必须是 HTB 而不是 fq maxrate

`fq maxrate` 是**每条流**的上限。四条流各限 980，端口上仍然是 4 Gbps —— 上游 policer 照样被打穿。只有 HTB 能给出**聚合**上限，所以它是落地鸡的主路径：

```
HTB aggregate（rate = ceil = cap，burst = cburst = 约1ms令牌）
  └─ fq leaf（limit 10000 / flow_limit 256）
       └─ eth0
```

回退顺序：HTB + fq → TBF + fq → 裸 fq（并强告警，因为此时已经没有聚合上限了）。**不走 CAKE** —— 落地鸡的基准路径必须是实机验证过的那一条。

叶子队列固定 10000 / 256，不用中转机那套按内存放大到 40960 / 8192 的深度：1ms 路径上那么深的队列只是徒增排队延迟。

### 端口档位

填的是**物理/套餐端口**，面板显示推导出的 HTB cap：

| 端口 | HTB cap |
|---|---|
| 500 Mbps | 490 |
| 1 Gbps | **980** |
| 2 Gbps | 1960 |
| 2.5 Gbps | 2450 |

约 98% 线速。自定义时填的就是最终 HTB 值，不再偷偷乘系数。

> **HTB 数值不等于 iperf3 的 TCP payload。** 1G 口设 980 时实际有效吞吐通常在 900 上下，这是正常的 —— 目标是把重传从每 15 秒十几万压到几十，而不是让测速数字刚好凑到 1000。

### 落地鸡的诊断

`netshape status` 在落地鸡模式下换成专用页面：HTB cap、burst、fq leaf 深度、initcwnd 状态、以及**实际 root qdisc**（与配置不符时直接告警）。

实时重传率 >1% 时给的建议是「优先怀疑上游 policer，把 HTB cap 降一档」，**不会**建议加大 rmem/wmem/tcp_mem/队列深度。同时会打印本机协议栈的丢包计数——如果 `TCPBacklogDrop`、`TCPRcvQDrop`、`softnet_dropped` 全是 0 而重传很高，会明确指出「本机协议栈未见丢包，重传更可能发生在 eth0 之后」。

### 整形突发模式

限速器（policer）判定的是**瞬时**速率，令牌桶给得越大越容易被打穿——平均速率没超也照样丢包。默认的 `policer` 模式给 HTB 约 1ms 的令牌（430M 档约 53KB），`throughput` 模式给 10ms（430M 档约 525KB，即 5.2.0 及更早的行为）。

跨境、被限速的线路用小突发；干净直连线路如果实测大突发吞吐更高，用 `netshape burst throughput` 切回去。**这两种没有普适答案，请在自己机器上对比 `netshape status` 里的实时重传率再定。**

### 初始拥塞窗口

`initcwnd/initrwnd 32` 写在默认路由上，缩短每条新连接前几个 RTT 的爬坡时间——高 RTT 跨境链路上直接影响 Emby 起播和拖动的手感。装了 networkd-dispatcher 的系统还会写一个 hook，DHCP 续约或链路抖动重写默认路由后自动补回。部分虚拟化平台不支持，此时会跳过并告警，其余调优不受影响。用 `netshape initcwnd 0` 可以关掉。

### 重传率怎么看

`netshape status` 会采样 5 秒，给出窗口内的 `重传数 / 发包数`：

| 实时重传率 | 含义 |
|---|---|
| `< 0.1%` | 干净 |
| `0.1% - 1%` | 偏高，线路或档位需要留意 |
| `> 1%` | 基本是撞上了限速器，把单连接上限降一档 |

阈值取自 [tcpfit](https://github.com/Kylin010/tcpfit) 公布的实测回归：七台真实机器上干净侧最高 0.0017%，撞限速器最低 1.354%。面板首页显示的是自开机累计值，机器跑得越久越被稀释，只当粗略信号看。

### 卸载会恢复什么

首次调优前会把 42 项内核参数的原值存到 `/var/lib/netshape-manager/pre-tune.snapshot`，`netshape uninstall` 按快照逐项写回——只删配置文件是不够的，那些值会一直留在运行中的内核里直到重启。根 qdisc 同样会恢复成安装前记录的类型（多队列网卡的 `mq` 交还给内核自动重建，不会被压成单个 fq）。

如果安装时机器上已经有 NetShape 的 sysctl 配置却没有快照（从旧版本原地升级），快照会记为非出厂状态并在卸载时明确告知。

### 关于整机总出口的实际值

HTB 实际投递约为标称值的 93-96%，所以 2.5G 口设 2300 Mbps 实测大约在 2140-2210 Mbps。设置常见档位时面板会提示这一点。

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

并按 RAM 档位限制在 8–128 MiB，同时受一条硬约束：单个 socket 不得超过 `tcp_mem` 上限的 1/8，即任何时候都要容得下 8 条并发大流。缓冲刻意不取过大的整数倍：过大的缓冲会允许 BBR 在被限速的线路上囤积巨大的拥塞窗口，正是重传暴涨的来源之一。TCP 自动调优按需增长缓冲，并不在每个连接建立时立即分配最大值。

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

### Emby 反代掉速但 iperf3 正常

这说明 TCP 与限速层没有问题，瓶颈在反代链路本身，按顺序排查：

1. 运行 `sudo netshape nginx-audit`：它会检查不限流片段是否真的被站点 include、`proxy_buffering` 是否关闭。Nginx 默认把视频流缓冲到磁盘临时文件再转发，是"速度剧烈波动、长时间只有几十兆"最常见的根源；片段生成后必须在反代 Emby 的 `location` 块里 `include` 才生效。
2. 在 VPS 上直接测"源站到 VPS"的入口速度（把 URL 换成实际可访问的视频直链）：

   ```bash
   curl -o /dev/null -w '平均下载速度 %{speed_download} 字节/秒\n' '源站视频URL'
   ```

   如果源站到 VPS 本身只有几十兆，瓶颈在上游，本机怎么调都无法超过它。
3. 确认源站没有在转码、没有对单条连接限速。

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
