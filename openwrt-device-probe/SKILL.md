---
name: openwrt-device-probe
description: 通过 SSH 跳板机（本机 → 宿主机 → 目标设备）可靠地探测 OpenWrt / 嵌入式 Linux 设备，做 A/B 设备对比，以及**远程 sysupgrade 刷写+刷后体检**。当需要 ssh 进路由器、光猫、开发板读取分区表、UBI 卷、设备树、nvmem、LED、中断、MAC，对比两台设备差异，远程刷固件，或在没有 sshpass 时用密码登录设备时使用。内含多层 SSH 引号规则、busybox 缺命令清单、askpass 免密登录法、刷机前置检查与刷后验证清单、固件身份哈希校验（FIT 子镜像 / fitblk 设备）以及刷写静默失败陷阱。
agent_created: true
---

# 通过跳板机探测 OpenWrt / 嵌入式设备

## 适用场景

- 本机不能直连目标设备，必须先 `ssh <user>@<jumpbox>` 再 `ssh root@<device>`
- 需要读设备的分区 / UBI 卷 / 设备树 / nvmem / LED / 中断 / MAC
- 刷了新固件后做体检，或与另一台在跑旧固件的设备做对比

## 核心陷阱：多层 SSH 的引号地狱

三层链路（本地 shell → 跳板 shell → 设备 shell）意味着**任意一层看到未转义的元字符都会炸**。

### 规则

1. **外层（本地 → 跳板）用单引号**，**内层（跳板 → 设备）用双引号**
2. **设备端命令里出现的 `$var` 必须写成 `\$var`**（跳板 shell 的双引号会先展开它）
3. **设备端命令里不要出现 shell 元字符**：
   - `(` `)` → 设备 ash 报 `syntax error: unexpected "("`。`echo ---MAC (12B)---` 就会炸
   - 反引号、未转义的分号组合也要小心
4. 给内层 ssh 加 `-T -n`（不分配 tty、不读本地 stdin），避免 stdin 串到设备端 `cat` / `sh -s` 上挂住
   **⚠️ 2026-09-29 实测到它的另一个更阴的症状：静默截断。** 写
   `ssh -n JUMP 'bash -s' <<'OUTER'` 喂一整段多行脚本时，如果里面某条内层 ssh **忘了加 `-n`**，
   它会**把外层 heredoc 剩下的内容当作自己的 stdin 吃掉** —— 表现是**该命令之前的输出全部正常，
   之后的命令一条都不执行、整体 `exit 0`、完全不报错**。我连着两次被它骗过（还先怀疑是工具截断、
   再怀疑是 device 没数据），排查成本很高。
   判据：**同一段脚本里"后半截整体没有输出"** ⇒ 先数一下每条内层 ssh 有没有 `-n`。
   （顺带：`curl`/`node` 之类**也会读 stdin**，喂 heredoc 的多行脚本里要留意。）
5. **不要用 `ssh ... "cmd" < script.sh` 或 `sh -s < script.sh` 传脚本** —— 偶尔会完全无输出。
   改用**单行命令串联**：`ssh -T -n root@ip "cmd1; cmd2; cmd3"`
6. 设备端通常**没有 `base64`**，所以 base64 传脚本的路子走不通

### 可靠模板

```bash
# 单条命令（推荐）
ssh -n jumpuser@JUMPHOST 'ssh -T -n -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@DEVICE \
  "cmd1; cmd2; echo \$HOME"'
```

```bash
# 循环遍历多台设备做对比
ssh -n jumpuser@JUMPHOST 'for ip in 192.168.1.1 192.168.16.1; do \
  echo \"################ \$ip ################\"; \
  timeout 40 ssh -T -n -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@\$ip \
    "cat /proc/mtd; echo ---; ubinfo -a | head -60" 2>&1; done'
```

```bash
# 需要多行脚本时：先写到跳板机，再逐条 ssh 执行
ssh -n jumpuser@JUMPHOST 'cat > /tmp/probe.sh' <<'EOF'
echo hello
EOF
# 但真正执行时仍建议展开成单行，而不是把脚本喂给远端 stdin
```

## busybox 缺命令清单（默认 OpenWrt 构建）

