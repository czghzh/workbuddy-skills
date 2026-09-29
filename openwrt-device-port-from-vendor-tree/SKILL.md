---
name: openwrt-device-port-from-vendor-tree
description: 把一个"厂商树/第三方 OpenWrt 分支"里已经支持的设备（光猫/ONU/路由器/开发板）移植到本地主线 OpenWrt 快照源码树，并做到能刷能跑。当任务是"设备移植到 OpenWrt 快照分支""以某设备为模板移植""主线没有这个设备""厂商驱动在这些仓库里""把 XX 设备加进 OpenWrt""U-Boot+UBI+FIT 启动的设备换固件"时使用。内含：先找现成上游树再对齐（而不是从零写 DTS）、补丁集一致性量化对比法、hunk 冲突改写规则、feed 接入、board.d 与 uci-defaults 的执行顺序、KERNEL_IN_UBI+fitblk 镜像配方、以及**刷机前必须确认设备在拓扑里的角色**这一致命前置检查。
agent_created: true
---

# 把厂商树里的设备移植到主线 OpenWrt

## 铁律：先找现成上游树，再对齐

**不要从零手写 DTS/驱动包。** 这类设备的固件几乎总能找到一个公开的第三方 OpenWrt/ImmortalWrt 分支，
里面已经有该设备的成套支持。移植 = 把那个树里的相关部分**对齐**进本地树，而不是重新设计。

### 第 0 步：定位现成树（决定整个任务成败）

1. 读设备上的固件身份，拿到关键线索：
   ```sh
   cat /etc/openwrt_release            # DISTRIB_REVISION / DISTRIB_TARGET
   cat /tmp/sysinfo/board_name         # 例：znxt,zn515xg-d
   cat /proc/device-tree/model; cat /proc/device-tree/compatible | tr '\0' ' '
   apk list -I 2>/dev/null | grep -iE "pon|wifi|vendor|airoha"   # 包 origin 字段直接暴露 feed 路径
   ```
   **`apk list -I` 的 `{feeds/xxx/...}` origin 字段是金矿**——它直接告诉你厂商固件用了哪些自定义 feed 和包名。
2. 用设备型号 / `board_name` / vendor 关键字去 GitHub 搜；也翻用户给的仓库的 **fork 关系**和 README。
   找到树后立刻检查它是否含 `target/linux/<board>/dts/<你的设备>.dts`。
3. 用**补丁集一致性**判断对齐成本（这一步决定策略）：
   ```sh
   P=<vendor-tree>/target/linux/<board>/patches-<ver>
   for f in $P/*.patch; do cmp -s $f <local>/target/linux/<board>/patches-<ver>/$(basename $f) || echo "DIFF $f"; done
   ```
   - 大量补丁**完全字节相同** → 两棵树同源，整体对齐最省事、成功率最高。
   - 只有零星差异 → 逐个人工核对。
   - 若本地有厂商树没有的文件（自研设备），对齐时要**保留**它们。

## 对齐策略（用户偏好"能跑优先"时）

整体覆盖 `target/linux/<board>/{patches-*,dts,image,base-files,*/config-*,target.mk}`，
并把厂商树里**被删掉的本地独有设备**重新加回去（image 定义 + `01_leds`/`02_network`/`platform.sh`/`03_*` 分支）。

```sh
cp -a $P/target/linux/<board>/patches-*/.  <local>/target/linux/<board>/patches-*/
cp -a $P/target/linux/<board>/dts/.        <local>/target/linux/<board>/dts/
cp -a $P/target/linux/<board>/image/.      <local>/target/linux/<board>/image/
cp -a $P/target/linux/<board>/*/base-files/. <local>/target/linux/<board>/*/base-files/
diff -rq <local>/target/linux/<board> $P/target/linux/<board>   # 复查只剩"本地独有"
```
本地源码树通常是 git 仓库且干净 → 所有改动可 `git diff` 复核、可回退。**先记下基线 commit。**

### 补丁预检（必须做，别等整编）

```sh
make target/linux/prepare -j1 V=s 2>&1 | grep -iE "FAILED|\.rej|failed to build"
find build_dir/target-*/linux-*/linux-*/ -name '*.rej'
```
出 reject 不要慌，看 `.rej` 与补丁 hunk，按**补丁意图**适配主线上下文，而不是照搬厂商行号。

**典型冲突模式**：厂商树带自己的 generic 补丁，改了某个通用函数的结构
（例：`nft_flow_offload.c` 里厂商有 `if (routing)` 分支，主线没有），
导致依赖该上下文的 hunk 失败。做法：读补丁注释搞清它要干什么，把 `+` 行插到主线等价位置。
用 `python3` 精确改写这一段（保留 tab），改完 `rm -rf build_dir/.../linux-<ver>` 再跑一次 prepare。

**改 hunk 后必须同步修正计数，否则 `patch(1)` 拒绝或错位应用**：
- 改动了某 hunk 的 `+/-` 行数 → 该 hunk 头 `@@ -a,b +c,d @@` 的 `b`/`d` 要跟着改；
- 删除或新增了整个 hunk → 其后所有 hunk 的**新文件起始行号 `c`** 要按增减量平移
  （只删 `+` 行的话是 `c -= 删除的加行数`）。
- 推荐用脚本统计每个 hunk 的实际 old/new 行数再回写，别靠眼看。

### 预检只能发现"应用失败"，编不过要另查

`prepare` 无 reject ≠ 能编过。厂商补丁常假设 `CONFIG_WERROR=n`，而主线内核
`CONFIG_WERROR` 默认可能为 y（`default COMPILE_TEST`，但被别的 config 打开），
于是厂商驱动里的 `-Werror=format=` 之类会直接中断整编。

**判据与处置**：
1. 先看报错是否**只集中在少数文件**（编译日志里 `error:` 的行数与文件数）。
   只 1~2 个文件 → **修 bug**（这才是正解，且能顺带发现真问题）。
2. 典型"厂商补丁针对旧基线"的两种 bug：
   - **重复逻辑**：厂商补丁加的检查/修复，主线更晚的补丁（或你刚换成的新版补丁）里已经有了
     → 直接**删掉那个冗余 hunk**，而不是去改主线代码；
   - **类型/格式不匹配**：`%d` 配 `u64`、`%u` 配 `FIELD_GET()` 的 `unsigned long`
     → 加显式转型（如 `(u32)FIELD_GET(...)`）或换正确的转换说明符。
3. 若厂商代码**大面积**告警，改不完 → 才在 `<target>/<sub>/config-<ver>` 里加
   `# CONFIG_WERROR is not set`，并明确记录这是妥协。
4. 全部修改都写进交接文档（哪个补丁、为什么、怎么改、原始报错），
   因为**下次从厂商树重新同步时会全部丢失**。

## 接入厂商 feed

`feeds.conf` 里加 feed（先 `cp feeds.conf.default feeds.conf` 再追加，否则会丢掉默认 feed！）：

```
src-git <name> <url>
```
然后**只更新这几个 feed**，别 `update -a`（会动其它 feed 的版本）：
```sh
./scripts/feeds update <name1> <name2>
./scripts/feeds install -p <name1> -a
```
注意 Rust/C 依赖：`PKG_BUILD_DEPENDS:=rust/host` 的包会连带编译整条 Rust 宿主工具链，**耗时很长**，
排进时间预算。厂商 feed 与上游 fork 比对 `PKG_VERSION/PKG_RELEASE` 可确认内容是否一致。

## 设备 profile 与配置

```sh
# 手工改 .config 后一定要再跑 defconfig，否则 make 不会认
sed -i 's/^CONFIG_TARGET_<board>_<sub>_DEVICE_<old>=y/# ... is not set/' .config
echo 'CONFIG_TARGET_<board>_<sub>_DEVICE_<new>=y' >> .config
make defconfig
grep -E "DEVICE_<new>=y|CONFIG_PACKAGE_<关键包>=y" .config
```
**坑**：旧 profile 的 `.config` 里会有显式 `# CONFIG_PACKAGE_xxx is not set`，defconfig 会**保留**它，
导致 `DEVICE_PACKAGES` 里的无线/功能包被静默排除。要启用就得先 `sed` 删掉那几行 "is not set"，再追加 `=y`。

## 板级配置的执行顺序（决定用 board.d 还是 uci-defaults 覆盖）

- `/etc/board.d/*` 由 preinit 的 `/lib/preinit/82_config_generate` → `/bin/board_detect` 执行，
  且仅当 `/etc/config/<file>` 不存在时生效。
- `/etc/uci-defaults/*` 由 `/etc/init.d/boot` 的 `uci_apply_defaults` 在后执行，且**成功即自删**（一次性）。
- 所以要**覆盖**板级默认（例如保持出厂网段/SSID）→ 写 `<target>/<sub>/base-files/etc/uci-defaults/9x-xxx-site`。
- `board_name` 在该脚本里可用；脚本里**不要**用 `rootfs_type`（它只在 `lib/upgrade/common.sh` 里，会 command not found）。

### ⚠️ 覆盖配置时**绝不要**整份重写 `/etc/config/*`

`config_generate` 除了 interface 还会写 `network.globals`（`dhcp_default_duid`、`ula_prefix`），
`/etc/config/wireless` 之外很多软件包也在自己的 config 里放单例节。用
`cat > /etc/config/network <<EOF ... EOF` 整份覆盖会把这些节**静默删掉**，症状是：

- LuCI「网络 → 全局网络选项」**空白**（该页 = `interfaces.js` 的
  `form.TypedSection('globals', ...)`；`form.js` 的 `TypedSection.render()`/`cfgsections()`
  **只遍历已存在的节**，一个都没有时只渲染 `renderSectionPlaceholder()` 的
  *“This section contains no values yet”* 一行灰字，且 `addremove=false` 不给"添加"按钮）；
