---
name: airoha-hw-offload-verify
description: 判定 Airoha（AN7581 / EN7581）光猫・路由器上「某个转发方向到底有没有真的走硬件卸载」，以及为什么会只有单向卸载、代理流量为什么永远不卸载、无线客户端为什么双向都不卸载。适用于「LAN→WAN 不能硬件卸载」「只有 WAN→LAN 生效」「WAN→LAN 能、LAN→WAN 不能」「npu_attached 是 1 但转发还是慢」「PPE FOE 表里有条目但不确定是否真在转发」「ppe/bind 里 packets=0 是不是没卸载」「两版固件/两棵源码树的卸载差异」「跑代理（daed/sing-box/mihomo/xray）后 CPU 高、不走硬件加速」「无线 WiFi 客户端转发不卸载」，以及给 PPPoE / PON 上联做 PSE_PORT 出口端口核对时使用。
agent_created: true
---

# 判定 Airoha 硬件卸载的方向与「真的生效吗」

## 什么时候用

* 用户说「**一个方向卸载了，另一个没有**」，或「换了一版固件/源码树之后还有没有这个问题」。
* 需要**证明**（不是推断）POE/PPE 硬件转发真的在工作。
* 需要核对 FOE 条目的**出口端口**配得对不对（PPPoE / PON 上联尤其容易错）。
* 「**跑了代理之后 CPU 高 / 看不到卸载**」→ 直接看 §8（本地终结永远不卸载）。
* 「**无线客户端**的转发是不是没卸载」→ 直接看 §9（MT7915 缺 WDMA forward path）。

核心原则：**不要只看一个指标。** 硬件卸载这件事有三个互相独立的判据，
只看其中任何一个都会被误导（下面 §4 有两个必踩的坑）。

---

## 1. 判据 A（最硬）：接口统计 vs Linux IP 层统计

**原理**：被硬件直接转发的包**根本不进 Linux 网络栈**，所以不进 IP 层的计数；
但 GDM/PON 端口的接口统计是**硬件维护**的，照样会涨。

⇒ 跑一个 30 秒窗口，比 `Σ接口包数` 和 `Ip: InReceives / ForwDatagrams` 的增量。

```sh
IF() { cat /sys/class/net/$1/statistics/$2; }
snap() { grep '^cpu ' /proc/stat
  awk 'NR>1 && $1=="Ip:"{printf "Ip: ForwDatagrams=%s InReceives=%s OutRequests=%s\n",$7,$4,$11}' /proc/net/snmp
  for i in pon0 pppoe-wan br-lan phy0-ap0 lan1 lan2 lan3 lan4; do
    [ -d /sys/class/net/$i ] && printf "  %-10s rx=%s tx=%s\n" "$i" "$(IF $i rx_packets)" "$(IF $i tx_packets)"; done; }
snap T0; sleep 30; snap T1
```

**读法**（下面是 2026-09-27 AN7581 实测的真实数字，30 秒窗口）：

| 指标 | 增量 | 含义 |
|---|---|---|
| `pon0` rx + tx | 69,738 + 226,255 = **361,743** | 该口实际处理的包 |
| `Ip: InReceives` | **+6,857** | 进了 Linux IP 栈的包 |
| `Ip: ForwDatagrams` | +3,598 | 软件转发的包 |

⇒ 361,743 里只有约 6,857 进了内核栈 ⇒ **≈98% 由硬件转发**。

**方向配对**（这是判断「哪个方向」的关键）：

| 方向 | 入口 | 出口 | 实测 |
|---|---|---|---|
| **LAN→WAN**（上行） | `lan1` rx | `pon0` tx | 225,926 ↔ 226,255（差 329） |
| **WAN→LAN**（下行） | `pon0` rx | `lan1` tx | 69,738 ↔ 69,448（差 290） |

**两个数字要对得上**（差几百个包是新建流的首包，正常）。
对不上就说明那个方向有大量包没被硬件接管。

> 注意：WAN 是 PPPoE 时，`pon0` 和 `pppoe-wan` 都会计数，
> 但**硬件的上行出口是 PON 口本身**，所以拿 `pon0` 去配 LAN 口最准。

---

## 2. 判据 B：FOE 表方向分布 + 出口端口 PSE_PORT

`/sys/kernel/debug/ppe/bind` 每行一条硬件条目（只列 `BND` 状态）：