| 命令 | 状态 | 替代 |
|---|---|---|
| `od` | **常缺** | `hexdump -C` |
| `base64` | **常缺** | 无；改用单行命令 |
| `hexdump` | 通常有 | — |
| `nohup` | **常缺**（实测 Airoha/OpenWrt 构建里没有） | `setsid sh -c '...' </dev/null >log 2>&1 &` |
| `sftp-server` | **常缺**（dropbear 不带 sftp-server） | `scp -O`（强制传统 SCP 协议），否则报 `subsystem request failed` |
| `ip -br` | **不支持**（busybox ip 无 `-br`） | `ip -o link` 或直接读 `/sys/class/net` |
| `dtc` / `fdtdump` | 缺 | 在跳板机/构建机上解析 |
| `setsid` `start-stop-daemon` | 通常**有** | — |
| `which` | 通常有 | — |
| `free` `df` `mount` `dd` | 有 | — |

读 `/sys/firmware/devicetree/base/*` 的属性文件时值**不带 NULL 结尾**（或带），
用 `cat` 常混入 `\0`，想看准原始字节用 `hexdump -C`。

**⚠️ 比"混入 NULL"更坑的后果：`cat` 一个含 `\0` 的 DT 属性会把整条 ssh 输出流截断。**
症状是**同一条命令里 `cat <属性>` 之后的所有输出全部消失**，看起来像"后半段没执行"，
实际是 read 方向被 NULL 终止。
→ 取 model 用 `cat /tmp/sysinfo/model`；必须读原始属性时用 `hexdump -C`，并且**把它放在命令最后**。

## 没有 sshpass 时怎么用密码登录

OpenWrt 默认禁 root 空密码（或 bringup 镜像预置了密码）时，`BatchMode=yes` 会直接失败。
设备上不一定装了 `sshpass`，跳板机上也不一定有。**零依赖办法**：用 OpenSSH 自带的 askpass。

```bash
cat > /tmp/askpass.sh <<'EOF'
#!/bin/sh
echo 'THE_PASSWORD'
EOF
chmod +x /tmp/askpass.sh

export SSH_ASKPASS=/tmp/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0
timeout 30 setsid -w ssh -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  root@DEVICE 'cmd'
```

要点：
- `SSH_ASKPASS_REQUIRE=force`（OpenSSH ≥ 8.4）让 ssh **没有 tty 也去问 askpass**，否则必须先 `setsid`
- **必须配 `setsid`**：`setsid -w` 另开会话执行，否则 ssh 会直接用控制终端提示密码
- 想确认走的是密码路径，看 `ssh -vv` 输出里的 `Authenticated ... using "password"`
- **快速判据**：`ssh -v` 若打印 `Authenticated ... using "none"`，说明对端 root 无密码（OpenWrt 默认态），
  此时**根本不需要密码**，加 `-o BatchMode=yes` 就能免密钥直连；一旦刷成"有密码"的镜像就会失效，必须切到 askpass

## 远程 sysupgrade 刷写（不拆机）

### 刷前四件事（全部非破坏性）

```sh
board_name=$(cat /tmp/sysinfo/board_name)   # 必须与镜像 metadata 的 supported_devices 一致
sysupgrade -T -n /tmp/new.itb              # 期望 "Signature check OK"，rc=0
ubinfo -a | grep -c 'Name:.*factory'       # 平台若要求 factory 卷（如 airoha_require_ubi_layout），少了会被拒
ubinfo -d 0 | tail -3                      # 看卷数与可用 LEB
```

空间账要自己算：`nand_upgrade_prepare_ubi` 会**先删 `fit` 和 `rootfs_data` 两个卷**再重建，
所以「可用 LEB = 0」不代表刷不了，只要 `可用 + 旧fit + 旧rootfs_data ≥ 新镜像所需 LEB` 即可
（`ceil(镜像字节 / LEB)`，LEB 见 `ubinfo` 的 Logical eraseblock size）。

### 刷写与重连判定

```bash
timeout 300 ssh root@DEVICE 'sysupgrade -n /tmp/new.itb' > /tmp/flash.log 2>&1
```

**正常输出长这样，最后那行报错不算失败**：

```
Signature check OK
... upgrade: Commencing upgrade. Closing all shell sessions.
Command failed: ubus call system sysupgrade {...} (Connection failed)
```

`(Connection failed)` 是 ubus 连接随重启断开，属于**预期现象**。别把它当刷写失败去重刷。

判定刷完（分段轮询，比死等固定秒数可靠）：