- 其它同类的单例节页面（dnsmasq/odhcpd 等）同理。

**结论：这不是 LuCI 的 bug，是配置缺节。** 修法是补回节 / 不要整份覆盖。

- 前置判断：`uci show network | grep -i globals`，与正常固件对比（正常应有 `network.globals`）。
- 写法：优先 **只改必要的项**（`uci set` / 只写 `device`+`interface` 段并保留 `loopback` 与 `globals`），
  或干脆**不覆盖**、用板级默认；确实要换网段时至少补回：
  ```
  config globals 'globals'
  	option ula_prefix 'auto'
  	option dhcp_default_duid 'auto'
  ```
- 更省事的路径：**管理 IP 尽量吃主线默认**。`bin/config_generate` 里
  `lan) ipad=${ipaddr:-"192.168.1.1"}`，所以只要板级 `02_network` 用
  `ucidef_set_interface_lan`（只传 device、proto=static、不带 ipaddr），默认 LAN 就是 `192.168.1.1`，
  不需要任何站点覆盖文件。
- 只想改接口数量时改 `board.d/02_network` 更干净：`ucidef_set_interface_lan "lan1 lan2 lan3 lan4"`
  = 只建 br-lan、无 wan；`ucidef_set_interfaces_lan_wan "..." "pon0"` = 额外建 wan（**netifd 会在开机时
  拉起 pon0 → 触发 PON 线路启动**，见附录）。改动共享分支时注意别连带改了别的机型，必要时把
  `case` 拆成两条。

## 厂商 LuCI 页面"不见了"怎么查

厂商固件有的页，自编固件没有 → **先看菜单 json 的 `depends` 门控，再看对应包有没有勾选**，
不要先去怪移植漏了文件。

```bash
# 1) 页面的菜单节点与门控：是否有 fs/uci/acl 依赖
cat feeds/<..>/<app>/root/usr/share/luci/menu.d/<app>.json
# 2) 门控语义（luci-base）：fs 依赖的三种 kind 检查
#    luci-base/ucode/dispatcher.uc:171 check_fs_depends()
#      directory → lsdir 非空；executable → stat.type=='file' && user_exec；file → 仅存在；absent → 不存在
#    → 任一不满足 ⇒ check_depends() 返回 false ⇒ **整个菜单节点被丢弃**（页面 JS 还在 www 里，但进不去）
# 3) 谁提供那个被门控的文件 → 那个包在 .config 里是否 =y
grep -rn "被门控的路径" feeds/ package/
grep -E "CONFIG_PACKAGE_<pkg>" .config
```

实例（本机 zn515xg 移植）：PON「诊断」页缺 → 门控是
`fs: {"/usr/libexec/airoha-pon-debug": "executable"}` → 该文件由 `airoha-pon-debug` 包提供，
而 `.config` 里是 `# CONFIG_PACKAGE_airoha-pon-debug is not set` → 勾上即恢复。
另一个经典门控：LuCI 挂载点页 = `fs: {"/sbin/block": "executable"}` → 该文件由 **`block-mount`**
（注意它定义在 `package/system/fstools/Makefile` 里，不在 `package/system/block-mount/`）提供；
USB 挂载还需 `kmod-usb-storage`(+`-uas`)、`kmod-scsi-core`、`kmod-fs-{ext4,vfat,exfat}`、`kmod-nls-*`，
而 USB 控制器本身 `kmod-usb3`/`kmod-usb-xhci-mtk` 通常已在。

> 判断"是不是我们漏了"的快速法：`apk list -I`（新）或 `opkg list-installed` 导出**厂商固件**包清单，
> 与 `bin/targets/.../*.manifest` 的包名 `comm -13` 一下，就能列出"厂商有我们没有"的全部包。

## 改"出厂默认值"要改哪里（**优先 target 局部，别改 base 包**）

用户常提这类需求：「默认打开 WiFi」「默认 region 改成 XX」「LAN 的 DHCPv6 默认关掉」
「换个默认 SSID」。正确落点取决于生成机制 —— 改 base 包会在下次同步厂商树/上游时丢失。

| 需求 | 落点 | 关键机制 |
|---|---|---|
| 无线默认：region/SSID/加密/**是否默认开启** | `<target>/<sub>/base-files/etc/board.d/0X_wireless` | `wifi-scripts` 的 `/lib/wifi/mac80211.uc` 从 **board.json 的 `wlan.defaults`** 生成 `/etc/config/wireless`：`wlan.defaults.country` → `option country`；`wlan.defaults.ssids.<band>` → ssid/encryption/key。**`set ${si}.disabled='${defaults ? 0 : 1}'` ⇒ 想让 AP 刷完自动开，必须真的预置一个 SSID**（只设 country 不够，WiFi 仍是 off）。board.d 里用官方 helper：`ucidef_set_country "CN"` + `ucidef_set_wireless <2g\|5g\|6g\|all> <ssid> [encryption] [key]`（`ucidef_set_wireless` 见 `-z "$ssid" && return`，空 SSID 直接返回）。写法照抄 `package/boot/uboot-tools/uboot-envtools/files/fw_defaults`：`. /lib/functions/uci-defaults.sh` → `board_config_update` → helper 调用 → `board_config_flush`。board.json 里 `wlan.phy*` 由 `/sbin/wifi config` 时的 `wifi-detect.uc` 填，它只删 `phy*` 和 `.info`，**保留 `defaults`** |
| 某个服务/接口选项的默认值（如 `dhcp.lan.dhcpv6='disabled'`） | `<target>/<sub>/base-files/etc/uci-defaults/9X-<board>-defaults` | 用 **`uci set <单个选项>` + `uci commit`**，**绝不整份重写**配置文件（否则会丢 `globals`/`dnsmasq`/`odhcpd` 等节，症状见上文「全局网络选项空白」）。uci-defaults 是被 **source** 执行的（`/etc/init.d/boot` 里 `( . "./$file" ) && applied=...`，**成功才自删**），所以结尾要 `exit 0`；`[ "$(board_name)" = "..." ] \|\| exit 0` 这种守卫在别的机型上会返回 0 并被删除，属正常 |
| 内核/驱动层面的默认（regdomain 限制、模块参数） | `<target>/<sub>/config-6.18` 或内核补丁 | 别碰 base 包 |

> 查厂商标的"出厂默认"是否真的生效过：拿**厂商原生固件镜像**当对照。例如判断
> 「DT 里的内存容量要不要自己改」——把厂商 imm 镜像里的 DTB 解出来看 `memory@` 的值，
> 再和设备**运行时** `/sys/firmware/fdt` 的值比：若两者不同，说明 bootloader 会改写该节点，
> DTS 里写的就只是兜底值，**不用改**（u-boot 侧典型实现：
> `arch/arm/mach-airoha/an7581/init.c` 的 `dram_init()` 读 `SCREG_WR1=0x1fb00284` bit[29:20] × 16MiB）。
> 从 FIT/镜像里抠 DTB 的办法：按 FDT magic(`d0 0d fe ed`) 扫偏移，读头部的 `totalsize` 切片，
> 再 `dtc -I dtb -O dts` 找含目标节点/`model` 的那份。

## 往 LuCI 首页（概览）加一块显示项，不必改 LuCI

`luci-mod-status` 的 `htdocs/luci-static/resources/view/status/include/` 是**可插拔目录**：
`view/status/index.js` 的 `load()` 会
`fs.list('/www' + L.resource('view/status/include'))` → 把每个 `.js` 变成
`view.status.include.<basename>` 模块 `L.require`，再按文件名排序，各自渲染成一个带
「隐藏/显示」开关的 `cbi-section`。所以**加新板块 = 往那个目录丢一个文件**：

- 模块写法：`baseclass.extend({ title: _('…'), load: function(){…}, render: function(data){…} })`；
  表格照抄现有板块：`E('table',{'class':'table'})` + `E('tr',{'class':'tr'})` +
  `E('td',{'class':'td left','width':'33%'})`。文件名前缀决定位置（如 `55_` 落在 `50_dsl` 与 `60_wifi` 之间）。
- 刷新：概览页会一起 poll（默认 5s），`load()` 每次都会被调用；跨轮次的状态放模块级变量即可。
- **模块工厂必须返回一个类**（`baseclass.extend({...})`）。返回普通对象会被加载器判为
  `factory yields invalid constructor`（`luci.js` 里 `Class.isSubclass(_class)` 校验），整块不渲染。
  加载器随后 `new _class()` 并把**实例**作为 `L.require()` 的结果 —— 所以跨轮次的状态放模块级变量、
  方法写在类里都没问题。
- **厂商的做法**：若厂商把温度/CPU 占用塞进了「系统」板块（imm 就是这样），那是它直接改了
  `10_system.js`，并加了**私有 rpcd 方法**（`luci.getTempInfo`/`luci.getCPUUsage`，上游树没有）。
  两种落地方式都可行，按用户偏好选：
  - **独立板块**（往 include/ 丢文件）：改动最隔离，跟上游永不冲突；
  - **并入「系统」板块（模仿厂商）**：把 feed 的 `10_system.js` 拷到 **顶层 `files/`**（`files/www/luci-static/resources/view/status/include/10_system.js`）
    —— **别放 target base-files**，否则和 `luci-mod-status` 撞同一个路径、apk 会拒绝（见下节），再改：
    在 `fields` 数组上插行/追加行 —— `fields` 是 `[标签, 值, 标签, 值, …]`，**必须成对增删**，
    可用 `fields.splice(fields.indexOf(_('Local Time')), 0, 标签, 值)` 定位插入点、`fields.push(标签, 值)` 追加。
    写复杂逻辑时另建一个辅助模块（放在 `files/www/luci-static/resources/<name>.js`，用 `L.require('<name>')` 引入），
    覆盖版 `10_system.js` 的 diff 就越小、越好跟上游对。
  无论哪种都**不要抄厂商的 rpcd**，改成读文件实现（厂商那套方法在你用的上游 LuCI 里不存在）。

### ACL：`file.read` 与 `file.exec` 的路径判定**不一样**

rpcd 的 `file` 插件有两套判定（`rpcd/file.c`）：

| 操作 | ACL 匹配用的路径 |
|---|---|
| `file.read`（`fs.read` / `fs.trimmed` / `fs.lines`） | **请求路径**先查一次，再 `realpath()` 解析符号链接后**按真实路径再查一次**（`rpc_check_symlink_access()`） |
| `file.exec`（`fs.exec`） | **只按命令字符串**：`rpc_canonicalize_path()` 仅做规范化（合并 `//`、去 `/./`、折叠 `/x/../`），**不解析符号链接** |

`/sys/class/thermal/*`、`/sys/class/hwmon/*`、`/sys/class/net/*` 都是符号链接（真机实测：
`/sys/class/hwmon/hwmon0/temp1_input` → `/sys/devices/platform/soc/<pcie>/…/ieee80211/phy0/hwmon0/temp1_input`），
所以 read 类要把**两套路径**都放行：

```json
"/sys/class/hwmon/hwmon*/temp1_input":                    [ "read" ],
"/sys/devices/*/ieee80211/phy*/hwmon*/temp1_input":        [ "read" ],
"/usr/sbin/<dev>-helper":                                  [ "exec" ]
```

- 匹配用 `fnmatch(pattern, path, FNM_NOESCAPE)`（**没有 FNM_PATHNAME**）⇒ `*` **能跨 `/`**，深层路径一条通配即可。
- `"ubus": { "file": [ … ] }` 要列出**用到的每个方法**（`read` / `exec` / `stat`），
  照抄 `luci-mod-system-flash` 的 `["exec","read","stat"]`。
- 自定义 ACL 组会自动生效（rpcd 默认登录配置是 `list read '*'`，`package/system/rpcd/files/rpcd.config`）。
- ⚠️ **`rpc_file_access(sid = NULL)` 直接返回 true** ⇒ 在 SSH 里裸跑 `ubus call file exec …` 会**绕过** ACL，
  **不能用它验证 ACL 对不对**；LuCI 一定带 session，真实场景下才真正校验。
- 想自己核对（零风险）：拿真机 `readlink -f` 的 realpath，在本地用 Python `fnmatch`（FNM_NOESCAPE）模拟一遍。

### ⚠️ rpcd 读不了 procfs/debugfs 的"大"文件：`file.read` 对 `st_size == 0` 只给 4 KiB

`rpcd/file.c`：`RPC_FILE_MAX_SIZE = 4096*64`（≥256 KiB 直接 `UBUS_STATUS_NOT_SUPPORTED`），
而 `st_size == 0` 的**伪文件**（procfs/debugfs，如 `/proc/net/nf_conntrack`、`sysfs` 下多数文件）
会走 `s.st_size = RPC_FILE_MIN_SIZE`（**4096**）—— **只读到前 4 KiB**，而且不报错。
所以「数行数」「统计全文」这类需求用 `fs.lines(path).length` 会静默得到偏小的错值（踩过一次）。

✔ 正确做法：放一个**本机小脚本**，用 `fs.exec()` 调它，由它在设备上读文件、算好、只回结果：

```sh
# target/.../base-files/usr/sbin/<dev>-connstat   （权限必须 755）
tcp_total=$(grep -c '^ipv4' /proc/net/nf_conntrack)   # 单值小文件用 cat/grep 都行
```
```json
"read": {
  "file": { "/usr/sbin/<dev>-connstat": [ "exec" ] },
  "ubus": { "file": [ "read", "exec" ] }
}
```
- 授权是**路径级**：`rpc_file_access(sid, realpath(cmd), "exec")`；`fs.exec(cmd)` 不带参数时只校验命令路径
  （`luci-app-acme` 就是这么写的）。要带参数则**整条命令行**一起匹配（见 `luci-mod-system-flash` 的
  `"/usr/sbin/uhttpd -m *": ["exec"]`）。
- `ubus` 段必须给 `file` 的 `exec` 方法，否则方法级就被拒（照抄 `luci-mod-system-flash` 的 `["exec","read","stat"]`）。
- 另一条路是 cgi-io 的 `fs.read_direct()` / `exec_direct()`（无 4 KiB 限制，但要额外 `"cgi-io": ["read"/"exec"]`）。
- busybox 的 `grep`/`awk` 都有（`/bin/grep`、`/usr/bin/awk` 是指向 busybox 的链接），脚本里用它们足够；
  但**别写死 `/bin/wc`**（不一定有独立链接）。

### 覆盖/补充包里的文件：⚠️ 走 apk 的构建必须放顶层 `files/`，否则编译直接失败

**踩过的坑**：把覆盖文件放 `target/linux/<target>/<sub>/base-files/...` 时，它会**被打进 `base-files` 包**；
而新构建（`CONFIG_USE_APK`）里 **apk 不允许两个包提供同一路径**，于是 `package/install` 阶段报：

```
ERROR: luci-mod-status-…: trying to overwrite www/luci-static/resources/view/status/include/10_system.js
       owned by base-files-…
