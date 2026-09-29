---
name: luci-block-overlay-customize
description: 改造 LuCI 已有页面（比如把「状态→总览」里的某个块改成卡片版、往页面加温度/连接数），两条路都覆盖：(A) 源码树顶层 files/ 覆盖层，(C) 做成独立 apk 让用户自己 apk add（新文件名顶上 + 包脚本改名停用默认块）。并配齐 rpcd ACL，做到不刷机就能验证。适用于「改 LuCI 页面但不想动 feed 包」「luci-mod-status 的文件要换掉」「apk 报两个包拥有同一路径」「把界面改造做成 apk」「主页要还原成源码默认」「include 会不会自动加载新文件」「LuCI 页面读 /sys 或 /proc 提示 Access denied」「file.read 返回被截断」「覆盖层的文件在镜像里又变成压缩单行了」「卡片并排但底边参差不齐 / 短的那张不肯长高 / 左右两栏高度不一致」，以及需要给 LuCI 页面写免浏览器的自检/静态预览时使用。
agent_created: true
---

# 改造 LuCI 页面：覆盖层（files/）与独立 apk 两条路

## 什么时候用

* 想改 LuCI 某个**已有**页面的行为或排版，但那个文件的路径**属于某个已装包**。
* 往 LuCI 页面里加自定义数据源（`/sys`、`/proc`、`debugfs`、自带小工具输出）。
* 需要在不刷机的前提下，先证明「这段 JS 真的能跑出预期的数据」。

不适用：新增一个全新的 LuCI 页面/菜单（那应该正常建 `luci-app-xxx` 包，见
`openwrt-luci-menu-missing`）。

---

## 0. 先定位：这个文件属于哪个包

```bash
# 源码树里，feed 的原始文件长这样
feeds/luci/modules/<pkg>/htdocs/luci-static/resources/<path>

# 设备上确认归属（apk 3）
apk info -W /www/luci-static/resources/view/status/include/10_system.js
# opkg 设备：opkg search '*10_system.js'  /  grep -rl <path> /usr/lib/opkg/info/*.list
```

**关键前提**：apk **不允许两个包拥有同一个文件**。所以
「另建一个小包去装**同名**文件」这条路是**走不通的**，会直接装包冲突。

能走的路有三条：

| 方案 | 优点 | 缺点 |
|---|---|---|
| **A. 顶层 `files/` 覆盖层** | 不动 feed，`feeds update` 冲不掉 | `files/` 常被 `.gitignore` 忽略；改动不在 git 里，必须额外归档；**改动跟着固件走，用户没法"要就要不要就不要"** |
| B. 改 `feeds/luci/...` 原文件 + 打补丁固化 | 进 git、可复现 | 每次 `feeds update` 要重放补丁；改动散在 feed 里 |
| **C. 独立 apk（用新文件名顶上）** | 改动与固件解耦，用户自己 `apk add` / `apk del`；镜像保持源码默认 | 要写包（§0.5）；得找到"和默认块并存/顶掉"的正确姿势 |

用户要求「主页保持源码默认、改造我自己装」时只能走 **C**。§1–§11 的覆盖层做法仍然有效，
但如果是 C，先用 §0.5 把机制吃透。

---

## 0.5 方案 C：把改造做成独立 apk（2026-09-28 实测可行）

### 0.5.1 机制根基：LuCI 的 include 是**运行时扫目录**，不是硬编码数组

`feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/index.js`：

```js
fs.list('/www' + L.resource('view/status/include'))   // → 滤 /\.js$/ → sort()
  → L.require('view.status.include.<名>')             // 逐个渲染成 cbi-section
```

推论（这就是全部可行性所在）：

* **起一个新文件名**（如 `15_hw.js`）就会被自动加载，**不用碰任何别人的文件**
  ⇒ 撞路径问题自然消失，包也不必声明 `10_system.js`。
* 顺序由 `sort()` 决定，所以文件名前缀（`10_` / `15_`）就是**显示顺序**。
* 每个 include 渲染成一个带标题 + 「显示/隐藏」按钮的 `cbi-section`，
  且 `includes[i].id = title`。**必须换掉 `title`**：LuCI 拿 `id`（= title）
  当 localStorage 里"这块被隐藏没有"的 key，**沿用旧 title 会继承旧的隐藏状态**
  （用户以前把默认块点过「隐藏」的话，新块一上来就是隐藏的，看起来像"没生效"）。

### 0.5.2 怎么"顶掉"默认那块：**改名**，不是覆盖

不要走「包里藏一份 `10_system.js`、postinst 覆盖上去」。理由：
`luci-mod-status` 一旦重装/升级，覆盖就被冲掉，**卡片代码连文件一起没了**。

用包脚本把默认文件**改名成不以 `.js` 结尾**（目录扫描按 `\.js$` 过滤，改名即可让它不被加载）：

```make
define Package/<pkg>/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
STOCK=/www/luci-static/resources/view/status/include/10_system.js
if [ -f "$$STOCK" ]; then
	cp -p "$$STOCK" "$$STOCK.disabled" && rm -f "$$STOCK"
fi
exit 0
endef

define Package/<pkg>/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
STOCK=/www/luci-static/resources/view/status/include/10_system.js
if [ -f "$$STOCK.disabled" ]; then
	cp -p "$$STOCK.disabled" "$$STOCK" && rm -f "$$STOCK.disabled"
fi
exit 0
endef
```

要点：

* **`[ -n "$${IPKG_INSTROOT}" ] && exit 0`** 这个 guard 必须有 —— 构建期 rootfs 装配也会跑
  post-install（`include/rootfs.mk`），不 guard 会在构建机上乱改文件；而且构建期脚本返回非 0
  会让 **make 直接失败**。
* 构建系统会由同一个 `postinst` 生成 **`post-install` 与 `post-upgrade` 两份**（`adbdump` 里都能看到）,
  `postrm` → `post-deinstall`。apk 装新版本走的是 `post-upgrade`，所以两份都得对。
* 失败模式温和：`.disabled` 被谁删了，最坏只是**多出一个默认块**，点一次「隐藏」即可。
  比"覆盖"方案（最坏卡片全丢）好得多。
* 卸载后要 `reboot` 一次，否则 rpcd 的 ACL 缓存里还留着旧条目。

### 0.5.3 包的写法（`PKGARCH:=all` ⇒ `arch=noarch`）

纯文件 + 脚本的包，三个必写项：

```make
PKGARCH:=all                      # ⇒ arch:noarch，任何架构都能装
DEPENDS:=+luci-mod-status +rpcd +rpcd-mod-file

# ⚠️ 没有源码也必须显式写空 Build/Compile，否则默认规则去
#    make -C $(PKG_BUILD_DIR)，报 "No targets specified and no makefile found"
define Build/Compile
endef
```

`.config` 里写 `CONFIG_PACKAGE_<pkg>=m` ⇒ **只编出 apk，不装进镜像**（正是要的效果）。
单包编译：`make package/<dir>/<pkg>/{clean,compile} V=s`；产物落
`bin/packages/<arch>/<feed>/<pkg>-<ver>.apk`。

⚠️ **那两个动词必须成对给，不能只 `compile`**：编译 stamp 只把 `Makefile` 当依赖，
`files/*` 改了**不会**触发重编 ⇒ 只跑 `compile` 会"成功"地打出**装着旧文件的新 apk**
（2026-09-28 实测：改完卡片只 `compile`，产物里还是旧 `15_hw.js`；加 `clean` 才刷新）。
这类包没有源码，编一次也就几秒，**永远 `{clean,compile}` 一起写**。

### 0.5.4 装到设备上之后的两条硬规矩

* **必须重新登录 LuCI**。rpcd 只在**每次登录**时 glob 读 ACL（`rpcd/session.c`），
  新装的 ACL 对已登录会话不生效 ⇒ 不重登会报 `Access denied`，看着像包装坏了。
* **别加 `--no-scripts`** —— 停用默认块靠的就是包脚本。
  `apk add --no-cache /tmp/xxx.apk` 即可；**不需要** `--allow-untrusted`
  （用同一棵源码树编的包，签名用的就是设备信任的那把 keys）。
* JS 只是新增一个文件（新 URL），刷新浏览器即可，**不必**清 `/tmp/luci-*`。
* ⚠️ **改了内容就动版本号**（`PKG_RELEASE` +1）。版本号不变而内容变了，设备上又装着
  同版本的旧包时，`apk add <本地 apk>` 可能判定"无变更"而**不覆盖** ⇒ 用户以为改动
  没生效，其实是他手里是旧的。要么 bump release 让 `apk add` 走正常升级，
  要么明确告诉用户用强制重装 / 先 `apk del` 再装。**这一条最容易忘，因为本地一切正常。**

