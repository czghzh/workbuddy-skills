---
name: openwrt-brick-offline-triage
description: 离线定位「自编译 OpenWrt 固件刷进设备后起不来 / 上不了网」的根因，并把只存在于 build_dir 的内核改动固化成能长期生效的正式补丁。当需要对比「能启动」和「变砖」两版 .itb、从 FIT 里抽 squashfs/内核/设备树做逐文件差分、给 drivers/ 下的手改代码补 patches-<ver>/*.patch、或把一台跑厂商固件的「黄金参考机」变成真值源时使用。内含 A/B 镜像差分脚本、内核 patch 生成与验证闭环、用未定义符号表反推预编译 .ko 所需内核 ABI、vermagic 判定二进制来源、"probe 整体失败 = 端口全丢"与"ndo_init 顺序耦合"这类经典根因的识别方法，以及**机器生成的「厂商行为重放」寄存器序列表为何会取到未收敛分支**（症状：能起搏但硬件永不 lock、数据中断恒 0）。
agent_created: true
---

# 离线定位 OpenWrt 变砖根因 + 固化内核补丁

## 适用场景

- 自己编的固件刷进去后「电源灯常亮、网口灯不亮、SSH 进不去」，用户没串口，只有 LED 可观察
- 手上有**同一条源码树编出的、确认能启动的基线镜像**（最关键的参照物）
- 需要把 `build_dir/.../linux-*/drivers/...` 里手改的代码补成 `target/linux/<target>/patches-<ver>/*.patch`

## 铁律

1. **没有串口时先分清楚「内核死了」还是「内核活着但网络没了」。** 判断依据：LED 类节点若在
   `/etc/init.d/boot`（`START=10`）里被 `/sbin/kmodloader` 加载，则"电源灯常亮"只证明
   **内核已进到 S10boot**，剩下什么都没证明。别据此说"内核崩了"。
2. **先做全量差分，再猜。** 绝大多数"变砖"能靠离线差分直接锁定，不需要刷第二次。
3. **不要手工"回退"代码来构造补丁基线**——一定会错一行上下文（见下文常见错误）。

## 第 0 步：确定 delta 边界

找到「能启动」的那版镜像，看它的 `.manifest`：
- 若基线 manifest 里**完全没有**你新加的包 → delta = 整块新功能，范围就此收敛
- 记下两版镜像的 sha256 与字节数

## 第 1 步：从 FIT 镜像里抽三层内容

`.itb` 是 FIT（`d00dfeed`），内部顺序一般是：kernel(gzip) → dtb → squashfs。

### 抽 squashfs —— 扫魔数 + 校验超级块

```python
import struct
SB = struct.Struct('<IIIIIHHHHHHQQQQQQQQ')   # squashfs superblock, 96 B
assert SB.size == 96

def find_sq(data):
    out, i = [], 0
    while True:
        i = data.find(b'hsqs', i)
        if i < 0: break
        (magic, inodes, mkfs_time, block_size, fragments,
         comp, block_log, flags, no_ids, s_major, s_minor,
         root_inode, bytes_used, id_table, xattr_id,
         inode_table, dir_table, frag_table, lookup_table) = SB.unpack_from(data, i)
        if s_major == 4 and block_size in (4096, 8192, 16384, 32768, 65536,
                                          131072, 262144, 524288, 1048576) \
           and 0 < bytes_used <= len(data) - i:
            out.append((i, bytes_used))
        i += 4
    return out
```

> **坑**：超级块是 **5 个 `u32`**（magic/inodes/mkfs_time/block_size/fragments）再 6 个 `u16`。
> 少写一个 `I` 或 `H` 会因为 `struct.error` 被 `except` 吞掉，表现为"扫不到 squashfs"。

抽出后 `unsquashfs -f -d <dir> <file>`（**必须 `-f`**：目标目录残留会让 `-q` 直接失败；
另外 `dev/console` 会因非 root 报错，**但其余文件已解出**，做清单/哈希比对足够）。

### 抽内核 —— 扫 gzip 流取最大解压结果

```python
import zlib
best = None
i = 0
while True:
    i = data.find(b'\x1f\x8b\x08', i)
    if i < 0: break
    try:
        buf = zlib.decompressobj(31).decompress(data[i:i+32*1024*1024])
        if not best or len(buf) > len(best): best = buf
    except Exception: pass
    i += 1
```

拿到裸 `Image` 后 `strings -a` 就能查符号/字符串，用来**证伪或证实某个特性是否被编进内核**。

### 抽 dtb + 反编译

按 FIT 找 `d00dfeed` 且 `totalsize` 合理（`0x1000 < ts < 200000`）的那块；
`dtc -I dtb -O dts -o x.dts x.dtb`。然后**逐节点逐属性**对比两版。

> `strings` 看 dtb 会骗人：dtc 做字符串去重，属性可能指向另一字符串的**中间偏移**，
> 于是你会看到 `tpon0-los` 而实际属性值是 `pon0-los`。**必须用 dtc 反编译后再比。**

## 第 2 步：三层差分（按性价比排序）

1. **rootfs 逐文件 sha256**：先列清单找只在一边存在的文件，再对共有文件算 sha256 比对。
   只差包数据库（`etc/apk/world`、`lib/apk/db/installed`、`scripts.tar.gz`）就说明 rootfs 无罪。
2. **内核字符串差分**：查关键特性字符串是否出现在基线内核里。
   若基线内核里**一处都没有**，就说明基线不含该功能，delta 含**全部**新增内核代码。
3. **dtb 差分**：找 `status` 从 `disabled` 变 `okay` 的节点——**这类改动是唯一"会真的跑起来"的改动**，
   新增但无驱动匹配的节点全是惰性的（先 `grep -r '<compatible 字符串>' <kernel tree> --include=*.c` 确认有无驱动）。
4. **三方确认某个源文件归属**：`build_dir/toolchain-*/linux-*/` 那棵树往往是**未打补丁的 vanilla**
   （`sha256` 跟 `dl/linux-*.tar.xz` 一致），**不能**当"OpenWrt 打过补丁"的中间基线。

## 第 2.5 步：先证明「内核到底有没有被改坏」—— 两版 kernel .config 键值全等 diff

**适用**：已经做出「坏版 / 好版」两版镜像、想二分到底是内核还是 rootfs 的锅。
这一步是**离线**的、几分钟出结果，且结论是硬的（不是推测），**先做它再考虑刷机**。

做法：分别用两版 `.config` 跑 `make target/linux/prepare`，各自把生成的 kernel `.config`
存成 `kernel-config.<标签>.bak`，然后做**键值全等**比对（不是肉眼 diff）：

```python
# 解析成 dict，统计：总项 / 仅出现在一侧 / 值有变化 / y→m、y→n、m→y、n→y 各多少
```

**判据**：
- 四项全为 0 ⇒ 两版内核配置**逐项相同** ⇒ 内核二进制没变 ⇒ **内核洗清嫌疑**，
  变量只剩 rootfs 内容。此时别再往内核方向查了。
- 只统计「`=y` 有没有被降级成 `=m`/`=n`」**不彻底**，会漏掉 m→y、字符串值变化、
  以及新增/消失项。要做就做全量。

**三个必踩的坑**：
1. **基准必须来自同一次源码树的真实构建**。拿手写的 `target/linux/generic/config-6.18`
   当基准会算出 9 项"降级"之类的**假差异**（那 9 项本来就是 generic 默认值，跟构建无关）。
2. **initramfs 内嵌的是 kernel compile 那一刻的 `$(TARGET_DIR)` 快照**（`CONFIG_INITRAMFS_SOURCE`）。
   所以「recovery 干不干净」**不用解包**——看体积即可：rootfs 里若被塞了 34 MB 的东西，
   recovery 就会是 46 MB 而不是 12 MB；12 MB 就说明它的 initramfs 是干净的。
3. **`target/linux compile` 到底跑没跑，只能看构建日志的那一行**（`make[3] -C target/linux compile`），
   子 make 的实际输出不进日志。别靠"应该没重编"来推断。

## 第 2.6 步：用「内存启动」做零风险二分（不写 flash）

有 Web recovery 的 u-boot 可以直接 `boot-upload` 把镜像**从 RAM 启动**，不写 flash、不改卷，
是最理想的二分手段。但它**自身的可信度必须先验证**：

- 拿一个**已知能启动**的镜像（比如刚确认能跑起来的那版）走一遍同样的 `boot-upload` 流程。
- 它若**也**失败 ⇒ 这个启动方式/它依赖的 bootargs 本身有问题，
  之前"某某镜像从 RAM 启动也失败"的结论**全部作废**，不能用来排除任何嫌疑。
- 它成功、坏版失败 ⇒ 结论才是有效的。

由此可以只花几分钟就把嫌疑从一个大集合缩小到单一变量，避免再编再刷一轮。

## 第 3 步：经典根因 —— probe 失败导致端口全丢

**症状**：电源灯常亮、网口灯永不亮、无 SSH/DHCP。
**机理**：`airoha` 这类驱动在 `probe()` 的子节点循环里逐个建端口，**任一端口失败就
`goto error_*` 让整个 probe 失败**，于是**一个 netdev 都不注册**（只剩 `lo`），
连正常的 LAN 口也一起消失。看起来像"启动不了"，其实内核好得很。

**排查套路**：
1. 看每个被 `okay` 的网口节点是否具备 probe 必需属性。以 airoha 为例：
   `airoha_setup_phylink()` 第一步就是 `of_get_phy_mode()`，
   而 `net/core/of_net.c` 的 `of_get_phy_mode()` 在 **`phy-mode` 与 `phy-connection-type`
   都缺失时直接 `return err`（-EINVAL）**。
2. 典型命中：base dtsi 里某端口是 `disabled` 且**没写 `phy-mode`**（兄弟端口都有，
   如 `"internal"` / `"2500base-x"`），一旦有人把它改 `okay` 就必炸。
3. 顺手检查 `of_property_read_bool(node, ...)` 读的是**父节点还是子节点**——
   厂商标记（如 `airoha,pon-data-path`）常挂在**子**节点上，读父节点会恒为 false，
   让整条下游功能静默失效（`-EOPNOTSUPP`）。

## 第 4 步：把 build_dir 手改代码固化成正式补丁

### 4.1 备份

```bash
BK=<某处>/kpon-backup
cp -a build_dir/target-*/linux-<soc>/linux-<ver>/drivers/net/{ethernet,pcs}/<drv> $BK/
```

### 4.2 拿到权威基线（**不要手工回退**）

`include/kernel-build.mk:13`：

```
STAMP_PREPARED = $(LINUX_DIR)/.prepared$(md5 of KERNEL_FILE_DEPENDS)
```

`KERNEL_FILE_DEPENDS` 含补丁目录 → **新增/修改 `patches-<ver>/` 下任何文件都会改变 md5**，
于是一次普通 `make` 就会自动 `rm -rf $(KERNEL_BUILD_DIR)` + 重新解包 + 重打**全部**官方补丁。

所以流程是：

1. 先随便放一个（哪怕是错的）补丁文件进去，跑一次 `make`，**故意让它 prepare**。
2. prepare 结束后，树里**没被你的补丁碰过**的文件就是权威基线，直接拿来当 `a/`。
3. 用 `diff -uN --label a/<rel> --label b/<rel>` 生成补丁（新文件用空文件当 `a/`）。

> **踩过的坑**：手工从"当前文件"删掉自己加的行来造基线时，很容易在 `};` 之类的位置
> 多留/少留一个空行 → `Hunk #2 FAILED at ...`。这就是第 2 步必须走构建系统的原因。