1 error; … MiB in … packages
```

旧的 opkg 是"静默覆盖"，所以这类做法在 opkg 时代能跑、换成 apk 就炸。

**正确位置**：顶层 **`$(TOPDIR)/files/`**（目录名就叫 `files`，与包的 `files/` 无关）。
依据 `include/image.mk` 的 `$(call prepare_rootfs,$(mkfs_cur_target_dir),$(TOPDIR)/files)`，
`include/rootfs.mk` 的 `prepare_rootfs` 第一步 `file_copy($(TOPDIR)/files/., <rootfs>)` ——
**在包安装之后、跑 postinst 之前**叠加整棵树，完全不经过包管理器（无包归属 ⇒ 无冲突），
且 sysupgrade / initramfs 两个镜像都生效。

```
openwrt/files/www/luci-static/resources/view/status/include/10_system.js   ← 覆盖 luci-mod-status 的文件
```

⇒ **优先级链：包 < target base-files < `files/`**。选择规则：

| 情况 | 放哪 |
|---|---|
| 覆盖别的包已有的文件（如 `10_system.js`） | 顶层 `files/`（必须） |
| 新增文件、与任何包都不撞（如自写脚本、新 ACL json） | target base-files（正规做法，归 `base-files` 包） |
| 板级脚本（board.d / uci-defaults / platform.sh / LED） | target base-files（本来就是这么设计的） |

两种位置都**不受 `./scripts/feeds update` 影响**（都不在 `feeds/` 里）。

**排查手法**：`make -j8` 在 apk 阶段失败时 quiet 日志里**看不到错误详情**，
复现：`make package/install -j1 V=s > log 2>&1`，再把 `(N/M) Installing …` 行过滤掉，就能看到 `ERROR: …`。

### an7581 上这几项传感器/计数器在哪（可直接复用）

| 指标 | 路径 |
|---|---|
| CPU 温度 | `/sys/class/thermal/thermal_zone0/temp`（毫摄氏度；驱动 `airoha_thermal`，DTS `cpu-thermal`） |
| WiFi 温度 | `/sys/class/hwmon/hwmonN/temp1_input`（毫摄氏度；`name`=`mt7915_phy0/phy1`，由 mt7915 的 hwmon 提供；**hwmon0=2.4G、hwmon1=5G**，可用 `uci show wireless` 的 `.band` 映射，也可以直接按 hwmonN 取） |
| **PON 光模块温度** | `/sys/kernel/debug/airoha-xpon-pon0/frontend` 里的 `temperature_8472: 0x%04x`。这是 **EN7572 DDMI 寄存器 0x60**，**有符号 8.8 定点**（1 count = 1/256 °C，即 `值/256` ℃，负数回绕到上半区）。驱动侧 `feeds/pon_drivers/airoha-pon-frontends/src/airoha-en7572.c` 读入 → `xpon-diagnostics.c` 的 `pon_frontend_debug_show()` 打印。⚠️ 该 dump 里**只有这一处温度**，没有其它地方暴露光模块温度（驱动未注册 hwmon/thermal） |
| CPU 占用率 | `/proc/stat` 首行 `cpu …` 两次采样求 `(Δtotal-Δidle)/Δtotal` |
| 各协议族/各协议连接数 | `/proc/net/nf_conntrack`：每行 `l3名 l3号 l4名 l4号 …`，即 `$1`=ipv4/ipv6、`$3`=tcp/udp/icmp；`awk '$3=="tcp"'` 直接分协议。总数也有 `/proc/sys/net/netfilter/nf_conntrack_count`（IPv4-only 旧路径 `/proc/net/ip_conntrack` 已不存在） |
| 硬件卸载的流 | 同一文件的**行尾状态标记**：`[HW_OFFLOAD]` / `[OFFLOAD]` / `[ASSURED]` **三者互斥**（`nf_conntrack_standalone.c`，HW 优先）。`[HW_OFFLOAD]` 由 `nf_flow_table_offload.c` 写入，即"已进 NPU 的流"；airoha PPE 注册了 `ndo_setup_tc` / `TC_SETUP_FT` 硬件 flowtable ⇒ 这个标记可靠 |
| PPE 硬件流表（原始） | `/sys/kernel/debug/ppe/{config,entries,bind}`，每行 `%05x STATE TYPE …`：`STATE`∈INV/UNB/BND/FIN（`bind` 只列 BND），`TYPE`∈`IPv4 5T`/`IPv4 3T`/`IPv6 3T`/`IPv6 5T`/`L2B`/`DS-LITE`/`6RD`。**没有 L4 协议字段**（只打印地址/端口）⇒ 想按 TCP/UDP 分就得改从 conntrack 取 |
| 卸载开关（uci） | `firewall.@defaults[0].flow_offloading` / `flow_offloading_hw` |

> 上面这些**伪文件全都要走上一节的 exec 小脚本**（`file.read` 只有 4 KiB）。
> **例外**：`…/xpon-pon0/frontend` 那个 dump 只有 8 行 ≈ 200 字节，`fs.trimmed()` 直接读即可，
> 不必为它写脚本；只有 conntrack / `ppe/bind` 这种会长的表才需要走 exec。

### 只改 LuCI 资源/ACL 时：热部署到**正在运行**的设备（免重刷）

纯 JS/JSON 的改动（LuCI 页面、rpcd ACL）不需要重编固件，可以直接推到设备上看效果：

```bash
# OpenWrt 上通常没有 sftp-server，scp 会 "Connection closed"；也没有 install(1)。
# 用管道写就行（别忘 chmod）：
ssh root@<dev> 'cat > /www/luci-static/resources/<x>.js && chmod 644 /www/luci-static/resources/<x>.js' < local.js
ssh root@<dev> 'cat > /usr/share/rpcd/acl.d/<x>.json && chmod 644 /usr/share/rpcd/acl.d/<x>.json' < local.json
ssh root@<dev> '/etc/init.d/rpcd reload'        # 让新 ACL 生效（否则新路径会被拒）
ssh root@<dev> 'touch /lib/apk/db/installed'    # 让浏览器缓存失效（见下面「缓存」一节）
```

要点：
- **先备份**：`cp -a <文件…> /root/<backup>/`。回退也可以直接 `rm` overlay 里的副本
  （`/www/...` 原本在 squashfs 只读层，写入只是生成了 overlay 上层副本）。
- 部署后用 `cmp <(ssh root@dev 'cat <path>') local_file` 确认逐字节一致 —— 走管道容易踩换行/截断。
- **验证 ACL 是否真的放行**：建真会话再带 `session` 调 ubus（`sid=NULL` 会被直接放行，测不出问题）：
  ```bash
  SID=$(ssh root@<dev> 'ubus call session login "{\"username\":\"root\",\"password\":\"\"}" | jsonfilter -e @.ubus_rpc_session')
  ssh root@<dev> "ubus call file read '{\"path\":\"<p>\",\"session\":\"$SID\"}'"
  ssh root@<dev> "ubus call session destroy '{\"ubus_rpc_session\":\"$SID\"}'"
  ```


### 刷不了机/设备不可达时，怎么验 LuCI 模块（打桩跑 JS）

改完 LuCI 的 JS 但设备连不上（网线被拔、在别人手上）时，**不要盲发**：把模块放进
`new Function(...)` 里、桩掉 LuCI 的运行环境，就能用**真机采集的数据**跑通整条数据链。

```js
const Klass = new Function('baseclass','fs','uci','L','E','_', src)
                (stubBaseclass, stubFs, stubUci, stubL, stubE, stub_);