### 0.5.5 验证 apk 内容：`apk adbdump` 的路径是**相对父目录**的

自己写门禁去 grep 文件清单时最容易踩：`adbdump` 把文件**嵌在父目录的 `files:` 下面**：

```
paths: # 15 items
  - name: usr/sbin
    acl:
      mode: 0755
    files: # 1 items
      - name: 515xg-connstat
        acl:
          mode: 0755
```

所以 `grep '^  - name: usr/sbin/515xg-connstat$'` **永远匹配不到**。
要先按父目录前缀拼回全路径，且**顺序必须是先匹配 6 空格（文件条目）再匹配 2 空格（目录条目）**：

```sh
awk '/^      - name: / { sub(/^      - name: /,""); print dir "/" $0; next }
     /^  - name: /     { sub(/^  - name: /,""); dir=$0 }' dump.txt | sort
```

取某个文件的权限位同理（要先定位到文件条目、再取它下面 10 空格缩进的 `mode:`）。
另一类假 FAIL：脚本原文里写的是 `"$STOCK.disabled"`，而门禁 grep 字面量
`10_system.js.disabled` —— **grep `\.disabled` 就够了**。

### 0.5.6 包脚本必须**在沙盒里真跑一遍**（文本 grep 不算验证）

`grep` 只能证明"脚本里**写了**改名逻辑"，证明不了"这段逻辑**跑起来**真能把默认块顶掉、
卸载后真能还回来"。条件写反的话，镜像门禁和 apk 门禁会**全绿**，
但用户装上以后默认块还在（两个块并存）、或者卸载后主页少一块。

```sh
# 1) 从 adbdump 里抠出某个 slot 的脚本文本（剥掉 4 空格缩进）
awk -v slot=post-install '
  $0 == "  " slot ": |" { f=1; next }
  f && /^  [a-z][a-z-]*: / { f=0 }
  f { sub(/^    /, ""); print }' dump.txt
# 2) 剥掉 OpenWrt 生成的通用前导（沙盒里没有，会提前 exit 0 让测试假过）
grep -vE 'IPKG_NO_SCRIPT|lib/functions\.sh|export root=|export pkgname=|add_group_and_user|default_postinst|default_prerm|export PKG_UPGRADE'
# 3) 只把写死的目标路径 sed 到沙盒目录（逻辑一字不改），然后按四拍跑：
#      装 → 再装一遍（幂等）→ 卸 → 空手卸（不该凭空造文件）
```

四拍的期望：装完 `10_system.js` 不在、`.disabled` 在且内容逐字节等于原文件；
连装两遍仍幂等；卸完原文件回来且内容一致；`.disabled` 不存在时执行卸载**不产生任何文件**。

**务必做反例自测**：把脚本故意改成"只备份不删原文件"和"条件写反"，这个门禁必须报 FAIL。
没失败过的门禁等于没有门禁。

---

## 1. 顶层 `files/` 的加载顺序 —— 覆盖层方案（A）成立的全部依据

`files/` 是 OpenWrt 的「自定义文件覆盖层」（`CONFIG_TARGET_ROOTFS_FILES` /
`include/rootfs.mk`），它在 **`make package/install` 完成之后、打包 rootfs 之前**整体拷进 rootfs。

由此**白拿**两个好处：

1. **覆盖生效**：包的文件先落，覆盖层后落 → 覆盖层赢。
2. **不被压缩**：luci feed 的 `LUCI_MINIFY_JS=1`（`feeds/luci/luci.mk`，走 `jsmin`）
   是在**装包之前**跑的 —— 也就是说 stock 文件在装包那一刻就已经是压缩好了的单行，
   覆盖层是之后落的，**不经过 jsmin**。

> **第 2 点是验证覆盖层有没有生效的最好判据**，也是这个方案唯一的
> 「不成功就白干」风险点：
>
> ```bash
> # 刷完后：这个文件应该是多行（未压缩），它的兄弟文件应该是单行（已压缩）
> wc -l /www/luci-static/resources/view/status/include/*.js
> ```
>
> 如果它也变成单行了 ⇒ 覆盖层落在 jsmin 之前了（或没赢），
> **必须改回方案 B**：改 `feeds/luci/modules/<pkg>/...` 原文件 + 把改动固化成正式补丁
> （固化流程见 `openwrt-brick-offline-triage`）。

---

## 2. rpcd ACL：两个必踩的坑

LuCI 前端拿数据走的是 rpcd 的 **`file`** ubus 对象
（`read`/`write`/`list`/`stat`/`lstat`/`md5`/`remove`/`exec`），
由 `fs.js` 的 `fs.trimmed()` / `fs.read()` / `fs.exec()` 包装。

> ⚠️ **`fs` 这个 ubus 对象在新版 rpcd 里已经不存在了**。别照抄老教程里的
> `ubus call fs ...` / ACL 里写 `"fs": [...]`，会 `Access denied` / `Not found`。
> 一律用 `file`。

ACL 文件放在 `files/usr/share/rpcd/acl.d/<name>.json`，形如：

```json
{
	"luci-status-hardware": {
		"description": "Grant read access to the board sensors ...",
		"read": {
			"file": {
				"/sys/class/thermal/thermal_zone*/temp": [ "read" ],
				"/sys/devices/virtual/thermal/thermal_zone*/temp": [ "read" ],
				"/sys/class/hwmon/hwmon*/name": [ "read" ],
				"/sys/class/hwmon/hwmon*/temp1_input": [ "read" ],
				"/sys/devices/*/ieee80211/phy*/hwmon*/name": [ "read" ],
				"/sys/devices/*/ieee80211/phy*/hwmon*/temp1_input": [ "read" ],
				"/usr/sbin/myhelper": [ "exec" ]
			},
			"ubus": { "file": [ "read", "exec" ] }
		}
	}
}
```

### 坑 1：`/sys/class/...` 和 `/sys/devices/...` **两条都要写**

看着像冗余，其实两条都必需。rpcd `file.c` 里：

* `rpc_check_path` 宏对 read / write / list / stat / remove **一律传 `resolve_symlinks = true`**；
* `rpc_check_symlink_access()` 会把路径 `realpath()` 解开，
  **再对解开后的真实路径重新跑一遍 ACL 检查**。

`/sys/class/thermal/thermal_zone0/temp` 的真实路径是
`/sys/devices/virtual/thermal/thermal_zone0/temp`；hwmon 的真实路径在
`/sys/devices/platform/.../ieee80211/phy0/hwmon0/`。
**只写一种，另一半会 `Access denied`。**

排查手法：设备上 `readlink -f <路径>`（busybox 没有 `realpath`），拿真实路径去补 ACL。

### 坑 2：rpcd 的 `fnmatch` **没有** `FNM_PATHNAME`

`uh_foreach_matching_acl` 用的是不带 `FNM_PATHNAME` 的 `fnmatch()`，
所以 `*` **能跨 `/`**：

* `hwmon*/name` 一条就覆盖了 `hwmon0/name`、`hwmon1/name`……
* 但反过来说，`/sys/class/hwmon/*` 也会覆盖 `/sys/class/hwmon/hwmon0/temp1_input`
  —— 注意别把范围开得比你想的大。

### 改完 ACL 要重启 rpcd 才生效

```bash
/etc/init.d/rpcd restart      # 或 ubus call session reload / service rpcd reload
```

---

## 3. `file.read` 对伪文件硬上限 4096 字节 —— 大文件必须走 `exec`

**硬结论**：`st_size == 0` 的伪文件（`/proc/*`、多数 `/sys/*`、debugfs）里，
`file.read` **最多只回 4096 字节**。

判据（自己复现一遍，别信我）：

```bash
# /proc/kallsyms 实际 1,698,880 B
ubus call file read '{"path":"/proc/kallsyms"}' | wc -c
# -> 4154 左右（4096 + JSON 包装 + 一个换行余量）
```

而 `/proc/net/nf_conntrack` 在**只有 11 条记录**时就已经 **3,993 B** 了。
所以只要数据量可能超过 4 KB，**就必须自己写一个小 helper + `file.exec`**：

```bash
# files/usr/sbin/myhelper  (chmod 0755)
#!/bin/sh
awk '{ ... }' /proc/net/nf_conntrack
# 输出 key=value 形式，前端 fs.exec() 后逐行解析
```

前端侧：

```js
return fs.exec(HELPER).then(function (res) {
	/* res = { code, stdout } —— code 非 0 也要走降级分支，别直接假设成功 */
});
```

ACL 里记的是 `"/usr/sbin/myhelper": [ "exec" ]` +
`"ubus": { "file": [ "read", "exec" ] }`。

> 顺带省一笔：**能合并的读取就合并**。6~8 次 `file.read` 合成 1 次 `exec`
> 能显著压低每 tick 的 rpcd 往返，代价只是 helper 变复杂。