```
00056 BND IPv4 5T orig=192.168.1.151:38072->117.181.242.65:7668
            new=172.20.74.85:38072->117.181.242.65:7668
            eth=68:ae:04:ec:ea:60->a4:7b:2c:50:67:f2 etype=0509 data=007f0800
            vlan=41,0 ib1=6151022e ib2=0403e241 packets=0 bytes=0
```

### 2.1 判方向：看 `orig` 是哪一侧

| `orig=` 开头 | 方向 | 说明 |
|---|---|---|
| 内网地址（`192.168.` / `10.` / `172.16-31.` / `2409:` 等） | **LAN→WAN**（出站，含 NAT） | `new=` 里是 NAT 后的 WAN 地址 |
| 公网地址，`new=` 指向内网 | **WAN→LAN**（入站 / 回程） | 回程方向由 nft 单独建条目 |

**两条条目成对出现才是完整的双向卸载。** 每个流两个方向各有一条
（`nft_flow_offload.c` 无条件 `set_bit(NF_FLOW_HW_BIDIRECTIONAL)`，
`nf_flow_table_offload.c` 据此为 `FLOW_OFFLOAD_DIR_REPLY` 也加规则）。

### 2.2 判出口：解 `ib2` 的 PSE_PORT

`ib2` 位段（`airoha_eth.h`）：

| 字段 | 位 |
|---|---|
| `DSCP` | 31-24 |
| `PORT_AG` | 23-13 |
| `PCP` | 12 |
| `MULTICAST` | 11 |
| **`FAST_PATH`** | 10 |
| `PSE_QOS` | 9 |
| **`PSE_PORT`** | **8-5** |
| `NBQ` | 4-0 |

`FE_PSE_PORT` 枚举：

| 值 | 0 | 1 | **2** | 3 | 4 | 5 | 6 | 7 | 8 | **9** | 10 | 15 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 名 | CDM1 | GDM1 | **GDM2** | GDM3 | PPE1 | CDM2 | CDM3 | CDM4 | PPE2 | **GDM4** | CDM5 | DROP |

**看出口端口对不对：**

| 条目方向 | 期望 PSE_PORT | 期望 FAST_PATH |
|---|---|---|
| LAN→WAN（出口 = PON/WAN） | **2（GDM2，uplink loopback）** | 0 |
| WAN→LAN（出口 = LAN 物理口） | 该口的端口号（本机 **9 = GDM4**） | **1** |

`FAST_PATH` 只对 **LAN 出口** 设置（`airoha_is_lan_gdm_dev(dev)` 分支，
源码注释 *"For downlink traffic consume SRAM memory for hw forwarding descriptors queue"*）。
**所以看到 `pse=2 fast_path=0` = 上行，`pse=9 fast_path=1` = 下行**，一眼就能分辨。

一条命令出分布：

```sh
grep 'BND IPv4' /sys/kernel/debug/ppe/bind | sed -n 's/.*ib2=\([0-9a-f]*\).*/\1/p' \
  | while read -r h; do v=$((0x$h)); echo "pse=$(( (v>>5)&15 )) fast_path=$(( (v>>10)&1 ))"; done \
  | sort | uniq -c | sort -rn
```

### 2.3 FOE 状态枚举

`INVALID=0, UNBIND=1, BIND=2, FIN=3`（`AIROHA_FOE_STATE_*`）。
只有 **`BND`** 是硬件已绑定。`entries` 里 `UNB` 比 `BND` 多**属正常**
（未绑定 / 已释放的槽位，老化的流会回到 UNB）；要数活跃条目请用 `ppe/bind`。

---

## 3. 判据 C：逐条与 conntrack 配对

把 FOE 快照和 `/proc/net/nf_conntrack` 一起拉回本地配对，
确认「同一条连接两个方向各有一条条目」。

```sh
ssh <dev> 'cat /sys/kernel/debug/ppe/bind; echo ===SPLIT===; cat /proc/net/nf_conntrack' > snapshot.txt
```

配对逻辑（**注意 tuple 解析**）：

* FOE 的 `orig=A:pa->B:pb` 要**先按 `->` 拆**，再各自拆 `IP:port` ——
  直接 `rsplit(':', 1)` 会把 `A:pa->B` 当成地址。
* conntrack 第一个 tuple = original，第二个 = reply。
* 期望：`tuple[ORIGINAL] ∈ FOE.orig` **且** `tuple[REPLY] ∈ FOE.orig`。