const mod = new Klass();            /* 工厂给的是类，必须 new（照 luci.js 的顺序） */
mod.load().then(d => renderRows(mod.render(d)));
```
要点：
- LuCI 模块其实就是「若干 `'require x';` 字符串语句 + 顶层 `return`」，
  **用 `new Function` 包一层就变成可调用函数**，那些 `'require'` 是无副作用的字符串表达式。
- **工厂返回的是"类"，必须自己 `new`**（`luci.js`：`_class = factory(window, document, L, …deps)` → `new _class()`）。
  所以桩 `baseclass` 要真的是个类：
  `BaseClass.extend = props => { function C(){}; C.prototype = Object.create(BaseClass.prototype); Object.assign(C.prototype, props); C.extend = BaseClass.extend; return C; }`。
  桩写成 `extend: o => o` 会在 `new` 时报 `not a constructor` —— 而**真机上返回普通对象同样不行**，
  LuCI 会报 `factory yields invalid constructor` 且整块不渲染（踩过一次）。
- 其余桩：`_ = s => s`；`L.resolveDefault = (p,d) => Promise.resolve(p).catch(()=>d)`；
  `E(tag,attrs,children)` 返回带 **`appendChild`** 的对象（模块会调它，别忘了）；
  `fs.trimmed/lines` 从「路径→内容」的 fixture 表里取，`fs.exec` 返回 `{ stdout, code }`；
  `uci.load = () => Promise.resolve()`、`uci.sections(conf,type,cb)` 逐个回调 section 对象；
  `uci.get(conf,sec,opt)` 要**按选项名分别返回**（一律返回同一个值会把 `clock_hourcycle` 之类搞崩）。
- **`String.prototype.format` 必须自己补**（`cbi.js` 里才有）：`%s/%d/%f`、`%.Nf`、以及 **`%%` → 字面 `%`**
  （LuCI 的实现在 `pType == '%'` 时输出 `%`）。用错会导致百分比这类字符串多出一个 `%`。
- `/proc/stat` 这类「需要两次采样」的来源，用样本队列喂：第一次给 A（触发模块内部的补采），
  第二次给 B/C，就能同时验证「首次基线」和「轮询求差」两条路径，并用**可手算的合成样本**断言百分比。
- **输入要用「设备上那份文件」本身**：`ssh root@dev 'cat <path>' > dep.js` 取回来、`cmp` 确认与源码
  逐字节一致，再让脚本读 `dep.js`。这样验的是**实际生效的东西**（而不是你本地以为要部署的东西）。
- 断言写在实例上（`new Klass()` 之后 `typeof inst.read`），**不要对工厂返回值取方法**
  （`Klass.read` 必然是 `undefined`，会误报"工厂没返回类"）。
- 自己拼「分段 dump」时注意**剥掉分隔符后的换行**：`@@@name@@@\nvalue\n` 按分隔符切分后，
  value 段会带前导 `\n`；只用 `replace(/\s+$/,'')` 会留下它，导致 `parseInt` 侥幸能过、
  但 `indexOf(...) == 0` 这类**前缀比较静默失败**（表现为某一项莫名缺失）。用 `.trim()` 最稳。
- 真机数据采集只需 ssh 过去 cat 那几个文件（本机/对照设备都可以，同 SoC 就行），
  存成 fixture 即可；这样刷机前就能确定「解析、映射、格式化、渲染链」都没问题。

## 构建期默认值：两个容易漏的开关

### 本地/厂商 feed 别出现在设备的软件源列表里

`/etc/apk/repositories.d/distfeeds.list`（opkg 侧是 `/etc/opkg/distfeeds.conf`）由
`include/feeds.mk` 的 `FeedSourcesAppendAPK` / `FeedSourcesAppendOPKG` 生成，逐条
`$(if $(CONFIG_FEED_$(feed)), …)`；而 `CONFIG_FEED_<feed>` 是 `scripts/feeds` 的 `feed_config()`
动态生成的 **tristate**（已安装的 feed `default y`，help 原文 "Say M to add the feed commented out"）。
于是加了本地 feed（如厂商的 `pon_drivers` / `pon_userspace`）之后，设备上会多出
`.../snapshots/packages/<arch>/<feed>/packages.adb` 这种**上游并不存在的源**。
⇒ 在 `.config` 里显式关掉即可（**只影响源列表，不影响用该 feed 编译包**）：

```
# CONFIG_FEED_pon_drivers is not set
```

（`make defconfig` 会保留该 not set；若设成 `m`，生成的是被注释掉的行。）
设备上已存在时临时清理：`sed -i '/<feed>/d' /etc/apk/repositories.d/distfeeds.list`
（该文件是构建期生成的，`sysupgrade -n` 后会被镜像里的新版本覆盖。）

### 设备的源地址、以及 kmod 的「内核哈希」绑定（自建源必读）

- 源前缀 = 构建期变量 `VERSION_REPO`（源文件里的 `%U`，`VERSION_SED_SCRIPT` 替换），
  取值 `CONFIG_VERSION_REPO`，`CONFIG_VERSIONOPT` 不开时默认 `https://downloads.openwrt.org/snapshots`
  （Kconfig 在 `package/base-files/image-config.in` 的 `VERSIONOPT` 菜单；兜底在 `include/version.mk:35`）。
  想让自建镜像**自带自建源**：`CONFIG_VERSIONOPT=y` + `CONFIG_VERSION_REPO="https://<自己的站>"`，
  站点按 `targets/<t>/<st>/packages/` + `packages/<arch>/<feed>/` 摆即可。
- **kmod 绑的不是内核版本号，是内核配置的哈希**：`include/kernel-defaults.mk` 用
  `grep '=[ym]' .config.set | sort | md5 > .vermagic`；`include/kernel.mk` 的 `KernelPackage` 里
  `EXTRA_DEPENDS:=kernel (==$(LINUX_VERSION)~$(LINUX_VERMAGIC)-r$(LINUX_RELEASE))`。
  官方下载站的 kmods 目录名就是这个哈希（`.../kmods/<ver>-<rel>-<hash>/`，**只有 `CONFIG_BUILDBOT=y`
  才会写进设备源列表**）。⇒ 别人编的 kmod 装不进来，与内核版本号相同也白搭。