---

## 3.5 新增一个数据源时：优先搭**已有的 helper**，别急着加 ACL

排序（成本从低到高）：

| 方案 | 代价 | 什么时候用 |
|---|---|---|
| ① 从**已经在读**的东西里解析 | 0 次新往返、0 新 ACL | 值就藏在已有的字符串里（典型：`ubus call luci getCPUInfo` 返回 `ARMv8 … x 4 (900MHz, 80.7°C)` —— 实时主频与温度都在里面，正则抠出来即可） |
| ② 塞进**已有的 `file.exec` helper** | 0 新 ACL、0 新往返（合并进同一次 exec） | helper 以 **root** 身份跑，它自己能读任何 sysfs/debugfs，**不用给 sysfs 加 ACL** |
| ③ 新增 `file.read` 路径 | 要加 ACL，且要写 `class` + `devices` **两条**（§2 坑 1），realpath 变一次就白名单落空 | 只在真的没法合并时用 |

②的做法（本项目实测）：

```sh
# 已有的 helper 里顺手多输出两行，绝对计数由前端差分
PON_IF=pon0
PON_STAT=/sys/class/net/$PON_IF/statistics
if [ -r "$PON_STAT/rx_bytes" ]; then
	echo "pon_rx_bytes=$(cat "$PON_STAT/rx_bytes" 2>/dev/null)"
	echo "pon_tx_bytes=$(cat "$PON_STAT/tx_bytes" 2>/dev/null)"
fi
```

**注意 ①/② 都改变不了 lua ACL**，所以刷完机不用碰 `/usr/share/rpcd/acl.d/`。

### 差分型指标（速率 / 占用率）的三个必备动作

1. **计数取绝对量，差分放在 JS 里**（helper 无状态、可随意调）。
   速率 = `(Δbytes × 8) / 1048576 / Δt`（`Mi` = 1024×1024，所以除以 `1048576`）。
2. **计数器回绕/设备重启要挡掉**：`if (to < from) return null;`，否则会画出一个天文数字的尖峰。
3. **首屏没有前一拍**：和 CPU 一样**隔 500 ms 补采一次**，首屏就有数，而不是空等一整个
   `pollinterval`。代价只是**打开页面时**多一次 exec（稳定态仍然一次）。
   如果两条指标共用同一次 exec，别为了补采把 helper 跑两遍 —— 让 `read()` 内的多个消费者
   **共用同一个 `readRaw()` promise**。

### 假时钟：差分型指标的断言必须用它

`Date.now()` 真实差分会让断言**随跑脚本那台机器的快慢抖动**（同一个数值在不同机器上
算出 `3.10` / `3.05` / `2.98`）。在 `mock-render.js` / `selftest.js` 里：

```js
let fakeNow = Date.now();
const real = ...;              // 先把真实时间取出来给页面用
Date.now = () => fakeNow;      // 再装假时钟
// 假 helper 每被调用一次：fakeNow += 500; 计数 += 对应 500 ms 的量
```

这样「分子增量 / 分母间隔」的比值恒定，断言可以写死成 `3.10` / `65.11`。
（只要每次调用推进的时钟与计数**成同一比例**，调用顺序怎么交错都不影响结果。）

### 按颜色断言时，光看颜色**一定不够**——还要看文本，而且常常要看**父节点**

主题里的 `--success-color-high` 不只用在"好消息"上 —— 温度色档的**低温档**也用它。
所以「断言卸载数值是绿色」不能只找 `success-color-high` 的节点。

**第一版写法（只加文本过滤）**，适用于"标签和数值在同一个节点"的场景：

```js
findNodes(tree, n => /success-color-high/.test(n.attrs.style || '')
                 && text(n).join('').includes('硬件卸载'))
```

**但这个写法有个隐藏前提**：绿色节点自己得含有那个中文标签。一旦需求变成
「**标签保持灰、只有数值绿**」（真实案例：用户要求「那几个字颜色不用改，只改后面的数值」），
节点会拆成

```html
<span style="color: var(--text-color-low)">硬件卸载
  <span style="color: var(--success-color-high); font-weight: 600">28</span>
</span>
```

⇒ 上面那个过滤条件**命中 0 个**，断言全红。正确写法是**按"绿色 + 自身文字是纯数字"取节点，
再回头检查它的父节点**：

```js
function withParents(node, parent, out = []) {          // 节点树没有父指针，遍历时自己带
	if (node == null || typeof node !== 'object' || !node.attrs) return out;
	out.push({ node, parent });
	for (const c of (node.children || [])) withParents(c, node, out);
	return out;
}
const greenNums = withParents(tree, null).filter(({ node }) =>
	/success-color-high/.test(node.attrs.style || '') &&
	/^[0-9]+$/.test(text(node).join('')));              // ← 纯数字这一条顺手把温度色档带排除掉
const captions = greenNums.map(({ parent }) => (parent && parent.attrs.style) || '');
assert(greenNums.length === 2 &&
	greenNums.every(({ node, parent }) => parent &&
		text(parent).join('').includes('硬件卸载') &&
		!text(node).join('').includes('硬件卸载')) &&
	captions.every(s => /text-color-low/.test(s) && !/success-color-high/.test(s)));  // 标签没被染绿
```

要点：**(a)** 用「纯数字」当过滤器，比用标签文字更稳，还能免掉"别处也用同一个色"的误判；
**(b)**「标签没被染绿」必须**显式断言父节点的样式**，否则把标签也染绿了测试照样过；
**(c)** 遍历带回 parent 是通用手法，凡是要断言"某节点在某个容器里"都用它。

### 增删一路数据源后，`Promise.all` 的**下标会全体左移**

按 `r[0] / r[1] / …` 取值时，中间删一项就会静默错位（`cpuusage` 拿到 `npuAttached`）。
删完立刻数一遍，或干脆改用对象包装；自检脚本里对该字段的断言就是防这个的。

---

## 4. `String.prototype.format()` —— CSS 里绝对不能用

LuCI 的 `String.prototype.format`（定义在 luci-base 的 `cbi.js`）有个陷阱：

> 它**先看字符串里第一个 `%` 是不是一个合法的转换符**；不是的话**整串原样返回**，
> 后面的占位符**全部静默失效**。

所以只要字符串里有个字面量的 `%`（典型：`style="height: 100%"`、
`"width: 50%"`），**后面所有 `%s` 都不替换**，而且不报错。

**规则：CSS / style 字符串一律用普通拼接 + `.toFixed(n)`，不用 `.format()`。**
`'%t'`（运行时间）和 `'%.2f'`（负载）那两处上游写法可以留，因为那两串里没有裸 `%`。

---

## 5. 主题 CSS 变量：只按目标主题适配，但 fallback 要取**真实值**

各主题定义的变量集**不通用**（argon 和 bootstrap 是两套）。先确认设备在用哪个主题，
再去读它的 CSS：

```bash
# bootstrap 的变量定义全在这里
feeds/luci/themes/luci-theme-bootstrap/htdocs/luci-static/bootstrap/cascade.css
```

bootstrap 浅色模式常用的一组（直接抄真实值当 fallback）：

| 变量 | 浅色值 |
|---|---|
| `--background-color-high` | `hsl(0,0%,100%)` |
| `--background-color-medium` | `hsl(0,0%,97.65%)` |
| `--background-color-low` | `hsl(0,0%,96.08%)` |
| `--text-color-highest` / `high` / `medium` / `low` | `0%` / `25.1%` / `50.2%` / `74.9%` （`hsl(0,0%,L)`） |
| `--border-color-high` / `medium` / `low` | `80%` / `86.67%` / `93.33%` |
| `--primary-color-high` | `#1976d2` |
| `--error-color-high` | `rgb(246,43,18)` |
| `--success-color-high` | `rgb(0,172,89)` |
| `--warn-color-high` | `#efbd0b` |

写法：

```js
function css(name, fallback) { return 'var(--' + name + ', ' + fallback + ')'; }
var cCardBg = css('background-color-medium', '#f9f9f9');   // fallback = 主题真实值
```

这样万一主题没定义某个变量，回落出来**仍是本机配色**，而不是不相干的颜色。
（用户明确不用某主题时，就别为它做适配 —— 但 `var(--x, fallback)` 这个写法留着当保险，成本为零。）

---

## 5.5 卡片并排：底边对齐靠 stretch —— 光改 `align-items` 还不够

2026-09-30 实测（状态→总览：左四卡 + 右硬件信息；下面内存 / 储存并排两张卡）。

**症状**：同一行里内容少的那个停在自身高度，底边参差。设备截图里「储存」比「内存」矮一截，
左栏四卡又比右栏的信息面板短一截。

**根因**：容器写了 `align-items: flex-start`。