实测样例（两个方向都对上，出口各自正确）：

```
192.168.1.151:38072 <-> 110.52.74.19:13765     (pkt 上行=24 / 下行=107)
   上行 idx=000a9 BND  pse=2(GDM2)  fast_path=0
   下行 idx=0267e BND  pse=9(GDM4)  fast_path=1
```

---

## 4. 两个必须知道的陷阱（不然一定误判）

### 陷阱 1：`ppe/bind` 里的 `packets=` / `bytes=` **全是 0，不能当判据**

`airoha_ppe_foe_entry_get_stats()` 先要求
`airoha_ppe_get_total_num_stats_entries(ppe) > 0` 且 `index < 该值`，否则**直接 return**；
部分 SoC/固件拿不到这个值 ⇒ 统计永远是 0。
**拿它判断会得出「全都没卸载」的错误结论。** 用 §1 的接口统计法代替。

### 陷阱 2：conntrack 里大部分条目**在 FOE 表里找不到，是正常的**

实测一台在跑的机器：内网源 conntrack **7263** 条，其中

* **4278 条是 `[UNREPLIED]`**（P2P 探测包，只有出站包、没有回包）⇒ **本来就不该卸载**；
* 真正双向都在跑的只有 **3008** 条；
* FOE 容量 `PPE_SRAM_NUM_ENTRIES = 8192`，当前只用 **949** 条，**远没满**。

⇒ **条目数是瞬时的，一条条目承载成千上万个包。**
绝不能拿「条目数比」去推断卸载覆盖率。

---

## 5. 「只有一个方向卸载」的根因：`pse_port` 判断写错

位置：`drivers/net/ethernet/airoha/airoha_ppe.c` → `airoha_ppe_foe_entry_prepare()`

**错误版本（Airoha AN7581 上会坏上行）：**

```c
if (dsa_port >= 0 || eth->ports[1])            /* 旧 */
    pse_port = port->id == 4 ? FE_PSE_PORT_GDM4 : port->id;
else
    pse_port = 2;   /* uplink relies on GDM2 loopback */
```

`eth->ports[1]` 是**设备级**判断 —— AN7581 有多个 GDM 口 ⇒ **恒为真** ⇒
`else` 分支（上行的 GDM2 loopback）**永远走不到**。

* 出口是 **LAN 口**（下行）：`port->id` 恰好正确 ⇒ **下行能卸载**
* 出口是 **WAN/PON**（上行）：`port->id` 是 LAN 端口号，**错** ⇒ **上行不卸载**

**这就是「WAN→LAN 能、LAN→WAN 不能」的完整机制。**

**正确版本（改成按当前流的出口设备判断）：**

```c
if (dsa_port >= 0 || airoha_is_lan_gdm_dev(dev))
    pse_port = port->id == 4 ? FE_PSE_PORT_GDM4 : port->id;
else
    pse_port = 2;   /* uplink relies on GDM2 loopback */
```

上游补丁 `net: airoha: Introduce WAN device flag`（OpenWrt / ImmortalWrt 树里编号
`165-04`，早期编号 `920-08`）。**查自己那棵树有没有修**：

```sh
grep -rn 'ports\[1\]\|is_lan_gdm_dev' target/linux/airoha/patches-*/*Introduce-WAN-device-flag*.patch
# 出现 `- ... eth->ports[1]` / `+ ... airoha_is_lan_gdm_dev(dev)` ⇒ 含修复
```

### 更普遍的机制（值得记住）

即使 nft 侧无条件设置了 `NF_FLOW_HW_BIDIRECTIONAL`，
`flow_offload_tuple_add()` 对**单个方向**失败**不会**让整体失败：

```c
ok_count += flow_offload_tuple_add(offload, flow_rule[0], FLOW_OFFLOAD_DIR_ORIGINAL);
if (test_bit(NF_FLOW_HW_BIDIRECTIONAL, &offload->flow->flags))
    ok_count += flow_offload_tuple_add(offload, flow_rule[1], FLOW_OFFLOAD_DIR_REPLY);
if (ok_count == 0)          /* ← 只要求至少有 1 个方向成功 */
    return -ENOENT;
```