- **要「以后随时能装 kmod」，先把内核配置定死**：`CONFIG_ALL_KMODS=y`（`config/Config-build.in`）。
  否则以后单独补编一个 kmod 会改内核 .config ⇒ 哈希变 ⇒ 装不上已刷的设备（连带要重刷）。
  ⚠️ 光写这一行不生效，且下面「把 target 级 feed 打进固件」是最省事的整体解法 —— 两处都务必先看。
- **内核侧没有第二道闸**：实测 .ko 的 vermagic 只有 `6.18.52 SMP mod_unload aarch64`（**不含哈希**），
  典型 OpenWrt 内核 `CONFIG_MODVERSIONS` / `CONFIG_MODULE_SIG` 都没开 ⇒ 同版本、同 SMP/PREEMPT 的外来模块
  会被放行，真实风险是**静默 ABI 漂移**（版本号相同 ≠ 结构体相同，尤其移植时打过大量厂商补丁）。
  `CONFIG_MODULE_FORCE_LOAD` 也没开 ⇒ 跨内核版本的模块连 `insmod --force` 都塞不进（天然下限）。
- 想让**自建** kmod 不被哈希钉住：把 `include/kernel.mk` 那行改成 `EXTRA_DEPENDS:=kernel`（去掉版本约束）。
- ⚠️ `apk --force-broken-world` **不是**绕过办法：它的语义是
  "delete world constraints until a solution without conflicts is found"（`src/solver.c`），
  会把你要装的那个包直接从事务里删掉 ⇒ 等于没装。
- 本地构建的 `bin/targets/<t>/<st>/packages/`（kernel + base-files + 全部 kmod + `index.json` + `packages.adb`）
  **本身就是可托管的 apk 源目录**，不必像 buildbot 那样拆成 `kmods/<hash>/`。
- **⚠️ 别指望"再提供一个别的哈希"就能装外来 kmod（沙盒实测，2026-09-25）**：
  apk 的 solver 对**同一个依赖名只保留一个 provider**。设备上那个名字是 `kernel`：
  已装的 N 个 kmod 钉在哈希 A ⇒ 真实 kernel 必须占住这个槽；外来 kmod 要哈希 B ⇒ 需要第二个 provider
  ⇒ **两套哈希不可能并存**，报 `breaks: kmod-x[kernel=…B]`。实测矩阵（宿主 apk + `/tmp` 假 root + 完整 world）：

  | 做法 | 结果 |
  |---|---|
  | 给已装 `kernel` 的 `p:` 追加 `kernel=<B>` | ✗ `conflicts:`（一个包提供与自己版本不同的**同名**版本） |
  | 独立 stub 包提供 `kernel=<B>`，自家 kmod 仍钉 A | ✗ solver 仍选真实 kernel，同基线 |
  | stub 同时提供 A/B 两个版本 | ✗ 同基线 |
  | 只把自家 kmod 的 `kernel=<A>` 放宽成 `kernel`（不加 stub） | ✗ 外来 kmod 要 B，无人提供 |
  | **放宽自家依赖 + stub 提供 B** | **✓**（代价：apk 会 purge 掉真实 kernel 占位包，账本里 kernel 变成 B） |

  ⇒ 想装"别人编的 kmod"必须**两件一起做**：放宽自家 kmod 的依赖（上面那行构建改动）+ 发一个
  provides `<外来哈希>` 的占位包。**只做后者无效**；只做前者只服务自家 kmod。
- **搭这个沙盒的四个坑**（以后要验证任何 apk 依赖/安装策略时照抄，省几小时）：
  1. `apk --root <dir>` 报 `Unable to read database` 的真因是**缺 `<dir>/etc/apk/world`**，不是缺 db 文件
     （`database.c` 里 world 读失败 → `-ENOENT`，而 `query` 不带 `APK_OPENF_CREATE`）。
  2. 缺 `<dir>/etc/apk/arch`（内容如 `aarch64_cortex-a53`）时宿主 apk 按 x86_64 判定 ⇒ 所有目标架构包
     被判 `uninstallable`，真因被 libc/libgcc1 噪声淹没。
  3. installed 里 **`C:<校验和>` 在条目开头、`P:` 之前**（不是结尾）。缺它 → `apk_db_pkg_add` 因
     `tmpl->id.len < SHA1` 返回 NULL → 被报成极具误导性的 `v2 database format error`。
     可自造：`'Q1' + base64(sha1(任意串))`（只需与已有包不撞）。
  4. 官方 kmods 目录可直接当源：`repositories-file` 里写一行 `file:///…/packages.adb`
     （**不能**用 `-X <dir>`，那会被当成 `<dir>/<arch>/APKINDEX.tar.gz`）。
     工具用 `staging_dir/host/bin/apk`（3.0.5）+ `--allow-untrusted`；假 root 的 world 要照设备填，
     否则 apk 会把不在 world 里的包全判为 orphan 并 purge，输出被淹没。

### 最干净的解法：把 target 级 feed 直接打进固件，用 `file://` 当源
（2026-09-25 在 515xg 上实施，机制全部核实）

上一节那些哈希麻烦（拆 `kmods/<hash>/`、放宽依赖、stub 包）**全都可以绕开**：让源就是同一次构建的产物。
`apk` 原生支持 `file://`（设备实测报 "No such file" 而非 "unsupported scheme"），**不需要起 HTTP 服务**。

四处改动：

1. **`.config`：`CONFIG_ALL_KMODS=y`** —— 但有个**必踩的坑**：
   只加这一行再 `make defconfig` **完全无效**（输出 `No change to .config`）。
   因为 `.config` 里几百条 kmod 本来就有显式 `# CONFIG_PACKAGE_kmod-x is not set`，
   Kconfig 把"显式 no"当用户值保留，**不会被 `default m` 覆盖**。
   正确顺序：**先删掉所有 `# CONFIG_PACKAGE_kmod-<x> is not set` 行，再 `make defconfig`**。
   想保留哪些不编，就先单独把那几行留下来（见下条）。
2. **排掉不需要的大固件包**：不用改包定义、不用产物过滤 ——
   kmod 包在 Kconfig 里**带 prompt**（`tristate "kmod-xxx…"`，由 `scripts/package-metadata.pl` 生成，
   **没有 `if !ALL_KMODS` 门控**），所以里 `# CONFIG_PACKAGE_kmod-mt799x is not set` 能压住 `ALL_KMODS`。
   （典型收益：mt7990/7992/7996 那几块别的 WiFi 芯片固件约 12.7 MB。）
3. **`include/feeds.mk` 的 `FeedSourcesAppendAPK`**：第一行 `%U/targets/%S/packages/packages.adb`
   → `file:///usr/share/kmods/packages.adb`；架构级那两行的 `%U` 换成自定义 `DIST_FEED_BASE_URL`
   （换成别的发行版镜像站时用得上）。