**必须同时满足两条**，只做一半等于没做：

1. 容器不 pin 交叉轴 —— `align-items` 用默认的 `stretch`（显式写 `stretch` 更好，它是**承重的**，值得标出来）；
2. **要拉伸的网格 / 面板必须是 flex 子项本身，中间不能包一层 div。**

第 2 条最容易漏，症状极具迷惑性：外层 pane 明明变高了，里面的卡片还是矮的。

```js
// ✗ 包裹层吃掉了拉伸：pane 高了，网格仍停在内容高度，卡片依旧短
var pane = E('div', { style: 'flex: 3 1 360px; min-width: 0' }, [ E('div', { style: S_CARD_GRID }, cards) ]);

// ✓ 网格自己当 flex 子项
var pane = E('div', { style: 'flex: 3 1 360px; min-width: 0; ' + S_CARD_GRID }, cards);
```

右栏同理：把 `flex: 2 1 260px` 挂到那块带边框的面板自己身上。
把 pane 尺寸当参数传进去（`buildInfo(pairs, paneStyle)`）比再套一层 div 干净，
也让「这里是个 flex 子项」留在调用点上。

**网格为什么会长高**：`display: grid` 不写 `grid-template-rows` 时行是 auto-size，
容器的 `align-content` 默认 `normal` 即按 `stretch` 处理 ⇒ 多出来的高度**平分给各行**，
下面那行卡片就跟着长高对齐。**反之，一旦写死 `grid-template-rows: 40px 40px` 就废了。**

**纯结构回归断言**（本项目 `selftest.js` 第 8 节那 8 条，不需要浏览器）：

* 容器 style 含 `align-items: stretch`（或不写 `align-items`），且**不含** `flex-start`；
* 卡网格 / 信息面板**自己**带 flex 尺寸 —— `kids[0].attrs.style` 里同时有 `flex:` 和 `grid-template-columns`；
* 网格没写死 `grid-template-rows`；
* 一条**前提断言**：两张卡的进度条行数确实不等（内存 4 行 vs 储存 3 行），
  否则上面几条等于没测到东西 —— 断言要能证明「测试对象确实存在差异」。

**预览页宽度要固定**（本项目固定 1080 px，与用户截图同宽），用 `width:` 而不是 `max-width:`。
否则预览面板一窄，两栏/两行就折成上下堆叠，恰好把要检查的对齐效果藏掉。
（注意别在后面又写一条 `max-width` 规则把它截回去。）

**想真看一眼对齐效果，不用自己下浏览器**：宿主机上 `agent-browser` 和 Chrome 早就装好了 ——
`~/.workbuddy/binaries/node/workspace/node_modules/.bin/agent-browser`，
Chrome 在 `~/.agent-browser/browsers/`。**只查 `PATH` 里的 chromium/firefox 是不够的**：
2026-09-30 我就这么误判成"宿主机没浏览器、截不了图"，白绕了一轮。直接 `file://` 打开
`preview.html` 也能截（见 §10.1）。

---

## 5.6 并排的几张卡：主数值统一用一个字号常量

2026-09-30 实测（用户指着截图圈了四处：「改成 CPU 那个大小」）。

四张卡各写各的字号（温度 16px、Pon 速率 16px、CPU 24px、连接数 24px）会让同一块里的
「主数值」大小不一，看起来像没做完。**立一个常量，所有卡的主数值都引用它**：

```js
var S_BIG_BASE = 'font-size: 24px; font-weight: 600; line-height: 1.15; font-variant-numeric: tabular-nums';
var S_BIG      = S_BIG_BASE + '; color: ' + cStrong;   // 多数卡直接用这个
var S_UNIT     = 'font-size: 12px; color: ' + cLabel;  // 单位 / 次要读数
```

* **一定要拆出不含颜色的 `S_BIG_BASE`**：温度卡的主数值要按冷热换色
  （`S_BIG_BASE + '; color: ' + color`），沿用带 `color` 的 `S_BIG` 就覆盖不掉。
* **只放大主数值**：单位（`°C` / `%` / `Mibit/s`）和次要读数（CPU 的实时主频）保持小字 ——
  连它们一起放大会糊成一片，「主数值」反而立不住。
* **副作用要在调用点确认**：`display: flex; justify-content: space-between` 的行里，
  主数值变宽会把中间的进度条挤短、数值贴近卡片右边缘。这是预期内的，
  别用 `overflow: hidden` 去遮；改字号前后各截一张图比一比。
* `font-variant-numeric: tabular-nums` 让数字等宽，5 秒轮询刷新时不会左右抖。

### 5.6.1 字号是**分层**的：主数值一级、次级数字一级（2026-09-30 追加）

同一块里的数字至少有两层，**每一层各自一个常量** —— 不然"同一类数字"会在两张卡上各长一样：

| 层 | 例子 | 本项目取值 | 常量 |
| --- | --- | --- | --- |
| 主数值（每卡一个） | 温度、CPU %、上下行速率、TCP/UDP 计数 | 24 px | `S_BIG` |
| 次级数字（主数值旁边的读数） | CPU 实时主频、**硬件卸载计数** | 16 px | `S_SECOND` |
| 说明文字 | `硬件卸载`、`上行速率`、`TCP`、单位 | 11–12 px | `S_OFFLOAD` / `S_RATE_LABEL` / `S_UNIT` |

**踩过的具体坑**：`S_OFFLOAD_NUM` 当初只写了 `color` + `font-weight`，**没写 `font-size`**，
于是字号从外面那层 11 px 的「硬件卸载」说明文字**继承**下来 —— 结果同一个"次级数字"，
CPU 主频是 16 px、卸载计数是 11 px，隔一张卡就不一样大。用户一眼就看出来了。

> 教训：**给数字写样式时把 `font-size` 显式写上**。靠继承拿字号，在别人调外层时会被无声改掉，
> 而且改的人根本想不到自己动了另一张卡的数字。

**配套坑：`tabular-nums` 记号会被当判据用，别乱加。** 本项目的离线自测拿
「带 `font-variant-numeric: tabular-nums` 的节点必须是黑色的」当判据（因为 `S_BIG`/`S_SECOND`
都带这个记号），而卸载计数是 success 绿、设计如此 —— 给它加 `tabular-nums` 就会自相矛盾。
所以要**再立一条反向断言**（"卸载计数必须保持绿"）把设计意图钉住，
而不是把判据放宽到谁都拦不住。

---

## 6. 一个会整块炸掉的坑：`zonename` 必须是合法 IANA 时区名

stock 代码（`view/status/include/10_system.js`）：

```js
zn = uci.get('system', '@system[0]', 'zonename')?.replaceAll(' ', '_') || 'UTC',
datestr = new Intl.DateTimeFormat(undefined, { ..., timeZone: zn }).format(date);
```

`Intl.DateTimeFormat` 收到非法时区名会**直接抛 `RangeError`**，
**整个块渲染不出来**（不是显示错，是整块空白）。

注意 `/etc/config/system` 里有两个字段，**别搞混**：

* `option timezone 'CST-8'` —— 给 `/etc/init.d/system` 的 `TZ` 环境变量用；
* `option zonename 'Asia/Shanghai'` —— **这个才是喂给 `Intl` 的**。

排查：`uci get system.@system[0].zonename`，或直接 `cat /etc/config/system`。
恢复出厂配置 / 换固件后要复检一遍。

---

## 7. 轮询机制：是浏览器在轮询，不是设备

回答「这会不会一直占 CPU / 关了浏览器还在跑吗」这类问题时，直接给证据链：

| 检查项 | 命令 / 位置 |
|---|---|
| 轮询实现在哪 | luci-base `luci.js` 的 `Poll` 类：`window.setInterval(this.step, 1000)` |
| 间隔来源 | `L.env.pollinterval` ← `header.ut` 的 `+config.main.pollinterval \|\| 5` ← `/etc/config/luci` |
| 谁注册的 | 页面自己的 `poll.add()`（如 `view/status/index.js`） |
| 设备有 crontab 吗 | `ls -la /etc/crontabs/`（空就是没有） |
| 有 cron / collectd 吗 | `ps w \| grep -E 'cron\|collectd'`、`apk list -I collectd` |

结论模板：**前端 `setInterval` 驱动的，页面一关就停，设备侧没有任何后台采样器。**

---

## 7.5 页面显示「0 / 未启用」时，先分清**懒初始化**还是**真故障**

用户看到自己新加的卡片显示「未启用」就来问「为什么」——**先别改文案也别改代码**，
去内核/驱动源码里确认那个值是谁写的、什么时候写。**有一类状态是"懒挂载"，开机本来就该是 0。**