⇒ **驱动只支持单向时，内核会「静默地」只卸载一个方向**，不报错、不告警。
排查任何「只有单向卸载」的问题，都要往驱动的 `ndo_setup_tc` 返回什么看。

---

## 6. 完整流程

1. **确认 `npu_attached: 1`**（`/sys/kernel/debug/ppe/config`）。
   它是**懒挂载**：没有第一条真正被卸载的流转发之前永远是 0，这是正常状态。
2. 跑 §1 的两拍快照 → 算出「硬件转发占比」和**两个方向的接口配对**。
3. 跑 §2 的 PSE_PORT 分布 → 看两个方向各自有没有条目、出口端口对不对。
4. 需要逐条证据时跑 §3 的配对。
5. 想看源码层面原因时对照 §5。

**判定标准**：

| 现象 | 结论 |
|---|---|
| 两个方向接口配对都对得上，且 IP 层增量 << 接口增量 | 双向都卸载，**没问题** |
| LAN→WAN 一条 `pse=2` 的条目都没有 | 上行没卸载 → 查 §5 |
| 有 `pse=2` 条目但 `Ip` 增量仍然巨大 | 条目建了但硬件没命中 → 查 FOE 容量 / `fe_wan_port` / GDM2 loopback 配置 |
| 条目一堆但 `packets=0` | 别慌，见 §4 陷阱 1，这字段不可用 |

---

## 7. 现成脚本

`assets/probe-offload.sh` —— 一次跑完 PPE 配置、FOE 方向与 PSE_PORT 分布、
两拍流量对比、flowtable devices。用法：

```sh
ssh -o StrictHostKeyChecking=no root@<设备IP> 'sh -s' < assets/probe-offload.sh
```

`assets/foe-ct-pair.py` —— 把 `snapshot.txt`（FOE + conntrack）做逐条双向配对，
输出「双向都有 / 只有上行 / 只有下行 / 都没有」的统计与样例。

---

## 8. 代理流量为什么**永远**拿不到硬件卸载（本地终结 ≠ 转发）

**症状**：设备上跑了透明代理（daed / sing-box / mihomo / xray …），
分流规则正常，但访问被代理的站点**CPU 很高、看不到卸载**。

**结论：结构上不可能，换客户端软件也没用。** 判据与机制：

### 8.1 分层判据（一次就能定案）

| 检查项 | 命令 | 期望（代理流量） |
|---|---|---|
| 卸载开关确实开着 | `uci show firewall \| grep -i offload` | `flow_offloading=1`、`flow_offloading_hw=1` |
| PPE 已挂载、FOE 在动 | `cat /sys/kernel/debug/ppe/config`；`grep -c BND /sys/kernel/debug/ppe/bind` | `npu_attached: 1`；几十~几百条（**非代理**流） |
| 代理核心在**独立 netns** | `ip -o link show \| grep dae0` | `dae0@ifNN … link-netns daens` |
| **该 netns 里没有转发流** | `ip netns exec daens sh -c 'wc -l < /proc/net/nf_conntrack'` | **0**（铁证） |
| 里面只有本地套接字 | `ip netns exec daens ip -o -4 addr` | 只有 `dae0peer 169.254.0.11/32`（或类似） |
| root netns 无 tproxy 规则 | `nft list ruleset \| grep -i tproxy` | 空（daed 走 tc/eBPF，不是 nft tproxy） |

`daens` 里 conntrack **0 行** = 「里面全是本地套接字、没有一条转发流」的直接证据。
**别被 root netns 里同时存在的 `BND` / `HW_OFFLOAD` 条目骗了** —— 那些是别的（非代理）转发流。

### 8.2 机制链（为什么必然是 0%）

1. 客户端包在 `br-lan` 的 **tc/eBPF ingress** 就被 `bpf_redirect` 送进 veth → 进入代理 netns
   → 由代理进程的透明套接字**本地终结**。
2. 它**从不进入 root netns 的 `forward` 链**。而 nft 硬件卸载**只在 forward 链挂 hook**
   （`nft_flow_offload.c:178`），且 `nf_flow_table_offload.c` 要求出口 `xmit_type` 是
   **DIRECT / NEIGH** —— 本地终结、本地发出两者都不满足。
3. 出方向是代理进程自己发的 socket（本地发出），同样不属于「转发」。
4. ⇒ 硬件（PPE/FOE）在整个代理数据路径上**根本看不到这些包**。

### 8.3 换软件 / 换协议都无效