### 4.3 验证闭环（缺一不可）

```bash
# ① 离线：对基线副本干跑 + 真套用 + 逐字节比对
mkdir -p /tmp/kv && cp -a <baseline>/drivers /tmp/kv/ && cd /tmp/kv
patch -p1 --dry-run --forward < P1 && patch -p1 --dry-run --forward < P2
patch -p1 -s --forward < P1 && patch -p1 -s --forward < P2
for f in <每个文件>; do cmp -s /tmp/kv/$f $BK/$f || echo "❌ $f"; done

# ② 真实：再触发一次 prepare，日志里必须无 FAILED / .rej
grep -nE "Hunk .* FAILED|Patch failed" <build log>
# ③ 完成后：树里的文件必须与备份逐字节一致
```

### 4.4 命名与位置

`target/linux/<target>/patches-<ver>/` 下按序号递增（例：已有到 `924-`，就用 `930-01`、`930-02`），
`-p1` 风格、`--- a/path` / `+++ b/path`，新文件用空 `a/` 侧。按功能拆成多个补丁
（如「数据面胶水」一个、「PHY 序列」一个）比一个巨型补丁好维护。

## 第 5 步：做「天然可恢复」的诊断镜像

当还没验证过厂商 `.ko` 能否在本内核上跑时，**不要**直接开自启。做法：