实例（2026-09-27 实测，Airoha AN7581）：
`/sys/kernel/debug/ppe/config` 的 `npu_attached` 打印的是 `!!rcu_access_pointer(eth->npu)`，
而 `eth->npu` 全树**唯一赋值点**在 `airoha_ppe_offload_setup()`，**唯一调用者**是
`airoha_eth.c` 的 `case TC_SETUP_CLSFLOWER` —— 也就是**第一条真正被硬件卸载的流转发出现时**才挂。
⇒ 无上联 / 无转发流量时它**永远是 0**，这是**正确状态**，不是页面 bug、也不是驱动坏了。
实测对照：同一台机器，接通 PON（ONU 到 O5、pppoe-wan 拿到地址）后立刻变 `1`，
conntrack 里出现 `[HW_OFFLOAD]` 条目。

判据 / 套路：

| 步骤 | 做什么 |
|---|---|
| 1 | `grep -rn "<那个值>" <驱动源码>` 找到**赋值点**，再看**谁调用** |
| 2 | 若调用点在"事件/每流/每请求"路径上 ⇒ 懒初始化，空闲时为 0 属正常 |
| 3 | 想验证而不改用户网络：造一条最小的真实事件即可（见下） |
| 4 | 别急着改文案；先有实测结论，再决定要不要把措辞改准（措辞改动要重编） |

**措辞怎么改**：判为懒初始化后，把「未启用 / 未开启 / 失败」这类**故障语义**换成
**待命语义**（例：`硬件卸载未启用` → `硬件卸载待命（暂无卸载流）`），
并在代码里留一段注释写清**依据**（哪个函数赋值、哪个路径触发），
避免下一个人再当成 bug。**改文案要一次改齐 4 处，漏一处就自相矛盾**：

| # | 位置 | 典型内容 |
|---|---|---|
| 1 | 源码树 `files/` 里的模块 | 字符串本体 + 依据注释 |
| 2 | 归档 `files/` 里的同名模块 | 与源码树 `cmp` 必须逐字节一致（改完 `diff -r` 复核） |
| 3 | `selftest.js` | 里面**硬断言了旧字符串**（`flat.includes('硬件卸载未启用')`）——不改必然 FAIL；注意正反两面都要改（`!flat3.includes(...)`）。**改动若是"颜色/加粗/拆节点"这类样式事，断言同样会红**：旧写法可能直接命中 0 个节点，要按上一节换成"纯数字 + 查父节点" |
| 4 | `README.md` | ASCII 示意图、改动清单、数据源表、"状态与遗留" 四处都容易漏；末尾要给 sha256 变化记录，方便判断手上文件是哪一版 |
| 5 | 交付说明 / 项目记忆 | 「下一版会变的界面」那张表 + 新 sha256；**颜色描述也要精确**（写「只有数字绿、标签保持灰」，别写「整体绿色」） |

改完跑 `node selftest.js` 全绿 + `node mock-render.js` 重生成 `preview.html`
（预览页是**生成物**，里面有同一串文字，必须重跑，否则文档和实现对不上）。
最后**明确告诉用户：镜像里还是旧文案，要重编 + 重刷才生效** —— 别让他以为刷过了。

**造"最小真实流"的低成本手法**（不用 tc、不用动用户的网络配置）：本地 kmods 仓库里
通常已有 `kmod-dummy`（离线 `apk add` 可用）→ `ip link add d0 type dummy` + 给个地址
→ 从另一台机器发 2 个以上 **UDP** 包到那个网段的某个不存在地址。
依据：fw4 的 `chain forward` 里 `meta l4proto { tcp, udp } flow add @ft` 是**第一条规则**，
且 `nft_flow_offload_eval` 对 UDP 只要求 `nf_ct_is_confirmed()`（TCP 才要求
`nf_conntrack_tcp_established()`）⇒ **同方向第 2 个包**就会触发硬件卸载回调。
做完 `ip link del d0` / `rmmod dummy` / `apk del kmod-dummy` 复原
（注意：`dummy` 模块会因 `numdummies=1` 默认自动建出 `dummy0`，两个接口都要删；
包数要回到与 manifest 一致）。

---

## 8. 不刷机的验证：node 桩 + 元素树序列化

**这是本流程最有价值的环节** —— 能在编译之前就把逻辑 bug 抓出来。
（实测抓到过：一个「去掉字符串尾部温度」的正则把整段括号连主频一起吃掉，
肉眼复查两遍都没看出来。）

原理：LuCI 的 JS 模块是 `'require x';` + `return baseclass.extend({...})`，
用 `new Function()` 执行时把 `'require ...'` 行剥掉、把 LuCI 全局桩上，就能在 node 里跑。

桩清单（缺一个就报 `xxx is not defined`）：

| 全局 | 作用 |
|---|---|
| `fs` | `trimmed/read/exec/list` —— 返回 `Promise`，喂**设备实测值** |
| `L` | `resolveDefault` / `isObject` / `env.pollinterval` |
| `_` | 取字符串本体（`(s) => s`） |
| `E` | 极简元素树 `{tag, attrs, children}`，带 `appendChild` |
| `baseclass` | `{ extend: (o) => o }` |
| `rpc` | `{ declare: () => () => Promise.resolve({}) }` |
| `uci` | `{ load: () => Promise.resolve(), get: (s,x,o) => ... }` |
| `window` | **`{ setTimeout: (fn, ms) => setTimeout(fn, ms) }`** —— 模块里合法地用 `window.setTimeout` 做首帧二次采样，node 里不加这个桩必报 `ReferenceError: window is not defined` |
| `String.prototype.format` | 按 `%s/%d/%.Nf/%t` 补一个最小可用版 |

完整可抄的骨架见 `assets/luci-module-harness.js`。

跑法：

```bash
node --check <module>.js        # 语法
node selftest.js                # 行为断言，末行应打印「全部通过」
node mock-render.js             # 把元素树序列化成 preview.html，浏览器里看效果
```

`preview.html` 的要点：**不要手画示意图**。让脚本真的去执行那两个模块、
喂实测值、再把返回的元素树序列化成 HTML —— 这样预览和实际渲染是同一份代码，
不会出现「图好看但代码跑不出来」。外层套一份主题变量的 CSS（抄 §5 的真实值）即可。

---

## 9. 出镜像前的动作（⚠️ 2026-09-27 修正：原来的 `rm Image` 会炸）

```bash
touch .config                               # 只做这个
rm -rf build_dir/target-*/root-<board>      # 强制重建 rootfs，否则覆盖层可能不重放
make world -j8 IGNORE_ERRORS=m
```

### 为什么不能再写 `rm -f build_dir/*/linux-*/Image`

`world` 是 **stamp 驱动**（`Makefile:133`），实测步骤序列
`package/compile → package/install → target/install`，**不含 `target/compile`**。

而内核拷贝带 **`cmp` 短路守卫**（`include/kernel-defaults.mk:154`）：

```make
define Kernel/CopyImage
	cmp -s $(LINUX_DIR)$(2)/vmlinux $(KERNEL_BUILD_DIR)/vmlinux$(1).debug$(2) || { \
		…objcopy…; \
		cp $(LINUX_DIR)$(2)/arch/$(LINUX_KARCH)/boot/$(IMAGES_DIR)/$(k) $(KERNEL_BUILD_DIR)/$(k)$(1)$(2); \
	}
endef
```

守卫只问「**内核变了没**」，**不知道目标文件被删了**。所以只要这轮内核与上次
**逐字节相同**（确定性构建很常见），`cmp` 判等 ⇒ 整段跳过 ⇒ `Image` 永远补不回来 ⇒
`image/Makefile` 的 `Build/kernel-bin`（`rm -f $@ ; cp $(KERNEL_BUILD_DIR)/Image $@`）报
`cp: cannot stat '…/Image': No such file or directory` ⇒
`make[4]: *** [Makefile:36: …-kernel.bin] Error 1` ⇒ `target/linux failed to build`。

**实测证据**（删了 Image 的那轮）：`vmlinux.debug` mtime 一直是上一轮的 03:28、
`$(KDIR)/vmlinux` 一直是 04:51 —— 拷贝段一次都没执行；而 `arch/arm64/boot/Image`
是 81,856,520 B 的 initramfs 版（干净内核只有 14,157,832 B），且它与
`Image-initramfs` **逐字节相同**、内含 rootfs（`grep -a -c luci-static` = 380）。

### 正确姿势：改成「编完三条判据 + 不过才强制重建」

```bash
K=build_dir/target-aarch64_cortex-a53_musl/linux-<board>
stat -c%s $K/Image                       # 正常 ≈14 MB；≈80 MB ⇒ 那是 initramfs 版
grep -a -c luci-static $K/Image          # 必须 0（内嵌 rootfs 的判据）
staging_dir/host/bin/mkimage -l bin/targets/.../…-sysupgrade.itb | grep -A6 'Image 0'
#                                        # kernel-1 正常 ≈6 MB；≈rootfs 大小 ⇒ 中招
```

