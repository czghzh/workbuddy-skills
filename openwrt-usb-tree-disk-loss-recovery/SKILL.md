---
name: openwrt-usb-tree-disk-loss-recovery
description: >
  OpenWrt / ImmortalWrt 源码树放在外置盘（USB/移动硬盘/外接 SSD）上，盘掉线、换设备号、
  或换了一份克隆盘之后，恢复工作区路径并保证编译不破的门禁式流程。
  关键点：先分清 staging_dir 里烘焙的是「逻辑路径」还是「物理路径」，再决定用软链还是重挂。
  适用于「源码树读不了 I/O error」「btrfs devid MISSING」「盘重新插上后挂到别的路径」
  「/home/xxx 是软链但编译用物理路径」这类场景。
  触发词：掉盘、盘掉了、I/O error、MISSING、重新挂载硬盘、源码树读不了、staging_dir 路径不对、
  换盘后编译、btrfs degraded、udisks 挂到 baf1。
agent_created: true
---

# 外置盘上的 OpenWrt 源码树：掉盘/换盘后的恢复

## 什么时候用

- 编译树在 USB/外接盘上，某天 `make` 突然报 I/O error，`cat` 文件失败但 `ls` 还列得出名字。
- `btrfs filesystem show` 里某个 device 显示 `MISSING`。
- 盘重新插上后**挂到了别的路径**（常见：`/media/<user>/<UUID>` 变成 `/media/<user>/<UUID>1`）。
- 工作区路径是软链（如 `/home/wen/515xg -> /media/wen/<UUID>/515xg`），换盘后编译行为变怪。

## 核心结论（先记住这条，能省一大截时间）

**OpenWrt 的 `staging_dir` 里熔了一堆绝对路径。决定能不能「随便换挂载点」的，是这些路径长什么样：**

```bash
ST=<topdir>/staging_dir
grep -rl '<候选路径前缀>' "$ST" 2>/dev/null | wc -l
```

- 若烘焙的是**逻辑路径**（如 `/home/wen/515xg/ponwrt/...`）⇒ **只把软链重指即可**，
  指向哪块盘都行，烘焙路径照样解析，不用 sudo、不用动挂载。
- 若烘焙的是**物理路径**（`/media/...`）⇒ 换挂载点会让所有烘焙路径失效，
  这时要么把盘挂回原路径，要么接受一次全量重编。

`.config` / `.prepared` 也一起看：`staging_dir/host/.prepared`、`staging_dir/target-*/.prepared`。

## 门禁流程

### 1) 判定盘的真实状态（只读）

```bash
lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINT
ls -l /dev/disk/by-uuid/
mount | grep -i '<关键字>'
findmnt -T <工作区路径>          # 工作区实际落在哪个挂载上
ls -l /dev/sd*                   # ★ 挂载点存在 ≠ 设备还在：设备节点可能已经没了
printf '\n' | sudo -S -p '' btrfs filesystem show    # 看 MISSING / read_io_errs
```

**判据**：`mount` 里还挂着 `/dev/sdb1`，但 `ls /dev/sd*` 里**没有 sdb** ⇒ 这是个「死挂载」，
源设备已消失，读文件必然失败（只有 dentry 缓存撑着 `ls`）。这种情况**修不回来**，只能换到别处。

### 2) 确认替代盘/克隆盘内容完整且可写

```bash
D=<新挂载点>/<工作区子目录>
t="$D/.write-test-$$"; printf ok >"$t" && rm -f "$t" && echo WRITABLE
for x in .config staging_dir feeds bin package toolchain build_dir; do test -e "$D/ponwrt/$x" && echo "有 $x"; done
ls -l "$D/ponwrt/bin/packages/*/base/"*.apk     # 有历史产物 = 大概率是完整树
df -h "$D"
```

> ⚠️ **btrfs UUID 不一样不代表内容不一样**。`btrfs send/receive` 型克隆会生成新 UUID，
> 但 `btrfs filesystem show` 里的 **FS bytes used 会一模一样**。用这个对账最省事。

> ⚠️ 别被「另一份备份树」骗了：备份常常 `build_dir/target-*` 是空的，
> 只有 `staging_dir`，**编不了**。先数一数：
> `ls <tree>/build_dir/target-*/ | wc -l`、`find <tree>/staging_dir -type f | wc -l`。

### 3) 选恢复方案（★ 先跑核心结论那段 grep 再决定）

**A. 重指软链（首选，无需 sudo，可回退）**

```bash
ln -sfn <新挂载点>/<工作区子目录> <工作区路径>
```

- 前提：烘焙的是逻辑路径。
- 注意 `TARGET` 要是**子树目录**，别指到挂载根，否则所有相对路径整体错一层。
- 改完立刻验：`head -3 <工作区>/<某文件>`（读）、写测试、`<树>/staging_dir/host/bin/python3 --version`。

**B. 重挂回原路径（需要 sudo）**

```bash
printf '\n' | sudo -S -p '' umount -l <死挂载点>   # 死挂载先惰性卸载，否则 umount 会卡
printf '\n' | sudo -S -p '' umount <新挂载点>
printf '\n' | sudo -S -p '' mount /dev/sdXn <原挂载点>
```

- 好处：`getcwd()` 与历史烘焙路径逐字一致。
- 坏处：动挂载；udisks2 可能又把盘抢走挂到它自己喜欢的位置。

**C. bind mount 到原路径（想要「真目录 + 物理路径一致」时）**

```bash
rm <工作区路径>            # 原本是软链
mkdir -p <工作区路径>
printf '\n' | sudo -S -p '' mount --bind <新挂载点>/<工作区子目录> <工作区路径>
```

- `getcwd()` 会返回 bind 路径，于是 TOPDIR 与历史逻辑路径一致。
- ⚠️ **坑：bind mount 不持久**。重启后只剩一个**空目录**，工作区「看起来全空」，
  比软链危险。要用就得写进 fstab，否则别用。

### 4) 恢复后必须验的三件事

1. `<工作区>/<树>/staging_dir/host/bin/<某工具> --version` 能跑（host 工具链没坏）。
2. `<工作区>/<树>/.config` 还在、且与预期一致。
3. 真编一次，看 **`staging_dir` 里是否出现第二种路径前缀**：

```bash
grep -rl '<物理路径前缀>' "$ST" 2>/dev/null | wc -l
grep -rl '<逻辑路径前缀>' "$ST" 2>/dev/null | wc -l
```

出现两种前缀 = 混用。**两种前缀都能解析时功能无害**，会随每次构建逐渐收敛；
但如果只想稳妥，回到方案 B/C 让 `getcwd()` 与历史一致。

## 顺手要做的两件事

- **删掉死挂载**：`printf '\n' | sudo -S -p '' umount -l <死挂载点>`，
  否则 `ls /media/<user>`、`df` 可能卡住。
- **告警**：原来的盘为什么会掉（接触不良 vs 盘坏）值得查；
  克隆盘别当成唯一一份，另存一份。

## 常见误区

| 误区 | 真相 |
|---|---|
| 「挂载还在，所以文件还在」 | 挂载点可能是死挂载（设备已消失）。`ls` 能列名 ≠ 读得出内容。用 `cat` 验。 |
| 「UUID 不同所以不是同一份数据」 | send/receive 克隆必换 UUID。看 `FS bytes used` 对账。 |
| 「盘挂回原路径问题就没了」 | 先看 `staging_dir` 烘焙的是物理还是逻辑路径 —— 逻辑路径的话重指软链就够，不用动挂载。 |
| 「有个备份树就能编」 | 备份常常没有 `build_dir/target-*`。数量一下再下结论。 |