- 模块照常安装到 `/lib/modules/<ver>/`
- 但**从 `/etc/modules.d/` 里删掉**（`kmodloader` 不碰它）
- **从 `/etc/init.d/` 里删掉**相关服务（`packager` 按 `/etc/init.d/` 内容自动生成 `/etc/rc.d/S*` 链接，
  删了就不会有自启链接）
- 把它们放到 `/root/<pkg>/` 备用，并预置一个已知 root 密码（`sysupgrade -n` 会清掉 overlay，
  否则刷完连不上就白刷）

**收益**：模块不被 autoload，手工 `insmod` 把内核搞挂后，**断电重启即回到可启动状态**，
不需要 TTL/U-Boot 自救。这是零成本的安全网。

> `uci-defaults` 的执行时机：`/etc/init.d/boot` 里是 `/sbin/kmodloader` **先**、
> `uci_apply_defaults` **后**，两者都在 S10boot 内，都早于 `dropbear`(S19)/`network`(S20)。

## 第 6 步：rc.d 顺序陷阱

`S19airoha-pond` 与 `S19dropbear` 同号时按名字排序，`airoha` < `dropbear`
→ **前一个卡住，dropbear 永不启动**，表现为完全无网络。排查"用户态阻塞"类问题时先看这个。

## 第 7 步：把「活的黄金参考机」当成真值源