不过再强制重建 —— **两个文件一起删**（删掉守卫的参照物才会真的走拷贝）：

```bash
rm -f build_dir/*/linux-*/Image build_dir/*/linux-*/vmlinux.debug
make -j8 target/linux/install IGNORE_ERRORS=m     # ≈2 分钟
```

原理：`.image` 配方里 `Kernel/CompileImage/Default` 是**先**用干净 `.config` 重编内核、
**再**拷贝，所以拷到的一定是干净份。

### 覆盖层改动只动 rootfs 时的最强判据：FIT 节点 sha1 等价性

纯 `files/` 覆盖层改动**不该碰内核**。拿新老两颗 `.itb` 用 `mkimage -l` 比 FIT 节点 sha1
（输出顺序为 kernel / fdt / rootfs）：

* `kernel-1`（+ `fdt-1`）sha1 **相同** ⇒ 内核未变 ⇒ **不可能有"旧 .ko 锁新内核"风险**，
  也不必跑 `openwrt-offline-kmod-repo` 那套模块新鲜度门禁；
* 只有 `rootfs-1` 不同 ⇒ 改动面正如预期。

```bash
mk=staging_dir/host/bin/mkimage
for f in <新.itb> <旧.itb>; do
  echo "== $f"; $mk -l "$f" | grep -A1 'Hash algo: *sha1' | grep 'Hash value'
done
```

### 附：`touch .config` 到底有没有用（纠正旧说法）

`$(STAMP_CONFIGURED)` 的依赖里本来就有 `FORCE`（`include/kernel-build.mk`），
所以 `Kernel/Configure` **每轮都会跑**，`touch .config` 并非"强制它重跑"。
真正决定 Default 趟拿到的是干净还是 initramfs 配置的，是这句**条件拷贝**
（`kernel-defaults.mk:124`）：

```make
cmp -s $(LINUX_DIR)/.config.set $(LINUX_DIR)/.config.prev || { \
	cp $(LINUX_DIR)/.config.set $(LINUX_DIR)/.config; \
	cp $(LINUX_DIR)/.config.set $(LINUX_DIR)/.config.prev; }
```

`.config.prev` 由 initramfs 趟删掉 ⇒ 下一轮 `cmp` 必失败 ⇒ 拷贝执行 ⇒ 配置回到干净态。
**所以判据永远以产物为准（上面三条），不要以"我做了某个动作"为准。**

跑构建前先净化 WorkBuddy 的「删除外壳」（否则 OpenWrt 的 `make` 会在删临时文件那步莫名崩）：

```bash
unset -f rm unlink rmdir 2>/dev/null
unset CODEBUDDY_SESSION_ID CLAUDE_SESSION_ID CODEBUDDY_SAFE_DELETE_ENABLED
export PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v 'shim/safe-bin' | paste -sd:)
```

---

## 10. 刷完 / 装完包之后的验收清单

```bash
# 1) 文件到位且内容对
sha256sum /www/luci-static/resources/<file>.js /usr/sbin/<helper> \
          /usr/share/rpcd/acl.d/<name>.json

# 2) 关键判据：覆盖层赢了 jsmin（见 §1）—— 只对方案 A 有效
wc -l /www/luci-static/resources/view/status/include/*.js

# 3) rpcd 真的给读 / 给执行
ubus call file read '{"path":"/sys/kernel/debug/.../frontend"}'
ubus call file exec '{"command":"/usr/sbin/<helper>"}'

# 4) 页面上真的出来了（浏览器打开 状态→总览，F12 看有没有 ACL 报错）
```

方案 C（apk）多两条：

```bash
# 5) 默认块确实被停用了、包文件确实在位
ls -la /www/luci-static/resources/view/status/include/
#    期望：10_system.js 不在、10_system.js.disabled 在、15_hw.js 在
# 6) 卸载即还原
apk del <pkg> && reboot   # 之后 10_system.js 应该回来了
```

> ⚠️ **设备 busybox 没有 `stat`**（`sh: stat: not found`，实测 mt7981/AN7581 的 busybox 都不带
> `stat -c %s`）。写在线体检脚本时**取字节数必须用 `wc -c < "$f"`**（顺手 `tr -d ' '` 去掉
> busybox 的补白空格），行数用 `wc -l < "$f"`。别写 `stat -c%s`，否则大小列全是空的、还看不出错。
>
> 反例自测很有用：新写的验收脚本，**先拿"旧版还没生效的设备"跑一遍**，
> 它必须报失败（否则判据在放水）。本项目就是这么发现上面那个 `stat` 坑的。

### 10.1 真浏览器验证 —— **只有它能证明"块真的显示出来"**

上面 1–6 条全是**文件/服务层**的判据：文件到位、目录扫描能看到新文件名。但**页面上到底出没出来、
数据取没取到**，只有真浏览器能证。本项目 2026-09-28 第一次用 agent-browser 把这段补上：

```bash
# 首次要装（约 190 MB 的 Chrome）；全局装被禁时就在 node workspace 里本地装
cd <node workspace> && npm install agent-browser && ./node_modules/.bin/agent-browser install
AB=./node_modules/.bin/agent-browser

$AB open "http://<dev>/cgi-bin/luci/admin/status/overview"
$AB wait --load load        # ⚠️ 别用 networkidle：块每 5 秒轮询一次，永远不 idle
sleep 8                     # 等首屏数据回来
$AB snapshot > /tmp/snap.txt
grep -n 'heading' /tmp/snap.txt    # 每个块 = 一条 heading "<title>" [level=3]
# ⚠️ 块标题在实际页面里带「隐藏」后缀 ⇒ XPath 必须 starts-with 前缀匹配，见坑 1
SEL='xpath=//h3[starts-with(normalize-space(.),"<块标题>")]/ancestor::div[contains(@class,"cbi-section")][1]'
$AB set viewport 1080 1600  # 视口调高，见坑 3
$AB scrollintoview "$SEL"
$AB screenshot "$SEL" card.png
$AB screenshot --full overview.png   # 见坑 2
$AB close                    # 无论成败都要关，否则留僵尸 daemon
```

**截图有三个静默的坑**（都踩过，2026-09-30）：

1. **XPath 必须前缀匹配** —— 块标题在实际页面里带「隐藏」后缀（snapshot 里是
   `heading "硬件监控 隐藏"`），写成 `normalize-space(.)="硬件监控"` 会**一张都截不到**
   （脚本里那个卡片截图就这么 WARN 了好久没人管）。XPath 1.0 没有 `ends-with`，用 `starts-with`。
2. **不写 `--full` 只截一屏** —— 总览页比 viewport 长（我们的块下面还有端口状态/网络/无线），
   不 `--full` 会从中间把第二个块切断。
3. **元素截图：落在视口外的部分会被拍成空白，而且不报错** —— 最坑的一条。块在 y≈475~725
   而视口只有 567 px 高时，截出来的 PNG 只有顶部 92 px 有内容、其余全白，**看上去像
   「卡片里的明细行没渲染出来」**。别拿它当 bug 报（我差点报了）：去 DOM 里量
   `getBoundingClientRect()`（各元素都有高度、`color` 正常、`vis=visible`）才是判据。
   对策就是上面那两行 —— `set viewport` 调高 + `scrollintoview`。
   > 这条坑的通用教训：**截图是观测手段，不是判据**。图看着不对时，先回 DOM 量数，
   > 再怀疑图。`agent-browser eval` 拿 `rect`/`getComputedStyle` 只要 40 秒，比改错代码便宜。

**「颜色/字号改对了吗」也要量，不要看**（2026-09-30 加）。用户说"这个数字别用黄色"这类
诉求，验收动作就是把**设备上**那个元素的 computed style 打出来，而不是看截图"像不像黑的"：

```js
// agent-browser eval —— 先定位一个稳定的锚点（这里是跟在数值后面的单位 °C），
// 再往上/往旁边取要验的那个元素。别用 querySelector 瞎猜类名，LuCI 的 class 不稳定。
(() => {
  const deg = [...document.querySelectorAll("span")]
    .find(s => s.children.length === 0 && s.textContent.trim() === "\u00b0C");
  const wrap = deg.parentElement;                    // 数值和单位同一个 span
  return { html: wrap.outerHTML,
           color: getComputedStyle(wrap).color,        // 期望 rgb(0, 0, 0)
           fs:    getComputedStyle(wrap).fontSize };   // 期望 24px
})()
```

判据写成字符串比较（`rgb(0, 0, 0)` / `24px`），就能进脚本当门禁 —— 比截图 diff 稳得多，
也不会被主题变量（`var(--text-color-highest, #000000)`）在不同主题下的解析差异骗到。