```bash
for i in $(seq 1 20); do
  timeout 3 ping -c 1 -W 1 DEVICE >/dev/null 2>&1 &&
  timeout 6 bash -c 'exec 3<>/dev/tcp/DEVICE/22' 2>/dev/null &&
  { echo "设备已回来"; break; }
  sleep 5
done
```

**注意两个假信号**：
- 刷完立刻 ping 可能**通**（旧系统还没真正重启完成），别据此判定新固件已起
- 期间会出现 `No route to host` / `无响应`，属正常重启空窗
- 只有 `ping 通 + 22 端口可连` 同时成立才算回来了

### 刷新固件后必做的三件事

1. **host key 变了** → 一律带 `-o UserKnownHostsFile=/dev/null`，否则连接被拒
2. **认证方式可能从空密码变成有密码** → 先试 `none`，失败再切 askpass（见上节）
3. **先确认"底座"再谈功能**：`uname -a` / `cat /etc/openwrt_release` / `ls /sys/class/net/` /
   `dmesg | grep -iE "error|fail"`。刷机最怕的不是功能没上，而是**网口全没了导致 SSH 失联**

## ★ 刷写命令「静默失败」陷阱 —— 必须校验，不能凭"设备回来了"判定成功

**真实事故**：用 `nohup sh -c 'sleep 2; sysupgrade -n $IMG' &` 触发刷写。该 busybox **没有 `nohup`**，
远端 ash 直接报 `ash: line 0: nohup: not found` —— 但它是在**子 shell 里**失败的，
外层 ssh **仍返回 0**，脚本打印出 `LAUNCHED`，设备也**根本没有掉线重连**。
于是"等待掉线 → 等待回来"的两段轮询都判定"设备已回来"，看起来一切正常，
实际上 `sysupgrade` 一个字节都没写。**若不做固件身份校验，这就是一次彻头彻尾的假成功。**

结论：
1. 触发刷写的命令**必须**用 `setsid` 分离，并在触发后**主动确认刷写真的开始了**（见下）；
2. **刷后必须比哈希**，不能靠 ping/uptime/`ls /sys/class/net` 这些"看起来正常"的信号；
3. "设备没重启"本身就是最强的失败信号 —— 正常刷写**一定会掉线重连**。

```bash
# 正确姿势：setsid 分离（避开 nohup 缺失），并且把 stdout 立刻回报
setsid sh -c 'sleep 3; exec sysupgrade -n /tmp/new.itb' </dev/null >/tmp/su.log 2>&1 &
```

## ★ 刷后验明正身：不依赖 `uname`/revision 的哈希级判定

`uname -a`、`/etc/openwrt_release` 的 revision 在两版自编译固件间**往往完全相同**
（内核 version string 常取源码时间戳，与构建时刻无关），
所以**证明"刷进去了"只能靠镜像字节比对**。三层递进，任一层通过即可定论，全过最稳：

### L1 — 原始固件卷 vs 本地 `.itb` 逐字节

```bash
# 宿主机
dd /dev/... 无 ——— 改为在设备上把固件卷拉回来：
ssh root@DEV 'dd if=/dev/ubiblock0_4 bs=64k 2>/dev/null' > post-vol.bin   # 卷名见 ubinfo
N=$(( $(stat -c%s post-vol.bin) < $(stat -c%s local.itb) ? $(stat -c%s post-vol.bin) : $(stat -c%s local.itb) ))
head -c $N post-vol.bin | sha256sum    # 与 sha256sum local.itb 比
```

**⚠️ 截断长度必须取 `min(卷, itb)`，不能直接用本地 itb 长度。**
卷是**按擦除块对齐**的（比 itb 长），而设备上那版 itb 可能比本地**短**；
若按本地长度截断，会把**上一版固件的尾巴 + 填充**一起截进来 → 哈希不等 → **假告警**。
（踩坑实例：设备上 E 版 9,908,490 B，本地 F 版 9,912,586 B，按 F 长度截断多吃了 4,096 B 填充。）

### L2 — FIT 内部子镜像逐项对拍（最稳，不受长度/对齐影响）

自写一个几十行的 FDT 解析器遍历 `/images/*`，读出每个子节点的
`data-position` / `data-size` 并就地算 sha256，**本地 itb 与设备卷各跑一遍对拍**。
kernel / fdt / rootfs / hash-1 / hash-2 逐项相同 ⇒ 板上跑的就是这个镜像。
（现成脚本：`tools/fitls.py`，纯标准库。）