* sing-box / mihomo / xray 用 `nft tproxy`（`prerouting` → `local-in`）同样是**本地终结**，
  进不了 forward 链；而且比 tc/eBPF 多走一轮 netfilter，通常**更费** CPU。
* 协议侧也别指望：Hysteria2 = QUIC + **用户态**加解密 + **用户态**拥塞控制（Brutal CC），
  开销 100% 在代理进程里；实测代理下载时**代理进程占设备全部 CPU 时间的约 70%**。

### 8.4 唯一能「回到硬件加速」的办法

把代理挪到**另一台机器**，让这台设备只做转发 —— **前提是那台机器有线接入**
（无线接入拿不到卸载，见 §9）。此时设备看到的是普通 LAN↔WAN NAT 转发，正常进 FOE，
设备侧 CPU 接近 0，压力与吞吐瓶颈转移到外置那台机器。

> ⚠️ 反过来：**判定「设备卸载有没有问题」时，必须先把代理摘掉**
> （或只测未被代理的流量），否则结论会被代理流量污染。

---

## 9. 无线客户端（非 GDM 出口）为什么**双向**都不进 FOE

**症状**：有线客户端转发双向都卸载，但**无线客户端**（WiFi 关联的设备）完全不卸载，
看直连视频也 CPU 高。

### 9.1 定点实验（证明不是配置问题）

同一下载窗口内对比两类客户端的 FOE 条目：

| 时刻 | 无线客户端（`phy*-ap0`） | 有线客户端（`lan*`） |
|---|---|---|
| 下载前 | 0 | 有 |
| 下载中 | **0**（恒为 0） | 有（双向都有） |
| 下载后 | 0 | — |

无线那条流的 conntrack 只有 `[OFFLOAD]`（**软件**流表），**没有 `[HW_OFFLOAD]`**。
用 `bridge fdb show br br-lan` + `iw dev phy*-ap0 station dump` 确认客户端接在哪（`offload` 标志也看）。
`eth=` 字段聚合能一眼看出下行条目的出口 MAC 全指向 `br-lan`/有线口，**没有一条指向 AP 口**。

### 9.2 源码根因（`drivers/net/ethernet/airoha/airoha_ppe.c`）

* 无线出口**唯一**通路：`airoha_ppe_get_wdma_info()`，要求
  `path->type == DEV_PATH_MTK_WDMA` → `PSE_PORT = FE_PSE_PORT_CDM4`。
* 非 WDMA 出口走另一分支：要求 `airoha_is_valid_gdm_dev()`，否则 `-EINVAL`。
* 注册 WDMA forward path 的**只有 `mt7996/pci.c`**；`CONFIG_MT76_NPU` 仅由
  `package/kernel/mt76/Makefile` 在 `kmod-mt7996e && TARGET_airoha_an7581` 时注入。
  **mt7915e 分支不含任何 NPU 宏，mt7915 目录 0 处 npu 引用。**
* mt7915 的 forward path 实现整段在 `CONFIG_NET_MEDIATEK_SOC_WED` 之下，
  而 Airoha 内核**没有这个符号**。
* ⇒ `dev_fill_forward_path()` 在 AP 口处返回 `-EOPNOTSUPP` → 走 else → `-EINVAL`
  → 无 FOE 条目；**两个方向一起失败，所以上行也拿不到。**

**这不是配置能解决的**：改配置、重编译都无解（要动驱动，收益不确定且有变砖史）。
⚠️ 注意：为防变砖关掉的是 `kmod-mt7996e`（**另一颗芯片**），与 MT7915/MT7916 **无关**，
别把「关了 mt7996e」当成无线不卸载的原因。

**实务含义**：无线客户端看**直连**视频时 CPU 同样高（压根没卸载）。想验证就拿网线对比。

---

## 10. 相关技能

* `openwrt-device-probe` —— 跳板机探测设备、刷机后体检的通用手法。
* `luci-block-overlay-customize` §7.5 —— 页面显示 `0 / 未启用` 时怎么区分
  「懒初始化」和「真故障」（`npu_attached` 就是典型例子）。
* 省 CPU 的透明代理调参（`bandwidth_max_rx` 峰值声明、`log_level`、`udphop_interval`）
  与「代理外置」路线，见项目笔记 `/home/wen/515xg/hw-offload-diag/measure-results-20260929.md`。