想证明"整个块再没有别的异色数字"，就把块内**所有叶子文字**按 computed color 归并成一个
`{color: [样本文本…]}` 表：

```js
root.querySelectorAll("span,div,strong,b,td").forEach(e => {
  if (e.children.length !== 0) return;              // 只看叶子，避免拿父元素继承色
  const t = e.textContent.trim(); if (!t) return;
  (res[getComputedStyle(e).color] ||= []).push(t.slice(0, 24));
});
```

实测这张表很有用：它会立刻告诉你还有没有"漏网"的带色数字（本项目里就揪出了
硬件卸载计数的**绿色** `rgb(0, 172, 89)` —— 用户只说"不要黄色"，所以绿的那两个数字是
**故意留着**的，得回去跟用户确认，而不是自己顺手一起改黑）。

> 注意扫描根别往上找太多层：`closest('.cbi-section')` 再往上扩会把侧边导航也圈进来，
> 于是表里混进 `rgb(255,255,255)` 的导航文字，白白吓自己一跳。

#### 升级用法：**跨版本做差** —— 用数字证明"改动边界恰好正确"（2026-09-30 实测）

单页普查只能说"现在有哪些颜色"。真正有力的问法是"**改完之后，那个不该存在的色值是不是
一处不剩，而且一处没多杀**"。做法是**把两个版本各生成一份、各普查一次、相减**：

```bash
W=/tmp/cmp; rm -rf $W; mkdir -p $W/{old,new}/files
cp mock-render.js $W/{old,new}/

# new: 当前工作区；old: 从 git 里把上一版抠出来（别用备份目录，可能会有第三份副本不一致）
cp files/* $W/new/files/
cp files/* $W/old/files/
git show <上一版rev>:files/15_hw.js      > $W/old/files/15_hw.js
git show <上一版rev>:files/22_memstore.js > $W/old/files/22_memstore.js

(cd $W/old && node mock-render.js); (cd $W/new && node mock-render.js)
# 再用上面的普查 JS 分别 eval 两个 file:// URL，把 (颜色, 计数) 两组数并排比
```

本项目实测（把浅灰 `#bfbfbf` 并入深灰 `#808080`）：

| 颜色 | old | new |
| --- | --- | --- |
| `rgb(0, 0, 0)` 主数值 | 21 | 21 |
| `rgb(0, 172, 89)` 绿计数 | 2 | 2 |
| `rgb(128, 128, 128)` 深灰 | 11 | **43** |
| `rgb(191, 191, 191)` 浅灰 | **32** | **0** |

**11 + 32 = 43** —— 这一行等式就是判据：新增的 32 正好等于被消灭的 32，
说明**一处不漏、一处不多**；黑/绿/标题三类计数**一模一样**，说明没误伤别的样式。

**关键价值：这套不用装机。** 预览页与真机用的是同一份源码、同一套 bootstrap token，
所以"改动的边界"可以在编译前就量死；装机后再跑真机版门禁复核一次即可。

> ⚠️ 两个前提：① 生成器时钟必须已钉死，否则两份预览没法比（见 §10.3）；
> ② **别把仓库里那份 HTML 原件交给浏览器打开** —— 宿主预览面板会回写它（见 §10.4），
> 所以在 `/tmp` 里做。


**探针的扫描范围必须锁在自己那个块里**（2026-09-30 实测）。第一版探针用全局
`document.querySelectorAll("span")` + `tabular-nums` 当锚点，结果**假阳性 7 个** ——
下面另一个块（内存与储存）的行值**用的是同一个记号**、本来就该是 `text-color-low` 的灰。
正确做法是先按块标题定位再把范围收进去：

```js
const h = [...document.querySelectorAll("h3")].find(e => e.textContent.trim().indexOf("硬件监控") === 0);
const root = h ? (h.closest("div.cbi-section") || h.parentElement) : document;
// 之后只查 root.querySelectorAll(...)
```

两个小细节：

* **中文字面量写成 `\u` 转义**（`"\u786c\u4ef6\u76d1\u63a7"`），别把中文直接嵌进脚本 ——
  经过 ssh / heredoc / 不同 locale 几道手，字面量写着写着就坏了。
* **`agent-browser eval` 返回字符串是 JSON 编码的**（首尾各一个双引号，内部引号被转义）。
  shell 里想 `case "$X" in OK*)` 得先剥壳：`sed -e 's/^"//' -e 's/"$//'`。
  返回对象时它打的是多行 JSON，shell 里解析很别扭 ⇒ **让 JS 自己做完断言、
  只回一行 `OK/NG + 关键数字` 的字符串**，shell 只管 case 匹配。这条比在 shell 里 parse JSON 省事得多。

判据：

* **新块标题在 `heading` 列表里、旧块标题不在** ⇒ 「停用 + 顶上」都生效（一条 grep 就够，不用看图）；
* `snapshot` 里的 `StaticText` 是**渲染后的真实数值**（温度 / MHz / 连接数…）——这是"数据通路端到端
  真的通了"最硬的证据，比任何离线断言都直接；
* `screenshot <selector>` 传 **XPath** 能只截某个块，比整页截图清楚得多（`div.cbi-section` 是 LuCI 的块容器）。

两个环境要点：

* **root 无密码的设备，登录框点一下「登录」就进去了**（用户名已预填 `root`）；有密码的要问用户。
* 本机/容器**未必能直连设备网段**：先 `curl -s -o /dev/null -w '%{http_code}' http://<dev>/` 探一下，
  不通就 `ssh -L 8080:<dev>:80` 端口转发，别硬试。

**这套已固化成脚本**：归档里的 `verify-ui.sh`
（`./verify-ui.sh <ip> [--expect card|stock|auto]`），装了 `agent-browser` 就能直接跑，
输出 PASS/FAIL + 整页与卡片两张截图。两条**必须照做**的判据细节：

1. **块标题要前缀匹配** —— 有的 LuCI 版本把「隐藏」并进标题文本，`snapshot` 里是
   `heading "硬件监控 隐藏"`；写成 `heading "硬件监控"`（带结尾引号）会**漏判**。
2. **「两个块并存」必须单独判 FAIL** —— 新块在、旧块也在 = 包脚本的停用逻辑没生效，
   这是最危险的失败模式（用户会看到两块内容），不能只判"新块在不在"。

### 10.2 「LuCI 登录不了」怎么查 —— ucode 版 LuCI 的会话机制（2026-09-29 实测，含一次自我纠错）

**先记住：登录跟你想的不一样，猜错方向会浪费一整轮。** ucode 版 LuCI（24.10+，
`/www/cgi-bin/luci` = `#!/usr/bin/env ucode` + `import dispatch from 'luci.dispatcher'`）
的会话**完全走 ubus**：

```
/usr/share/ucode/luci/dispatcher.uc
  :472  session_retrieve(sid) → ubus.call("session","get"/"access", {ubus_rpc_session: sid})
  :498  session_setup(user,pass) → ubus.call("session","login",{username,password})
                                   → session.set{values:{token:randomid(16)}}
```

⇒ **两个反直觉结论**：

1. **`luci.sauth.sessionpath='/tmp/luci-sessions'` 是废弃配置项**，`/tmp/luci-sessions`
   **不存在是正常的**。我第一轮就是看到这个目录缺失、误判成"会话写不进去"，错的。
2. **cookie 名按连接方式分**：HTTP → `sysauth_http`，HTTPS → `sysauth_https`
   （`path=/cgi-bin/luci/; SameSite=strict; HttpOnly`）。抓包/复现时**别只 grep `sysauth`**，
   否则会得出"没下发 cookie"的错误结论（我也踩了）。
3. 登录表单就是普通 POST（无 CSRF）：字段 `luci_username` / `luci_password` →
   `POST /cgi-bin/luci/`；**成功 = `302` → `/cgi-bin/luci/admin/status/overview` + `Set-Cookie`**。
   未登录 GET 时返回 **`403` + `x-luci-login-required: yes`**，这是**正常行为不是故障**。

**四步排障（从设备往外，每步都给硬判据）**：

```bash
# 1) 凭证层：空密码能不能换到 session+ACL？
ubus call session login '{"username":"root","password":""}'      # 看有没有 ubus_rpc_session
#    顺带看账号状态：root:::0:99999:7::: 里的第二个字段为空 = 空密码
head -2 /etc/shadow

# 2) HTTP 层：登录取没取到 cookie？（用 node/py 都行，别用 BusyBox wget，它没有 POST）
#    POST luci_username=root&luci_password= → 期望 302 + sysauth_http=...
#    再带该 cookie GET /cgi-bin/luci/admin/status/overview → 期望 200 且【不含】luci_username

# 3) 服务端到底认没认：设备日志里能直接分辨「密码错」和「根本没到设备」
logread | grep -E 'luci: (accepted|failed) login'
#    accepted → 密码是对的；failed → 密码错；两边都没有 → 请求压根没提交到 dispatcher

# 4) 浏览器层：只有真浏览器能证 JS 起了没（见 §10.1，agent-browser）
```