### L3 — `fitblk` 子设备 = 当前 rootfs，天然就是"固件指纹"

Airoha 等平台用 `fitblk` 把 FIT 里的 rootfs 子镜像暴露成块设备（`/dev/fit0`，magic 是 `sqsh` 不是 `d0 0d fe ed`），
内核就用它挂 `/rom`。**读 `/dev/fit0` 拿到的就是"现在正在跑的固件"**：

```bash
ssh root@DEV 'sha256sum /dev/fit0'     # 应等于本地 itb 里 rootfs-1 节点的 sha256
```

这比 `uname` 精确得多，一眼就能区分 E/F 两版自编译固件。

### 顺带：刷前先取一份"当前身份"存证

刷之前把固件卷和 `/dev/fit0` 各拉一份存进证据目录，既做回滚保险，
又能证明"刷前是哪一版"（本次就靠它坐实了设备仍在跑 E 版）。

## 刷机结果体检清单

拿到一台刚刷完的 OpenWrt 设备，按顺序查这些：

```sh
# 1 身份与版本
uname -a; cat /etc/openwrt_release
cat /sys/firmware/devicetree/base/model | hexdump -C

# 2 内存实际值（验证引导器回填是否生效）
head -1 /proc/meminfo
cat /proc/cmdline
hexdump -C /sys/firmware/devicetree/base/memory@80000000/reg

# 3 分区与 UBI
cat /proc/mtd
ubinfo -a

# 4 网络 / MAC / LED
for i in /sys/class/net/*; do echo $i $(cat $i/address) $(cat $i/operstate); done
cat /proc/net/dev
ls /sys/class/leds/

# 5 中断（拿硬件中断号）
cat /proc/interrupts

# 6 nvmem 与 factory 卷内容
ls /sys/bus/nvmem/devices/
dd if=/dev/ubi0_3 bs=1 skip=$((0x141024)) count=12 2>/dev/null | hexdump -C

# 7 内核日志
dmesg | grep -iE "error|fail|timeout|denied"
```

## 中断号的关键区分

`/proc/interrupts` 一行的格式是：

```
 56:      0      0      0      0    GICv3  74 Level     1fb64000.ethernet
 ^virq                                   ^hwirq
```

- 行首的 `56:` 是 **Linux virq**（GICv3 irq_domain 动态分配，不可预测）
- `GICv3 74` 里的 `74` 才是 **hwirq**（= DT 里 `interrupts = <0 42 4>` 的 `42 + 32`）

**驱动 dmesg 打印的 `irq=NN` 是 virq，不能拿去写 DT。核对 DT 时必须看 `GICv3` 后面那个数。**

## 设备树交叉校验技巧

- 运行中的 Device Tree 在 `/sys/firmware/devicetree/base/`，路径可直接 `find` / `ls`
  例：`/sys/firmware/devicetree/base/soc/spi@1fa10000/nand@0/partitions/partition@20000/volumes/ubi-volume-factory/nvmem-layout/calibration@1c0400`
- 对比「DTB 静态值」与「运行时值」的差异，能反推引导器做了哪些 fixup
  （例：DTB 写 `memory = 512M`，运行时变 1G → 引导器按实测容量回填）
- 想知道某节点的 `compatible`，直接 `cat <path>/compatible`

## A/B 对比两代固件

固定同一份探测命令，对两台设备各跑一遍，然后逐字段列表比对。重点看：

| 比对项 | 为什么重要 |
|---|---|
| `MemTotal` + `memory/reg` | 验证引导器内存回填 |
| `/proc/mtd` | 分区表是升级安全的基础 |
| `ubinfo` 卷**名字与顺序** | 决定 `ubi0_N` 编号；顺序由设备历史决定，**应按卷名而非 ID 定位** |
| `GICv3` hwirq | 写 DT 用 |
| `/sys/class/leds/` | 校验 `board.d` 里的 LED 名 |
| `nvmem` 设备与 MAC | 验证 UBI 卷 → nvmem → mac-base 链路 |
| `dmesg` 过滤 error/fail | 快速发现缺驱动 |

**卷 ID 顺序会因设备历史不同而漂移**（新板 = 预置卷 + 新建卷；刷过别的固件的板 = 沿用旧卷 ID）。
只要代码用 volname / phandle 定位，顺序差异就无害 —— 但仍要确认关键卷（如 `factory`）的 ID 在目标设备上符合预期。