4. **把产物拷进 rootfs 并重建索引** —— 这一步的时机是**整个方案最容易搞错的地方**，2026-09-25 在
   515xg 上第一版就写错了（`BUILD_EXIT=0`、构建树里文件齐全，固件里一个都没有）：
   - **squashfs 是从 `$(TARGET_DIR)` 打包的**，即 `build_dir/target-<arch>_<libc>/root-<board>`，
     **不是 `STAGING_DIR_ROOT`**（`staging_dir/...` 那个是包编译阶段的 staging root，两者内容不同）。
     依据：`include/image.mk` 的 `mkfs_target_dir` / `mksquashfs4`；`rules.mk` 的
     `TARGET_DIR:=$(TARGET_ROOTFS_DIR)/root-$(BOARD)`，而 `TARGET_ROOTFS_DIR` 默认 `$(BUILD_DIR)`。
   - **❌ 不要挂 `define Image/Build`。** `image.mk` 里：
     ```make
     install-images: kernel_prepare $(foreach fs,...,$(KDIR)/root.$(fs))   # 前置依赖
             $(foreach fs,$(TARGET_FILESYSTEMS),$(call Image/Build,$(fs)))  # 配方体
     ```
     make 先把前置依赖全做完（`mksquashfs4` 打出 `$(KDIR)/root.squashfs`、各设备的
     `$(BIN_DIR)/*.itb` 也都写好了），**然后**才跑配方体 ⇒ 钩子永远晚一步。实测纳秒 mtime：
     `.itb` 05:06:48.267、`TARGET_DIR/usr/share/kmods` 05:06:49.115 —— 晚了 0.85 秒，
     文件全在构建树里，镜像里 0 个。（另注：`Image/Build` 在 airoha 等 target **上游根本没定义**，
     `$(call Image/Build,squashfs)` 是个空调用，所以覆盖它还会给自己加戏。）
   - **✅ 正确 hook：把铺 feed 做成本 target `image/Makefile` 里
     `$(KDIR)/root.squashfs` 的额外前置依赖**（GNU make 会把显式规则的前置依赖合并到 pattern rule
     `$(KDIR)/root.%: kernel_prepare` 上；上游自己就用这招挂 `target-dir-<profile>`）：
     ```make
     define Image/Prepare
     	rm -rf $(KMOD_FEED_DIR)          # 清残留；且必须早于 initramfs cpio
     endef

     .PHONY: <dev>-kmod-feed-stamp
     <dev>-kmod-feed-stamp: kernel_prepare     # 钉顺序：晚于 initramfs
     	$(call <dev>-kmod-feed)

     $(KDIR)/root.squashfs: <dev>-kmod-feed-stamp   # 钉顺序：早于 mksquashfs
     ```
     两个顺序都有硬理由：
     * **早于 `mksquashfs4`** —— 否则就是上面那个 bug。
     * **晚于 `kernel_prepare`** —— `include/kernel-defaults.mk` 给内核写
       `CONFIG_INITRAMFS_SOURCE="$(TARGET_DIR) …"`，**initramfs/recovery 镜像内嵌的是
       `$(TARGET_DIR)` 的 cpio**；feed 若此刻已在 TARGET_DIR 里，恢复镜像会凭空胖几十 MB。
       同理必须清掉 `$(TARGET_DIR)/usr/share/kmods`：**它不属于任何 apk 包，不会在两次构建
       之间被自动清掉**。
     * ⚠️ **但挂在 `Image/Prepare` 里清理远远不够早！**（真机踩过，后果是刷完循环重启）
       `Image/Prepare` 属于 `image_prepare`，在 **`target/install`** 阶段；而内核编译在
       **`target/compile`**，比它**更早**。⇒ **上一轮铺的 feed 残留，会在下一轮"内核重编"
       时被原封不动打进 initramfs**。
       实测：TARGET_DIR 64 MB（含 34 MB 残留）⇒ 编出的内核与 recovery 一起膨胀，刷完
       **循环重启（约 90 s 一轮）根本进不了系统**，而此时内核 config 本身一点没变，
       极难想到是 initramfs 被污染。
       修法二选一：
       - 把清理挂到**内核编译之前**（target 的 `Makefile` 里给 `compile` 加前置，
         或重定义 `Kernel/Prepare`）—— 这是正解；
       - 或每轮开编前手工 `rm -rf $(TARGET_DIR)/usr/share/kmods`。
       **判定残留的硬指标**：`du -sh $(TARGET_DIR)` 应在 **30 MB 上下**；
       若 **60 MB+** 就是上一轮的 feed 还在，此刻千万不能让内核重编。
     * 校验方法（不开编）：`make -C target/linux/<t>/image TOPDIR=$PWD -pn --eval='__probe: ; @:' __probe
       | grep -A4 'root\.squashfs:'`，应看到自己的 stamp 出现在前置依赖里。
     * 顺带：`$(KDIR)/root.squashfs.pagesync`（FIT 真正吃的那份）由 `Build/fit-its`
       （`image-commands.mk`，`dd … bs=4096 conv=sync`）在 IMAGE 配方里生成，属 `.itb` 的前置依赖，
       自动排在 `root.squashfs` 之后，不必管。
   - **索引要自己生成**：`packages.adb` 由 `package/index` 产出，而它在顶层 `world` 里排在
     `target/install` **之后**，hook 时还不存在。照抄 `package/Makefile` 的写法：
     `apk mkndx --root $(TOPDIR) --keys-dir $(TOPDIR) --allow-untrusted
     $(if $(CONFIG_SIGNED_PACKAGES),--sign $(BUILD_KEY_APK_SEC),) --output packages.adb *.apk`
     再 `apk adbdump --format json packages.adb | scripts/make-index-json.py -f apk -a "$(ARCH_PACKAGES)" - > index.json`。
   - 变量（**在 image 子 make 里用探针读过，别凭记忆**）：
     `make -C target/linux/<t>/image TOPDIR=$PWD -s --eval='__probe: ; @echo $(PACKAGE_DIR)' __probe`
     ⇒ `BIN_DIR = bin/targets/<board>/<subtarget>`（`rules.mk`，**target 构建里 BIN_DIR 就是它**），
     所以 `PACKAGE_DIR = $(BIN_DIR)/packages` = `bin/targets/<board>/<subtarget>/packages`，
     里面正好是本次该 target 的全部包（**含 `kernel-<ver>~<hash>-r1.apk` 占位包**，
     本地源要靠它解 `kernel (==…)` 依赖）。⚠️ 别拿 `bin/packages`（那是 `PACKAGE_DIR` 的顶层同名物，
     只有 feed 里少数包，且顶层根目录下 0 个 `.apk`）。
     `BUILD_KEY_APK_SEC = $(TOPDIR)/private-key.pem`。
   - **验收别直接 `unsquashfs4 -l <itb>`**：FIT 不是 squashfs，会报
     `Can't find a valid SQUASHFS superblock`（看着像"镜像里没有"，其实是命令用错）。正确做法是
     `python3 -c "d=open(f,'rb').read(); i=d.find(b'hsqs'); open(out,'wb').write(d[i:])"` 抽出 squashfs 段
     再 `unsquashfs4 -l/-d`。
5. **加外部镜像站的公钥**：放 `target/linux/<target>/base-files/etc/apk/keys/<名字>.pem`
   （**新增文件**，不会与 base-files 包撞路径）。放 target base-files 而不是顶层 `files/`：
   后者常被 `.gitignore` 忽略、不会被 git 跟踪。验证方法：把源索引 `curl` 到本地当 `file://` 源，
   带公钥能读、移走报 `UNTRUSTED signature` 即成。

**换掉架构级 feed 前先查同名包**（这一步能救你）：用 `apk adbdump <packages.adb>` 列出对方 feed 的包名，
确认它**不含 `kernel` / `kmod-*`**，也不含只会出现在自家 target 源里的 `base-files` / `libc` /
`fstools` / `dropbear`。否则跨源升级会把你自己的基础包换掉。
（实测 ImmortalWrt snapshot 的 base/packages/luci/routing/telephony 五个 feed 全部 0 kmod、
0 kernel，且不含 base-files/libc —— 与 OpenWrt 快照同源，混用安全。）

**代价说清楚**：源与固件绑死 —— 以后改内核补丁 / `config-<ver>` / kmod 选择，必须**整体重刷**才能更新源。
换来的是：没有任何哈希要对，也不受上游快照滚动影响。

### ⚠️ `ALL_KMODS` 的连带伤害：变体回落会编一个你根本没选中的软件包

开 `ALL_KMODS` 后第一次整编最常见的失败**不是 kmod 编不过**，而是某个 kmod 把它所在目录里的
**用户态大包**一起拖进来编，然后那个包编不过。典型报错只有一行、看不出原因：

```
ERROR: package/feeds/telephony/rtpengine failed to build (build variant: no-transcode)
```

`.config` 里 `# CONFIG_PACKAGE_rtpengine is not set`、`rtpengine-no-transcode` 也没选 —— 那它为什么编？
链条是这样的（每一环都能在树里查到证据，不是猜）：

1. `ALL_KMODS` 把 `kmod-ipt-rtpengine` 从 not set 打开成 `=m`。
2. 该 kmod 与用户态 `rtpengine` **同处一个源码目录**。`tmp/.packagedeps` 里：
   `package-$(CONFIG_PACKAGE_kmod-ipt-rtpengine) += feeds/telephony/rtpengine`
   ⇒ 只要目录里**任何一个**包被选中，整个目录就被拉进 `world`。
3. 该目录声明了变体，`scripts/package-metadata.pl:497-512` 生成（`tmp/.packagedeps`）：
   ```
   $(curdir)/feeds/telephony/rtpengine/variants += $(if $(CONFIG_PACKAGE_rtpengine-no-transcode),no-transcode)
   $(curdir)/feeds/telephony/rtpengine/variants += $(if $(CONFIG_PACKAGE_rtpengine),transcode)
   $(curdir)/feeds/telephony/rtpengine/default-variant := no-transcode
   ```
   两个变体的 config 都没选 ⇒ `variants` 展开为**空**。
4. `include/subdir.mk:61`：
   ```
   subdir_variants = $(filter-out *,$(if $(BUILD_VARIANT),$(BUILD_VARIANT),$(if $(strip $($(1)/variants)),$($(1)/variants),$(if $($(1)/default-variant),$($(1)/default-variant),__default))))
   ```
   variants 为空时**回落到 `default-variant`** ⇒ 目录被按 `no-transcode` 整份编。
   **结论：这个目录不管你有没有选它，都会被编一遍**（只有"目录里一个包都没选"才躲得过）。

**动手前先扫描，别边编边撞**（从 `tmp/.packagedeps` 反推，只读、秒出）：

```python
#!/usr/bin/env python3
# 找「目录被拉进 world，但解析出的变体对应的包没被选中」的陷阱
import re, collections
TOP = '/home/wen/515xg/openwrt'
cfg = {}
for line in open(TOP + '/.config', errors='ignore'):
    line = line.strip()
    m = re.match(r'(CONFIG_[A-Za-z0-9_-]+)=(.*)', line)          # 注意要含连字符！
    if m: cfg[m.group(1)] = m.group(2)
    else:
        m = re.match(r'# (CONFIG_[A-Za-z0-9_-]+) is not set', line)
        if m: cfg[m.group(1)] = 'n'
on = lambda s: cfg.get(s, 'n') in ('m', 'y')
dir_pkgs, dir_variants, dir_default = collections.defaultdict(list), collections.defaultdict(list), {}
for line in open(TOP + '/tmp/.packagedeps', errors='ignore'):
    line = line.rstrip('\n')
    if m := re.match(r'package-\$\(CONFIG_PACKAGE_([^)]+)\) \+= (\S+)$', line):
        dir_pkgs[m.group(2)].append('CONFIG_PACKAGE_' + m.group(1))
    elif m := re.match(r'\$\(curdir\)/(\S+)/variants \+= \$\(if \$\((CONFIG_[A-Za-z0-9_-]+)\),([^)]+)\)$', line):
        dir_variants[m.group(1)].append((m.group(2), m.group(3)))
    elif m := re.match(r'\$\(curdir\)/(\S+)/default-variant := (.+)$', line):
        dir_default[m.group(1)] = m.group(2)
for d, pkgs in dir_pkgs.items():
    if not any(on(s) for s in pkgs):
        continue                                                  # 目录没进 world
    if [v for s, v in dir_variants.get(d, []) if on(s)]:
        continue                                                  # 有选中的变体，正常
    if d in dir_default:
        print('%s  default-variant=%s  选中: %s' % (d, dir_default[d], ','.join(p for p in pkgs if on(p))))
```