**先问清楚哪台设备是什么。** 如果手上有一台跑**厂商原版固件**且**内核版本与你的目标一致**的设备，
它的价值远高于任何离线 dump —— 它是"活的真值"。一次把下面这批全取下来存本地：

```sh
# 权威设备树（注意 ethernet@* 在 soc/ 下面，不在顶层！）
ls /proc/device-tree/soc/
for d in /proc/device-tree/soc/ethernet@* /proc/device-tree/soc/pcs@*; do
  echo "== $d"
  for f in "$d"/*; do printf '  %-24s = ' "${f##*/}"; cat "$f" | tr -d '\000'; echo; done
done

ip -br link; ip -d link show <dev>          # 谁注册了 netdev、谁是谁的 conduit（DSA 线索）
dmesg | grep -iE "<驱动名>"                  # 驱动各自的探针顺序与参数
uci show network; cat /etc/board.json        # 用户的最终接口拓扑
ls -la /lib/modules/$(uname -r)/; modinfo <mod>   # 模块清单 + vermagic
for f in /lib/modules/$(uname -r)/*.ko; do sha256sum "$f"; done
```

**同内核版本的厂商设备还能直接判定"我们打包的二进制对不对"**：把厂商 `.ko` 拉回本地
（`ssh host 'cat <path>' > local` 比 `scp` 可靠），与 `package/**/vendor/**` 里的打包源
`sha256sum` 对比。**只有逐字节相同，才能说"我们烧进去的就是参考机在跑的那份"。**

### 判定某个 `.ko` 到底来自哪个厂商构建版本 —— 靠 vermagic

同名同大小但校验和不同的两份 `.ko`，**先看 `.modinfo` 里的 vermagic**，
一眼就能分辨是「不同内核版本」还是「同一版本的两次构建」：

```python
# 读 .modinfo：解析 ELF section header，定位 .modinfo，按 \0 切分找 vermagic=
# vermagic=6.18.44 SMP mod_unload aarch64   vs   vermagic=6.18.52 SMP mod_unload aarch64
```

同一机型常同时存在**多份厂商固件**（出厂旧版 + 新版 ImmortalWrt），
`analysis/` 里堆的 dump 极易张冠李戴。**用 vermagic 给每个 dump 贴上标签再动手。**

## 第 8 步：用未定义符号表反推预编译 `.ko` 需要的内核 ABI

逆向移植预编译模块时，**不要靠猜"它需要内核提供什么"**。直接读符号表，
未定义符号（`shndx == 0`）就是它要从内核/你的驱动里拿的全部东西：