**关键判读**：如果 `#3` 里**只有 accepted、0 条 failed**，而用户说"登录不了"，那**不是密码问题**
——要么他其实登进去了，要么他的提交**从来没到设备**（网络/URL/浏览器缓存/开了 HTTPS 而
uhttpd 没监听 443 等）。这时**别改设备上的任何凭证**，先问清"具体看到什么 + 从哪个地址访问"。

**其它现场事实**：

* **root 空密码时 LuCI 会弹黄条**「未设置密码！…请设置管理员密码」——**不拦登录**，
  别把它当成"登录失败"。想设密码走 `ubus call luci setPassword '{"username":"root","password":"..."}'`
  （rpcd 的 `luci.so` 插件提供，`ubus -v list luci` 可见）。
* **`dropbear` 的日志会误导**：它允许空密码登录并记 `Auth succeeded with blank password`，
  这跟 LuCI 是两条完全独立的认证路径，不能互相印证。
* 容器**常常能直连设备网段**（本项目实测可以），所以 `agent-browser` 直接在容器里跑就行；
  不通再考虑 `ssh -L`（判据见 §10.1）。

---

### 10.3 生成物（预览页 / 文档截图）必须能"重跑复现" —— 否则它静默过期

**踩过的坑（2026-09-30）**：仓库里提交的 `docs/preview.html` 停在 r3 的样子
（卡片主数值还是 16 px、温度还是黄色的 `--warn-color-high`），而源码早就改成 24 px 黑了。
两轮改动都没人重跑生成器，README 还在指着那个过期的文件说"这就是真实渲染结果"。

**当时的"验证"是这样的**（错的）：

```bash
# ❌ 拿一个样式串去 grep，看到只有一种就断言"已同步"
grep -o 'font-size: 24px; ...; color: [^"]*' docs/preview.html | sort -u
# → 只有一条（黑色），于是得出结论"和源码一致"
```

**为什么错**：旧版里**温度数值根本不是 24 px**（是 16 px 黄字），所以它压根不在
`font-size: 24px` 的匹配结果里 —— 这个 grep **从结构上就无法覆盖到出问题的那个元素**。
"某一类样式只有一种取值"不等于"这一类的成员都在里面"。

**正确做法（两条，缺一不可）**：

1. **把生成器的时钟钉死。** 预览里只要有一处取"当前时间"（本项目是信息面板的
   `new Date(unixtime * 1000)`），每次生成的结果就都不一样 —— 于是"重跑比字节"
   这条判据**根本无法成立**，只能退回到靠眼睛看。把种子写死成读数采集时刻：

   ```js
   const FROZEN_NOW = 1790702059000;   /* 2026-09-30 01:14:19 GMT+8 = 采集时刻 */
   let fakeNow = FROZEN_NOW;
   Date.now = () => fakeNow;
   ```

2. **门禁里"重跑 + 逐字节比对"**，而且**必须在临时目录里跑**：

   ```bash
   MTMP="$(mktemp -d)"; cp mock-render.js "$MTMP/"; mkdir -p "$MTMP/files"
   cp -f "$REPO"/files/* "$MTMP/files/"
   ( cd "$MTMP" && node mock-render.js ) >/dev/null 2>&1     # 写成 $MTMP/preview.html
   cmp -s "$MTMP/preview.html" "$REPO/docs/preview.html" \
       || bad "预览已过期：改过 files/ 后没重跑生成器"
   ```

   > ⚠️ **一定要在临时目录跑**。如果就地跑，生成器会先把不同步的文件**改对**，
   > 然后 `cmp` 当然一致 —— 一个永远 PASS 的门禁比没有门禁更糟。

**这条检查要自己做一次负向测试**：故意把提交的那份改坏一格，确认门禁报 FAIL、退出码非 0，
再还原。只在不坏时跑过的检查，你不知道它会不会报警。

**同理适用于文档截图**：`docs/screenshot.png` 这类"从真机裁出来的图"没有生成器，
只能靠**每次装机后重裁**。本项目立的规矩是：真机截图随手归档到 `out/<版本>-真机-*.png`，
`docs/` 下那几张在每次版本号 +1 时一并换掉 —— 因为图里的数字（字号/颜色）就是版本的一部分。

### 10.4 仓库里的 HTML 交付物会被**宿主预览面板回写** —— 提交前必须重新生成

**踩过的坑（2026-09-30，就在上一节的检查刚补完的下一轮）**：准备提交时例行跑
"重跑生成器比字节"，发现工作区那份 `docs/preview.html` 是 **25572 B**，
而生成器输出 **18262 B**，**从第 2 行就分叉**。差异是两处：

* 每个标签上被注入了 `data-page-node-id="..."` 属性（宿主的节点标记）
* `<div class="note">` 那段说明文字被**整段吃掉**

#### 污染源已确证 = 把 HTML 交给宿主预览面板打开

第一次只是推测（"某次打开过"）。第二轮做了个对照实验，**当场复现**：

```bash
sha256sum docs/preview.html > /tmp/before.sha    # 记为 aa78b2d4…（18262 B）
#   ... 把 docs/preview.html 交给预览面板打开 ...
sleep 30; sha256sum docs/preview.html; wc -c docs/preview.html
#   → df013282…（25572 B），注入标记 22 处
```

确认：**打开预览 = 原文件被回写**，不是"某次可能"。而且——

| 事实 | 数据 |
| --- | --- |
| 两次污染的**体积完全相同** | 都是 25572 B |
| 两次污染的**哈希不同** | `127b15e6…` vs `df013282…` |
| 原因 | 每处 `data-page-node-id` 的值是随机生成的，**长度固定** |

⇒ **`25572 B` 这个体积就是可靠指纹**（对一份 18262 B 的源而言）。
`wc -c` 一看不对就知道被回写过，不必等 grep。

**怎么认出来**：

```bash
wc -c docs/preview.html                        # 体积对不上生成器的输出
grep -c 'data-page-node-id' docs/preview.html   # 应当为 0；非 0 就是被回写过
```

要点：**不要手工去删那些属性** —— 它们出现在嵌套的每一层（这次 22 处），手删必漏。

**恢复（按可靠性排序）**：

```bash
git checkout -- docs/preview.html    # ① 已提交过 ⇒ 一条命令回到提交时的样子
node mock-render.js                  # ② 没提交过 ⇒ 用生成器重新生成
```

①更快，且顺带证明了"**提交 = 有后盾**"：这份文件之所以敢拿去展示，
就是因为它在 git 里，最坏情况一条命令还原。

**要回头查历史提交有没有也被污染**（这次查了，全是干净的）：

```bash
for c in HEAD <rev1> <rev2> ...; do
  echo "$c $(git cat-file -s $c:docs/preview.html) $(git show $c:docs/preview.html | grep -c data-page-node-id)"
done
```

**预防**（两条一起用）：

1. 上一节的「重跑生成器比字节」门禁 —— 它在本轮**真的拦下了一次不当提交**；
2. **要给别人看/要预览，就 `cp` 一份到 `/tmp/` 再打开**，别把仓库里那份直接交出去。
   仓库里那份是"生成的产物"，只该被生成器写。

---

## 11. 归档：覆盖层改动不在 git 里，必须另存一份

`files/` 和 `.config` 通常都被 `.gitignore` 忽略，**不能靠 `git diff` 当门禁**。
每次改完按**目标路径**归档到源码树之外的目录，附一个 README 记：

* 设备 / 固件版本 / target、**覆盖的那个包的精确版本**（`bin/packages/**/<pkg>-<ver>.apk`）；
* 每个文件的 sha256 + 上一版的 sha256（便于对比）；
* 本轮改动点、踩过的坑、**未验证的假设**；
* 出镜像前动作、刷后验收清单。

**方案之间的形态切换也要一起归档**（本项目实测：从覆盖层换成 apk 时，
把旧覆盖层目录**改名**成 `overlay-0828/`（而不是删掉），新增 `pkg/<pkg>/` 存包源+Makefile 的
逐字节副本，再加一条门禁脚本断言「归档与源码树逐字节一致」——
否则过几个月没人知道归档里那份还是不是当时编进镜像的那份）。

---

## 红线（这个项目的规矩）

* **编译/构建前必须先问用户**能不能开始。
* **刷机等用户明确说「刷」** —— 只交付镜像，不替他按那个键。
* 有疑问不自己猜，把选项和依据摆出来让他拍板。
* 实话优先：没生效就说没生效，未验证就说未验证。