**两个自己踩过的坑**：① 正则里 `CONFIG_[A-Za-z0-9_]+` 漏了**连字符**，`CONFIG_PACKAGE_kmod-foo` 会被整个丢掉，
结果一个都报不出来；② `.packagedeps` 里内层是 `$(if $(CONFIG_...),...)`，写正则别漏那个 `$(`，
否则变体列表全解析不出来、把所有带 `default-variant` 的正常目录（dnsmasq / busybox / hostapd…）全误报。

**修法**：把那个"携带者" kmod 显式关掉即可 —— `.config` 里加
`# CONFIG_PACKAGE_kmod-ipt-rtpengine is not set`（库里有 prompt，用户值优先于 `default m if ALL_KMODS`），
目录不再进 `world`，问题消失。**不要去改 feed 里的 `default-variant`** —— 那既动了上游文件，
又会去编你本来就不想要的那个用户态包。
心态上要接受：`ALL_KMODS` 的产物是"绝大多数 kmod"，不是"绝对全部"；为 1 个冷门 kmod 去改上游不划算。

### 默认 BBR

`CONFIG_PACKAGE_kmod-tcp-bbr=y` 就够了 —— OpenWrt 自带包（`package/kernel/linux/modules/netsupport.mk`）：
`KCONFIG:=CONFIG_TCP_CONG_BBR` + `AUTOLOAD:=$(call AutoProbe,tcp_bbr)`，并安装
`/etc/sysctl.d/12-tcp-bbr.conf`（内容 `net.ipv4.tcp_congestion_control=bbr`）；
`/etc/init.d/sysctl` 的 `start()` 会遍历 `/etc/sysctl.d/*.conf` 与 `/etc/sysctl.conf` ⇒ 开机即生效。

- **别去改 `CONFIG_DEFAULT_TCP_CONG`**：那是编译期**内建**默认，BBR 以模块形式提供时设不了；
- 想把默认队列也换成 `fq`，要额外 `kmod-sched`（它提供 `sch_fq`）+ `net.core.default_qdisc=fq`；
  内核 6.10+ 的 BBR 自带内部 pacing，不动队列也能跑（默认 fq_codel 还带 AQM）。
- 验证：`cat /proc/sys/net/ipv4/tcp_congestion_control`（应 `bbr`）与 `tcp_available_congestion_control`。

## ⚠️ 改了 LuCI 文件、刷完机却「看不到变化」：先查浏览器缓存

LuCI 的静态资源版本号是（模板里写死，`luci-base/ucode/template/header.ut`）：

```
<resource>/luci.js?v=<luci PKG_VERSION>-<mtime of /lib/apk/db/installed>
                pkgs_update_time = stat('/lib/apk/db/installed').mtime  (ucode/runtime.uc)
```

而 OpenWrt 是**可复现构建**：`SOURCE_DATE_EPOCH` 取**最后一次 git 提交的时间戳**，
`include/image-commands.mk` 用 `touch -hcd "@$(SOURCE_DATE_EPOCH)"` 把镜像里**所有文件**的 mtime
统一成这个固定值。⇒ **同一棵源码树反复重编，版本号完全不变**，浏览器一直复用缓存里的旧 JS（例：
覆盖版 `10_system.js` 永远加载不到）。**症状很坑：新板块/新字段不出现，且控制台不报错**
（跑的是旧代码）—— 别去怀疑 ACL 或包没进去。

- 先取证：`curl -s http://<dev>/cgi-bin/luci/ | grep -o 'luci.js?v=[^"]*'`（和上次比），
  以及确认 web 服务返回的**字节数/内容**与源文件一致（一致 ⇒ 后端没问题）；
  让用户 `Ctrl+Shift+R` 也能立刻判定。
- **立即破解（无需重编）**：设备上 `touch /lib/apk/db/installed` → 版本号变化 → 普通刷新即可见。
- **固化进固件**：加一个 uci-defaults（只在刚刷入的镜像里存在、成功执行后自删）：
  `[ -f /lib/apk/db/installed ] && touch /lib/apk/db/installed` ⇒ 每次刷机后自动失效一次缓存。
- 别去改 `CONFIG_REPRODUCIBLE_*`（牵动大范围重编，不值得）。

## 不用浏览器也能把 LuCI 的 ACL / 数据链验穿

root 无密码的 OpenWrt 可以直接建会话，并把 session **显式**传给 rpcd 的 `file` 方法
（这些方法的 policy 里就带 `session` 参数），这样能绕过
`rpc_file_access(sid=NULL) => true` 这个坑，做**真实** ACL 校验：

```sh
SID=$(ubus call session login '{"username":"root","password":""}' | jsonfilter -e '@.ubus_rpc_session')
ubus call file read "{\"path\":\"/sys/class/hwmon/hwmon0/temp1_input\",\"session\":\"$SID\"}"
ubus call file exec "{\"command\":\"/usr/sbin/<dev>-helper\",\"session\":\"$SID\"}"
ubus call file list "{\"path\":\"/www/luci-static/resources/view/status/include\",\"session\":\"$SID\"}"
ubus call session destroy "{\"ubus_rpc_session\":\"$SID\"}"
```

配合「把设备上的 JS 拉回来 + 打桩渲染」这套（见上节），就能在**不点开浏览器**的情况下
把「ACL 通过 → 数据正确 → 渲染出的行」整条链验完，比等截图快得多。

## 镜像：U-Boot + UBI + FIT 启动的设备

```make
UBOOTENV_IN_UBI := 1
KERNEL_IN_UBI := 1
KERNEL := kernel-bin | gzip
IMAGES := sysupgrade.itb
IMAGE/sysupgrade.itb := append-kernel | fit gzip $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb external-static-with-rootfs | append-metadata
DEVICE_PACKAGES += fitblk
```
DTS 里必须有 `chosen { rootdisk = <&ubi_volume_fit>; }`，`fit.sh` 靠它解析出 `CI_KERNPART`。

**刷写机理（务必核对 `lib/upgrade/nand.sh` 再动设备）**：
`nand_upgrade_fit` → `nand_upgrade_prepare_ubi` 只 `ubirmvol`/`ubimkvol` **`fit` 与 `rootfs_data` 两个卷**，
其余卷（u-boot/ATF 所在的 `fip`、`factory`、`ubootenv`）**不动**。
`nand_attach_ubi` 在 UBI 已挂载时直接复用，**不会** `ubiformat` 全片。
只有 `.ubi` 容器才会走 `ubiformat`（那种才危险）。

`sysupgrade` 会被 `fit_check_image` 拦吗？在设备上实测：
```sh
dd if=/dev/ubiblock0_<fit卷号> of=/tmp/cur.itb bs=64k; fit_check_sign -f /tmp/cur.itb; echo rc=$?
```
只要原固件镜像也返回 0（只校验 hash，不要求签名），我们的未签名镜像同样能过。
被拒时的备用路径：`ubiupdatevol /dev/ubi<X>_<fit卷号> -s $(stat -c%s img.itb) img.itb`。

## ⚠️ 刷机前必做的拓扑检查（最容易翻车的一步）

**先确认这台设备在网络上扮演什么角色**，否则刷机会切断你自己的连接、还可能切断用户全家网络：

```sh
ip route                                   # 默认路由是不是就走这台设备？
iw dev <wlan> link 2>/dev/null             # 本机 WiFi 关联的 AP 是不是它？
ssh root@<dev> 'cat /tmp/dhcp.leases'      # 本机的租约在不在它的 DHCP 列表里？
ssh root@<dev> 'ip -br link; ip route'     # 它是 AP/网关/PPPoE 出口吗？
```
如果它既是网关又是 AP，则新镜像一旦不带无线驱动、或改了网段，**远程必然失联**。此时：
1. 先准备**独立的有线兜底**：设备某个 LAN 口 ↔ 本机/宿主机网口，并确认能配静态 IP（需要 root）。
2. 或让新镜像**预置**原网段 + 原无线 SSID/密码（uci-defaults），让它刷完自动回到原网络。
3. 确认有 **串口 / U-Boot 命令行 / TFTP** 恢复途径。
4. 明确告知用户"只写 `fit`+`rootfs_data`，不动 `fip`/`factory`"，并说明失联后的恢复步骤。

刷机前把现场信息存档：`/etc/config/network`、`/etc/config/wireless`、`/etc/config/pon`、
`ip -br link`、`cat /proc/mtd`、`ubi` 卷表、`sys/firmware/fdt`（反编译成 dts 作对照）。

## 停止/重跑编译的正确姿势

**永远不要用 `pkill -f "make -j8"` 这类模式匹配去停编译**：
- 该模式会匹配到你自己那条 ssh 命令行 → 自杀；
- 会把编译中的子任务打成孤儿 → 孤儿进程与重启后的新编译**并发写同一个 build_dir**，污染 host 工具
  （典型症状：日志出现两个不同的 `--jobserver-auth=fifo:/tmp/GMfifo*`）。

正确做法：取顶层 make 的 **pgid，整组 kill**：
```sh
PG=$(ssh <host> "ps -o pgid= -p \$(pgrep -f 'make -j8' | head -1)" | tr -d ' ')
ssh <host> "kill -9 -$PG"
```
若已发生并发污染，必须删掉被污染的产物再重跑：
`rm -rf build_dir/host/<tool>-<ver> build_dir/host/stamp/.<tool>.* staging_dir/host/bin/<tool>*`

长时间编译请这样起（独立于会话存活 + 日志可查 + 结束有标记）：
```sh
ssh -o ServerAliveInterval=60 <host> 'cd <src> && setsid bash -c \
  "make -j8 > /home/x/build.log 2>&1; echo BUILD_EXIT=\$? >> /home/x/build.log" </dev/null & wait'
```
检查：`tail -3 build.log`；`grep -cE "ERROR:|error:" build.log`（应为 0）；`grep BUILD_EXIT build.log`。