```python
# kosym.py —— 纯 Python，不依赖 readelf
import struct, sys
for p in sys.argv[1:]:
    d = open(p, 'rb').read()
    shoff = struct.unpack_from('<Q', d, 0x28)[0]
    shent = struct.unpack_from('<H', d, 0x3a)[0]
    shnum = struct.unpack_from('<H', d, 0x3c)[0]
    shstr = struct.unpack_from('<H', d, 0x3e)[0]
    sh = [struct.unpack_from('<IIQQQQIIQQ', d, shoff + i * shent) for i in range(shnum)]
    stro = sh[shstr][4]
    for s in sh:
        if s[1] not in (2, 11):            # SYMTAB / DYNSYM
            continue
        stro2 = sh[s[6]][4]
        for k in range(s[5] // (s[9] or 24)):
            o = s[4] + k * (s[9] or 24)
            nme, info, other, shndx, val, size = struct.unpack_from('<IBBHQQ', d, o)
            if shndx != 0:
                continue
            n = d[stro2 + nme : d.index(b'\0', stro2 + nme)].decode('utf8', 'replace')
            if n:
                print("U", n)
```

**用法**：`python3 kosym.py <厂商>.ko | grep <你的子系统前缀>`。
它同时给出两个关键信息：

1. **你的导出接口清单对不对**（多一个少一个都是隐患）—— 例：`airoha-xpon.ko` 恰好要
   7 个 `airoha_eth_pon_*` + 4 个 `airoha_pcs_pon_*`，与实现逐字对齐。
2. **它会用哪些内核机制** —— 例：出现 `of_find_net_device_by_node` 就说明它**靠 DT 节点
   反查 netdev**，那么该 DT 节点**必须真的注册了 netdev**，否则模块拿不到句柄。
   这类信息靠读日志是永远推不出来的。

配套技巧：**比较两份 `.ko` 的差异字节落在哪个 ELF 段**（解析 section header 后把
偏移映到段名）。落在 `.modinfo` = 只是 vermagic；落在 `.text` = 代码真的不同，要当心。
用场景：判断"我们的逆向结论是否被二进制差异影响"。

## 第 9 步：动手改内核前必查的四个「二阶陷阱」

改「让某个端口/设备交给另一个驱动接管」这类逻辑时，**跳过分配**往往不是安全的最小改动：

1. **`ndo_init` 里的顺序耦合。** 有些驱动的"谁是 WAN"判定是靠**遍历已注册的 netdev** 实现的
   （例：`airoha_dev_init()` 里 `if (airoha_get_wan_gdm_dev()) break; fallthrough;`，
   而该函数返回的是"**已经**被打上 WAN 标记的那个"）。此时**被你跳过分配的那个端口，
   恰恰是让别的端口不被误判的前提** —— 跳过它会导致 LAN 端口被整体打上 WAN 标记。
   查法：`grep -n "for (i = 0; i < ARRAY_SIZE(eth->ports)" drivers/...`，
   把所有遍历点读一遍，确认每个都有 `if (!port) continue;`，
   **并且**确认没有 `ndo_init`/`.ndo_*` 回调依赖被跳过对象的"存在性"。
2. **预编译模块的句柄来源**（见第 8 步）：模块若用 `of_find_net_device_by_node()` /
   `of_find_device_by_node()` 反查，**对象必须存在**。此时正确做法常常是
   **保留分配、只翻转"能力开关"**（例：`pon_capable = true`），而不是删掉对象。
   这类"最小改动"往往只有一个判断块，风险远低于结构性重构。
3. **打包源真伪**：改内核前先确认 `package/**/vendor/**` 里的二进制与参考机一致（第 7 步），
   否则你会同时动两个变量，出问题无法归因。
4. **★ 机器生成的「厂商行为重放」产物必须当作可疑代码审查。**
   把厂商内核的寄存器时序**用模拟器逐指令重放**、把 `regmap_read/write/update_bits` 打桩、
   录下访问日志生成一份"序列表"（如 `pon-seq.h` 这类几百条 op 的静态表）——这个方法威力很大，
   但有一个**致命局限**：**`regmap_read()` 打桩返回 0，会让代码里所有"轮询/比较/搜索"型循环
   一律走「条件不成立」那条分支**，于是录下来的是**失败/未收敛路径的写入值**，
   而真机上这些循环本该收敛到另一组正确值。
   - 症状特征：起搏日志里"能配置、能启动 RX"，但**硬件状态机永远停在 hunt / 不锁定**，
     对应的数据中断计数**恒为 0**（一帧未收），并陷入"检测到信号→重训→又失败"的循环。
   - 判据：把设备日志与**同型设备的厂商固件黄金日志**逐行对拍。若黄金日志里有一条
     **"搜索/校准/锁定成功"**的打印（含具体读数，如 `lock=1 idac=0x4ef fl=0xa4bf target=0xa49a`），
     而自编译版**完全没有**，就高度怀疑序列取的是未收敛分支。
   - 处理顺序：**优先改调树里已有的"真算法"**（厂商上游那份会实测回读并迭代逼近的搜索函数，
     通常已在别的接口路径里被调用，只是没接到目标路径上），代价远小于重新采集真机读轨迹去重放。
   - 同源陷阱：生成物里的 **`FIELD`/回调类条目若被标成"占位符"（placeholder）就是空操作**，
     会被静默跳过。数一下有多少条、对应哪个未转写的描述符表，
     这类"静默跳过"不会报任何错，只能靠数条目发现。