## 验收清单

- [ ] `make target/linux/prepare` 零 reject
- [ ] `grep` 关键驱动代码已进内核树（PON 的 `airoha,pon-data-path`、pinctrl 新增 group、spinand 新器件…）
- [ ] DTS 单独立预检通过（不必等整编）：
      `cd build_dir/.../linux-<ver> && cpp -nostdinc -I include -I arch/arm64/boot/dts -I <dts目录> -undef -x assembler-with-cpp -D__DTS__ -o /tmp/x.dts <目标>.dts && dtc -I dts -O dtb -o /tmp/x.dtb /tmp/x.dts`
- [ ] 产物 manifest 里含预期包
- [ ] 刷后：`board_name`、`/proc/mtd`、`ip -br link`、`dmesg` 驱动探测、LED/按键、WAN 拨号

## 把移植成果交付出去：让 clone 下来就能编出同一个镜像

移植做完、设备也跑起来了，最后一关是把成果变成**别人 clone 下来直接能编**的树。
上游 `.gitignore` 会挡住这个目标，必须动手改。

### 上游默认忽略、但移植成果里必须纳入版本管理的三项

| 路径 | 上游为什么忽略 | 为什么必须提交 |
|---|---|---|
| `.config` | 每人自己 menuconfig | 没有它就编不出同一个镜像（device profile + 包选择） |
| `feeds.conf` | 同上 | 缺了就是缺厂商 feed，编不过 |
| 顶层 `files/` | 用户的本地叠加目录 | **apk 下唯一能覆盖「别的包已有文件」的位置**（见上文 LuCI 概览页那节），不提交等于把改动丢了 |

`.gitignore` 改法（第 3 条有坑）：

```gitignore
# 直接删掉这两行
# /.config
# /feeds.conf

# /files 不能整行删（否则 files/ 下任何杂物都会被提交），要写成：
/files/*
!/files/www/
```

> **坑**：negation 必须作用在**目录本身**（`!/files/www/`）。只 negate 里面的文件
> （`!/files/www/**`）无效 —— git 不会进入一个已被排除的目录去找例外。

改完必须验证，三层都要查：

```bash
git check-ignore -v .config feeds.conf files/www/…/10_system.js   # 期望 rc=1（未忽略）
git check-ignore -v dl build_dir staging_dir bin tmp feeds \
                      .config.old private-key.pem public-key.pem   # 期望仍被忽略
git status --porcelain | wc -l                                    # 数目应与改动清单吻合
git diff --cached --name-only | grep -E '^(bin|dl|build_dir|staging_dir|tmp|feeds)/'  # 期望空
```

### 提交前必查：敏感信息

站点覆盖脚本（`uci-defaults/99-*-site`）里常带**明文 PPPoE 账号密码 / WiFi psk2 密码**，
这是最容易漏的一类。用真实值反查整棵树：

```bash
grep -rn "<账号片段>\|<密码>\|<ssid>\|<手机号>" . \
     --exclude-dir={.git,build_dir,staging_dir,dl,bin,tmp,feeds}
```

- 空输出 = 干净。`.config` 里出现 `PASSWORD`/`KEY` 基本都是无害的内核/busybox 选项，
  但值得肉眼扫一遍。
- 被停用的站点脚本（改名为 `*.removed` 留档）如果不在 git 仓库里，**不会被推送**，
  但磁盘上仍是明文 —— 提醒用户脱敏或删除，不要只靠「已改名」放心。

### fork 的远端布局（保留 rebase 能力）

```bash
git remote add fork git@github.com:<user>/<repo>.git   # origin 留给上游，只拉不推
git push -u fork main
```

推送前确认体积不会被打回：`git verify-pack -v .git/objects/pack/*.idx | grep ' blob ' |
sort -k3 -n | tail` 看历史最大 blob（GitHub 单文件上限 100 MB；`/home/wen/515xg` 那份
OpenWrt 全史 pack 约 324 MiB、最大 blob 6.4 MB，正常）。

### 交付文档该写什么

移植树的 README 不要只写"这是什么"，要写成**能独立复现**的一份：基线 commit + 镜像
sha256 + feeds 锁定 commit（产物目录里的 `feeds.buildinfo` 直接可用）→ 编译步骤 →
刷机步骤（含"哪些分区绝对不能动"）→ 出厂默认值表 → 关键实现说明（为什么这么改）→
**「从厂商树重新同步时必须重新应用」清单**（手改过的补丁、新增文件、顶层 `files/`、
`.config`/`feeds.conf`）→ 免责声明。

## 相关技能

- 设备探测 / 远程 sysupgrade / 刷后体检 → `openwrt-device-probe`
- 刷完起不来、要离线比对两版固件找根因 → `openwrt-brick-offline-triage`
- 要把厂商 `.ko` 移植到主线内核 → `vendor-ko-mainline-port`

---

## 附录：PON（光猫/ONU）设备的"PON 不工作"排查要点

Airoha AN7581/AN7583 这一系的 PON 设备（`airoha-xpon` + `airoha-pon-frontend` + EN7572 光前端），
**"PON 不工作"最常见的根因不是驱动坏，而是线路根本没被启动**。

### 核心机制（先记住这一条）

**PON 线路的生命周期 = `ponX` 这个 netdev 是否被打开。**

`airoha_eth.c` 的 gdm 打开路径里：

```c
if (dev->flags & AIROHA_PRIV_F_PON) {
        /* Start the PON line asynchronously after QDMA and NAPI are ready. */
        err = dev->pon_link_ops->start(dev->pon_link_priv);
```
关闭时对应 `ops->stop`。

所以：**必须有网络接口绑定 `ponX`（netifd 会 `ip link set ponX up`），PON 线路才会启动**。
如果设备的 `/etc/config/network` 里没有任何接口用 `ponX`（例如 WAN 走的是别的口 PPPoE），
那么线路会永远停在 `lifecycle: stopped` / `onu_state: O1`，看起来"完全没反应"。
厂商 init 脚本 `airoha-pon-daemons` 的注释也写了：
`# 线路由 netifd 打开对应 ponX 时启动。`

### 判定顺序（全部只读，安全）

```sh
# 1) 驱动/固件/用户态是否就绪
lsmod | grep -E "xpon|en7572|pon_frontend"
dmesg | grep -iE "xpon|en7572"        # 期望看到 MD32 initialized / LED triggers registered / bound to pon0
ps w | grep airoha-pond
ls /sys/class/leds/ | grep -E "wan"   # 触发器应为 pon0-registration / pon0-los / pon0-online

# 2) 光路是否正常（LOS / 收光功率）
ponctl --device pon0 status           # 看 [frontend] rx_power_dbm：-40 附近=没光；-8~-28=有光
cat /sys/class/leds/red:wan/brightness   # 1 = LOS 亮 = 无光；0 = 有光

# 3) 线路是否被启动（这就是"不工作"的关键判据）
cat /sys/kernel/debug/airoha-xpon-pon0/line          # lifecycle: stopped|running|error
cat /sys/kernel/debug/airoha-xpon-pon0/registration  # onu_state: O1..O5, active_serial_number
ponctl --device pon0 mode show                       # configured=xgpon active=none → 未启动
ponctl --device pon0 identity show                   # active_serial_number: none → 未锁存
uci show network | grep -i pon0                      # ★ 没有任何接口用 pon0 → 就是根因
```
`lifecycle: stopped` + `last_start_error: 0` ⇒ **从未尝试启动**（不是启动失败）；
`lifecycle: error` + `last_start_error != 0` ⇒ 真启动失败，看 dmesg。

### 让它工作

```sh
# 方式 A（持久）：给 pon0 建一个接口，netifd 打开它即启动线路
uci set network.wan_pon=interface
uci set network.wan_pon.device='pon0'
uci set network.wan_pon.proto='dhcp'          # 若运营商是 PPPoE over PON 则改 pppoe + 账号
uci commit network && /etc/init.d/network reload

# 方式 B（临时验证）：直接拉起网卡，然后盯状态机
ip link set pon0 up
while :; do cat /sys/kernel/debug/airoha-xpon-pon0/registration; sleep 2; done
# 期望 onu_state 从 O1 往 O2-1/O3/O4/O5 推进，active_serial_number 不再是 none
```
**注意**：拉起 pon0 会 arm 上行发射，开始与 OLT 测距。这是标准 XG-PON 发现流程
（OLT 用 quiet window 安排未注册 ONU 上报），对同 PON 其他用户影响很小，
但仍属于"对运营商网络发射"，动手前跟用户确认。

### 常见后续问题

- **OLT 不认这台 ONU**（onu_state 在 O3/O4 反复、ploamd_rejected 增长）→ 运营商侧白名单/认证问题：
  SN 白名单（需运营商登记这台设备的 SN）或 LOID+密码。国内运营商还常见
  `omci.loid` / `loid_password` 配置。
- **身份来源**：`serial_number` 通常来自板级 NVMEM（DTS 里 `nvmem-cells = <&pon_serial>`，
  偏移在 `factory` 卷内），所以 `option serial_number ''` 反而表示"用 NVMEM 的"，不是没配。
- **数据面**：注册成功后还需 `ponctl data-path` 把 GEM/队列映射到 `airoha,pon-data-path` 指向的
  gdm 口；`data-path configured=0 count=0` 表示尚未配置。
- 对比排查法：**把"正常"的那台设备的 `ponctl status` / debugfs 读数一起抓下来对比**，
  往往一眼就能看出差异是"没启动"还是"启动失败"还是"OLT 不认"。