### 增量补丁策略（当无法廉价重建基线时）

第 4 步的"权威基线"需要一次 prepare 才能拿到。若**约 70 个官方补丁都碰过同一个文件**
（`grep -rl "<文件路径>" patches-<ver>/`），基线就不再等同于上游 tarball，
重建成本变高。此时用**追加式补丁**更划算：

```sh
# a/ 侧 = 上一号补丁的产物（就是当前树里那个文件），b/ 侧 = 你改完的文件
diff -uN --label a/<rel> --label b/<rel> a/<rel> b/<rel> > patches-<ver>/930-03-<slug>.patch
```

- 按字典序 `930-01 < 930-02 < 930-03`，OpenWrt 用 `$(sort ...)` 排序，所以天然续接
- 验证闭环与第 4 步完全相同（干跑 / 真套用 / `cmp` 逐字节），无需重建基线
- 代价：自己的补丁后面跟了自己的修补丁，稍欠优雅；上游化之前再合并即可

> 错误信息**沿用厂商原版文案**（例：`"airoha,pon-data-path is valid only on GDM2\n"`）
> 是大赚的：以后真机上 `dmesg` 能与厂商日志逐字对拍。

---

## 第 10 步：验证改动真的进了产品二进制（标记串法）

补丁套用成功、构建树里文件也对 —— 但**产物镜像里的内核**到底含不含这段代码？
比对文件大小、翻 `System.map` 都不够直观。用**改动独有的字符串**来钉死：

```python
# 扫 gzip 流，取解压后最大的那个 = vmlinux；再数标记串
import re, zlib
d = open(itb, 'rb').read()
best = max(((m.start(),
             zlib.decompressobj(31).decompress(d[m.start():m.start()+40*1024*1024]))
            for m in re.finditer(b'\x1f\x8b\x08', d)),
           key=lambda t: len(t[1]))
k = best[1]
print("vmlinux =", len(k))
for s in [b"<本次改动独有的新字符串>", b"<既有接口符号名>"]:
    print(k.count(s), s)
```

判据：

| 结果 | 结论 |
|---|---|
| 新标记串 **≥1 次** | 改动确实进了二进制 ✅ |
| 既有接口符号**仍在** | 旧补丁没被新补丁挤掉 ✅ |
| 出现 **0 次** | 先别慌 —— 分清「没进」还是「名字不在这」，见下 |

**三个必查前提，否则会搜错对象、白忙一场**：

1. **先确认是内建还是模块** —— 看构建树的 `.config`：
   ```sh
   grep -E "CONFIG_NET_VENDOR_AIROHA|CONFIG_<你的驱动>" build_dir/*/linux-*/.config
   # =y → 内建：修复在 vmlinux 里，抽内核搜
   # =m → 模块：修复在 .ko 里，去 rootfs 里搜
   ```
2. **0 次命中先区分语义** —— 例：`airoha-xpon` 是**外部 `.ko`** 的名字，
   内建内核里本来就没有，**别把它当失败**。
3. **最省事的标记串来源**：直接用你抄来的**厂商原版错误文案** —— 反正本来就要抄，
   顺手就得到了一个"既独有、又能与厂商日志对拍"的字符串。

> **编译日志错误扫描的假阳性**：`grep -nE "error:|Error [0-9]"` 会命中宿主机工具的
> 警告上下文（例：`atmaddr.c` 的 `-Wformat=` 提示里那行 `fprintf(stderr,"internal error: …")`）。
> 命中后必须 `awk 'NR==<行号>'` 看**那一行实际是什么**，再决定是不是真错误。
> 真正的判据是最后有没有 `MAKE_EXIT=0`。
