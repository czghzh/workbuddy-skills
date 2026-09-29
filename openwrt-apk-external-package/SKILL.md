---
name: openwrt-apk-external-package
description: 把一个「仓库在 GitHub、构建系统不是 OpenWrt」的第三方项目（Rust / Node 前端 / Go / 预编译二进制……）交叉编译成 aarch64-musl 二进制，并打成 OpenWrt **apk**（apk v3）软件包，用 `apk add` 装到设备上。当任务是「把 XX 编成 OpenWrt 包/apk/ipk」「这个 GitHub 项目怎么装到路由器上」「交叉编译 Rust/Go 到 OpenWrt」「把界面/脚本改动做成 apk 让用户自己装」时使用。涵盖：rustup + musl target 的交叉编译配方、OpenWrt"纯文件包"模板（含 `PKGARCH:=all` 的 noarch 变体、`postinst/postrm` 接管别的包的文件）、`adbdump` 门禁的路径陷阱、以及三个必踩的坑（未选中的包 compile 是空操作 / 顶层 host 目录缺失 / 包会被装进 root-<board> 污染固件）。
agent_created: true
---

# 把外部项目打成 OpenWrt apk 包

## 什么时候用
目标是一台跑 **apk v3**（`CONFIG_USE_APK=y`，`/etc/apk/repositories.d/`）的 OpenWrt 设备，
要装一个"上游自建"的软件（Rust/Go/Node 服务、CLI 工具）。也适用于要出 `.ipk` 的旧固件
（把最后打包步骤换成 ipk 规则即可；本文按 apk 讲）。

**也包括"没有上游、只是想把一堆现成文件+脚本打成包"**的情形（例如把某个 LuCI 页面改造
做成 `luci-app-xxx` 让用户自己 `apk add`）—— 直接跳到 §5 的模板，那是同一条路。

**先确认包的格式**：本树/设备是 `apk`（apk-tools 3，包后缀 `.apk`，索引 `packages.adb`，
`.apk` 是 `ADBd` 魔数的容器、**不是 tar**）；老固件才是 `.ipk`。用户说"ipk"时先确认。

## 心智模型（四条）
1. **交叉编译在宿主机做**，产物是静态 aarch64-musl 二进制；OpenWrt 只负责"装文件 + 打包 + 签名"。
2. OpenWrt 里最省事的是**「纯文件包」**：无 `PKG_SOURCE`、`Build/Compile` 留空、直接从 `./files/` 安装。
   参考树内现成模板：`package/firmware/<某 firmware 包>/Makefile`。
3. **包用构建树的 `private-key.pem` 签名**，设备信任配套的 `public-key.pem` ⇒ 安装时**不需要**
   `--allow-untrusted`（前提：设备刷的就是这棵树编的镜像）。
4. 免被坑的前提：**你改的是构建树**，所以能直接借用它的交叉工具链
   `staging_dir/toolchain-*/bin/<triple>-gcc`（triple 形如 `aarch64-openwrt-linux-musl`）。

## 流程

### 1. 摸清上游构建（只读）
- 语言/构建系统、**产物是否是"单文件"**（前端是否被 `include_dir!`/`embed` 之类编译期嵌入）。
- 需要哪些工具链与版本（`packageManager`、`rust-toolchain`、CI workflow 里的平台配方）。
- 依赖里有没有 C 代码（`*-sys` crate、cgo、node-gyp）⇒ 决定必须给 target 设 `CC`。
- 抄 CI 的交叉编译 env（最可靠）：例如 rust musl target 的
  `CC_<target> / AR_<target> / RUSTFLAGS="-Clink-self-contained=yes -Clinker=rust-lld"`。

### 2. 前端（如果有，且被嵌入）
```bash
corepack enable            # 或直接 corepack pnpm ...
corepack pnpm install --frozen-lockfile --registry=https://registry.npmmirror.com
corepack pnpm run build    # 产物目录要按上游代码里的 include_dir! 路径来，别猜
```

### 3. 交叉编译 → 静态 aarch64-musl
Rust（rustup 在宿主机装，只写 `~/.rustup`/`~/.cargo`；国内用 tuna 镜像）：
```bash
export RUSTUP_DIST_SERVER=https://mirrors.tuna.tsinghua.edu.cn/rustup
export RUSTUP_UPDATE_ROOT=https://mirrors.tuna.tsinghua.edu.cn/rustup/rustup
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path
rustup target add aarch64-unknown-linux-musl

TC=$TOPDIR/staging_dir/toolchain-<...>_musl/bin
export CC_aarch64_unknown_linux_musl=$TC/aarch64-openwrt-linux-gcc
export AR_aarch64_unknown_linux_musl=$TC/aarch64-openwrt-linux-ar
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=$TC/aarch64-openwrt-linux-gcc
cargo build --locked --release --target aarch64-unknown-linux-musl
```
**判据**：`file` 说 `ELF 64-bit LSB executable, ARM aarch64, statically linked`；`ldd` 说
"不是动态可执行文件"（或 not a dynamic executable）。

### 4. strip + 放进包目录
```bash
$TC/aarch64-openwrt-linux-strip -s -o package/<name>/files/<name> <编译产物>
```

### 5. 写 `package/<name>/Makefile`（纯文件包模板，逐字可用）
```make
include $(TOPDIR)/rules.mk
PKG_NAME:=<name>
PKG_VERSION:=<ver>
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=...
PKGARCH:=all            # 纯文件/脚本包 ⇒ arch:noarch，任何架构都能装（跨架构复用同一颗 apk）
include $(INCLUDE_DIR)/package.mk

define Package/<name>
  SECTION:=net
  CATEGORY:=Network
  TITLE:=...
  URL:=...
endef

define Build/Compile
endef

define Package/<name>/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/<name> $(1)/usr/bin/<name>
endef

$(eval $(call BuildPackage,<name>))
```
> Makefile 顶部写清"二进制怎么来的"（上游 URL + tag + 交叉编译命令），否则以后没人能复现。
> **`define Build/Compile` / `endef` 这两行不能省**（哪怕里面什么都不写）：没有源码时若不定
> `Build/Compile`，默认规则会去 `make -C $(PKG_BUILD_DIR)`，直接报
> `No targets specified and no makefile found` 让构建失败。
> 主构建里如果带 `IGNORE_ERRORS=m`，这个失败会被当"可忽略"**静默放过** —— apk 不产出，
> 但 make 返回 0，很容易误判成"编好了"。单包编译验证是必须的。

**变体：包的脚本要"接管"另一个包的文件时**（例如用自己版本顶掉某页面的默认块），
别让包去**覆盖**同名文件（对方包一重装就前功尽弃、而且 apk 会报路径冲突）。
改成**改一个不冲突的名字/打岔**，用脚本做：

```make
define Package/<name>/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0      # 构建期装配 rootfs 也会跑，必须 guard
STOCK=/www/.../10_system.js
if [ -f "$$STOCK" ]; then cp -p "$$STOCK" "$$STOCK.disabled" && rm -f "$$STOCK"; fi
exit 0
endef

define Package/<name>/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
if [ -f "$$STOCK.disabled" ]; then cp -p "$$STOCK.disabled" "$$STOCK" && rm -f "$$STOCK.disabled"; fi
exit 0
endef
```

槽位映射：`postinst`→`post-install`（**并且构建系统会自动生成一份 `post-upgrade`**，
升级时跑的是后者，所以两个都要在 `adbdump` 里确认）、`postrm`→`post-deinstall`、
`prerm`→`pre-deinstall`。构建期只跑 `post-install`，**它返回非 0 会让 make 失败**
（`include/rootfs.mk`）—— 所以那个 `IPKG_INSTROOT` guard 是必须的，不是可选的。

### 6. 构建（**必须先净化 rm 外壳**，见 `openwrt-offline-kmod-repo` 的坑 1）
```bash
unset -f rm unlink rmdir; unset CODEBUDDY_SESSION_ID CLAUDE_SESSION_ID CODEBUDDY_SAFE_DELETE_ENABLED
export PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v 'shim/safe-bin' | paste -sd:)
export STAGING_DIR=$TOPDIR/staging_dir
make package/<name>/compile V=s
```

### 7. 验证（离线）
```bash
A=$TOPDIR/staging_dir/host/bin/apk
$A adbdump bin/packages/<arch>/base/<name>-<ver>-r1.apk   # 元数据 + 每个路径 + "data block, size: …" + sig 块
```
- 元数据要看：`arch`（应为你目标的 arch）、`depends`、`installed-size`、`paths`；
- **`# data block, size: N`** 要与你的文件大小对上（OpenWrt 会再 strip 一次，可能小几十/几百字节）；
- 有 `# sig …` 行 = 已签名 ✔（`UNTRUSTED` 只是 adbdump 没给密钥，不代表没签）。
- **host apk 是精简版**：没有 `--initdb`，装不进假根，别指望它验内容；只能靠上面这些 + `file`/`strings` 判据。

> ⚠️ **写门禁脚本时注意 `paths:` 的文件名是"相对父目录"的**（嵌在父目录的 `files:` 下面）：
>
> ```
> paths: # 15 items
>   - name: usr/sbin
>     files: # 1 items
>       - name: 515xg-connstat     ← 不是 usr/sbin/515xg-connstat
> ```
>
> 所以 `grep '^  - name: usr/sbin/515xg-connstat$'` **永远匹配不到**，写出来的门禁会报假 FAIL。
> 正规做法是先按父目录前缀拼回全路径，且**先匹配 6 空格（文件条目）再匹配 2 空格（目录条目）**：
>
> ```sh
> awk '/^      - name: / { sub(/^      - name: /,""); print dir "/" $0; next }
>      /^  - name: /     { sub(/^  - name: /,""); dir=$0 }' dump.txt | sort
> ```
>
> 更狠的离线比对（强烈建议加进门禁）：`apk extract <apk>` 到一个空目录，
> 再与源文件**逐字节 `cmp`**；顺便用 `apk --keys-dir <含 public-key.pem 的目录> verify <apk>`
> 验签（匹配 `: OK`，**注意不给 keys-dir 时退出码也是 0**，只看退出码会误判）。
> 还有一个反向判据很好用：**断言包内"不含"某个不该带的路径**（防自己不小心把别人的文件打进去了）。

### 8. 给包加 procd 服务 + LuCI 界面（让它在网页里能开关）

**先决定包结构**：
- 想要「一个 apk 装完就有界面」→ **单包**：包名可以就叫 `<name>`，界面文件放对位置即可，
  LuCI 不要求包名是 `luci-app-*`（只认 `menu.d` 里的 `acl` 组名）。`DEPENDS:=+libc +luci-base`。
- 想要「命令行版 / 界面版分开」→ 双包（`<name>` + `luci-app-<name>`），界面包用
  `include $(TOPDIR)/feeds/luci/luci.mk`（本树先例：`feeds/pon_userspace/luci-app-pon`），
  它会自动装 `root/`、`htdocs/`、`menu.d`、`acl.d` 并处理 i18n。

**包内目录用 `root/`（语义 = 以 / 为根）**，Makefile 逐条 `INSTALL_*`：

```makefile
define Package/<name>/conffiles
/etc/config/<name>
endef

define Package/<name>/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/<bin> $(1)/usr/bin/<bin>
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/<name> $(1)/etc/init.d/<name>    # 必须 INSTALL_BIN → 0755
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/<name> $(1)/etc/config/<name>  # INSTALL_CONF → 0600（OpenWrt 惯例）
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/<name>
	$(INSTALL_DATA) ./root/www/luci-static/resources/view/<name>/main.js $(1)/www/luci-static/resources/view/<name>/main.js
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-<name>.json $(1)/usr/share/luci/menu.d/
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-<name>.json $(1)/usr/share/rpcd/acl.d/
endef
```
> **别用 `$(CP) ./root/* $(1)/`**：源文件的 644 权限会被带进去，init 脚本变不可执行、服务起不来。

**init 脚本**（模板 `package/homebox/root/etc/init.d/homebox`）：`USE_PROCD=1` +
`procd_open_instance` / `command` / `respawn 3600 5 5` / `stdout 1` / `stderr 1` / `procd_close_instance`，
外加 **`procd_add_reload_trigger "<name>"`**（决定「保存并应用」能否自动重启服务）和 `reload_service() { stop; start; }`。

**LuCI 视图**（模板 `package/homebox/root/www/luci-static/resources/view/homebox/main.js`）三个关键点：
1. 查状态用内建 ubus，**不用自己写 rpcd 脚本**：
   `rpc.declare({object:'service', method:'list', params:['name'], expect:{'':{}}})` →
   遍历 `res.<name>.instances[*]` 的 `running` / `pid`。
2. 控制用 `fs.exec_direct('/etc/init.d/<name>', ['start'|'stop'|'restart'|'enable'|'disable'])`。
3. 自启状态用 `fs.stat('/etc/rc.d/S<NN><name>')`（存在即已启用）。
   文案直接在 `_()` 里写中文 —— 没有 po 时 `_()` 返回原文，省掉 luci.mk 和翻译流程。

**menu.d**（`action.path` 相对 `/www/luci-static/resources/view/`，**不带 `.js`**）：
```json
{ "admin/services/<name>": { "title": "<Name>", "order": 65,
  "action": { "type": "view", "path": "<name>/main" },
  "depends": { "acl": [ "luci-app-<name>" ], "uci": { "<name>": true } } } }
```

**acl.d**：`read` 给 `uci:[<name>]`、`ubus:{service:['list'], file:['read','stat','exec']}`、
路径级 `file:{"/usr/bin/<bin> --version":["exec"], "/etc/rc.d/S<NN><name>":["read"]}`；
`write` 给 `uci`、`cgi-io:['exec']`、`ubus:{file:['exec']}`，以及**逐条**列出的
`file:{"/etc/init.d/<name> start":["exec"], … stop/restart/enable/disable}` ——
rpcd 按「命令+参数拼成的字符串」精确匹配，漏一条按钮就报权限不足。

**装到设备后必须 `/etc/init.d/rpcd restart`**，否则 LuCI 里看不到菜单（menu/acl 是 rpcd 启动时加载的）。

**离线验证包内容**：`adbdump` 会给每个文件记 `hash:`，与源文件 `sha256sum` **逐一对应**即可证明包内容就是你这版文件（`strings` 扫不到文本文件 —— ADB 格式会编码载荷）。

## 三个必踩的坑

### 坑 A（最坑）：包没进 `.config` 时，`make package/x/compile` 是**空操作**
症状：`make` 返回 0，日志里只有
`make[2]: Entering directory '.../package/x'` / `Leaving`，**不编译、不打包**，`bin/packages/` 里什么都没有；
同时 make 会提示 `your configuration is out of sync. Please run make menuconfig, oldconfig or defconfig!`。
修法（编完记得还原！）：
```bash
cp .config /home/<user>/.config.<proj>.before-<name>.bak
make defconfig                                   # 让新包的符号出现
sed -i 's/^# CONFIG_PACKAGE_<name> is not set$/CONFIG_PACKAGE_<name>=y/' .config
make defconfig
make package/<name>/compile V=s
# …拿到 apk 之后：
cp /home/<user>/.config.<proj>.before-<name>.bak .config && cmp -s .config <原基线>
```
> 注意：把 `CONFIG_PACKAGE_<name>=y` 留在 `.config` 里会让**下次编固件把它打进镜像**——按需决定。

### 坑 B：顶层 `host/` 目录缺失 → `prepare-tmpinfo` 失败
症状（**只有新增/改动 package Makefile 时才会触发**，改 `.config` 不会）：
```
touch: cannot touch '<TOPDIR>/host/.prereq-build': No such file or directory
make[2]: *** [include/toplevel.mk:213: <TOPDIR>/host/.prereq-build] Error 1
```
修法：`mkdir -p $TOPDIR/host`（构建产物目录，不是源码）。之后 `git status` 可能多一条 `?? host/`，
建议让用户把 `/host` 加进 `.gitignore`（别擅自改人家的 .gitignore）。

### 坑 C：打包会把文件**装进固件 rootfs 暂存**，不清就污染下次编固件
`make package/x/compile` 的 install 步骤会把文件复制到
`staging_dir/target-<...>/root-<board>/`，并写 `pkginfo/<name>*.install|.provides|.flags`、`stamp/.<name>_installed`。
只出包不想要它进固件时，编完要清：
```bash
R=staging_dir/target-<...>/root-<board>
rm -rf $R/usr/bin/<name> $R/usr/share/licenses/<name> $R/stamp/.<name>_installed
rm -f  staging_dir/target-<...>/pkginfo/<name>*.install* staging_dir/target-<...>/pkginfo/<name>*.provides
find $R -iname '*<name>*' | wc -l      # 应为 0
```
外加 `make package/<name>/clean`（会删 build_dir 与 `bin/packages/…/<name>*.apk`）
⇒ **先把 apk 拷到树外保底**（`bin/` 是 gitignore 的，且会被 clean 清掉）。

### 坑 D：装到**另一棵树**编的固件上 → `UNTRUSTED signature`（rc=99）

自编 apk 用**本树** `private-key.pem` 签名，其配对公钥 `public-key.pem` 是**本树固件**在
构建时放进设备 `/etc/apk/keys/` 的。所以天然信任只存在于**本树编的固件**。
往别的固件（厂商固件、发行版官方快照、另一台设备）上装，必然被拒：

```
ERROR: /tmp/<name>-<ver>-r1.apk: UNTRUSTED signature      # rc=99
```

**判据 —— 先比钥匙，别猜**：
```bash
sha256sum <本树>/public-key.pem                  # 本树公钥
ssh root@<dev> 'sha256sum /etc/apk/keys/*.pem'   # 设备信任的钥匙（官方固件有两三把 *-snapshots.pem）
```
两串不等 ⇒ 就是签名问题，与包本身无关（架构 `noarch`、依赖、路径冲突都可排除）。

**三种解法 + 命令矩阵**（2026-09-28 在 apk-tools 3.0.5 / aarch64 上实测；
拿 `--keys-dir <空目录>` 模拟"设备没有本树钥匙"的机器）：

| 写法 | 结果 |
|---|---|
| `apk --keys-dir /tmp/nokeys add /tmp/<name>.apk` | ✘ `ERROR: …: UNTRUSTED signature` **rc=99** |
| `apk … add --allow-untrusted /tmp/<name>.apk` | ✔ **rc=0**（写在 applet 选项位） |
| `apk --allow-untrusted … add /tmp/<name>.apk` | ✔ **rc=0**（写在全局选项位也行，两种位置都吃） |
| `apk --keys-dir /tmp/konly add …`（`konly/` 里**只有**本树公钥） | ✔ rc=0 但 **6 行 UNTRUSTED WARNING** |
| `apk --keys-dir /tmp/kboth add …`（`kboth/` = `cp /etc/apk/keys/*.pem` + 本树公钥） | ✔ rc=0、**0 告警** ← 最佳折中 |

1. **一次性忽略签名**：`apk add --allow-untrusted /tmp/<name>.apk`
2. **不动设备又保留验签**（推荐折中）—— 临时钥匙目录里**同时**放官方钥匙和本树公钥：
   ```bash
   scp -O <本树>/public-key.pem <本树>/<name>.apk root@<dev>:/tmp/
   ssh root@<dev> 'mkdir -p /tmp/kboth && cp /etc/apk/keys/*.pem /tmp/kboth/ \
     && cp /tmp/public-key.pem /tmp/kboth/ \
     && apk --keys-dir /tmp/kboth add --simulate /tmp/<name>.apk'   # 去掉 --simulate 即真装
   ```
3. **一劳永逸**：把本树公钥拷进设备 keys 目录 —— **用新文件名，绝不覆盖现有的**：
   `scp -O <本树>/public-key.pem root@<dev>:/etc/apk/keys/<yourname>.pem`

⚠️ **三个坑**：

* **`--keys-dir` 是「替换」不是「追加」**：只放本树公钥时，官方源的索引会立刻变成不可信
  （实测 6 行 UNTRUSTED WARNING）。所以临时钥匙目录必须把 `/etc/apk/keys/*.pem` 一起拷进去。
* **这个版本没有配置文件开关**：`apk --config` → `unrecognized option 'config'`；
  设备上也没有 `/etc/apk/apk.conf`、`/etc/config/` 里也没有 apk 条目。
  ⇒ 想少打字只能写 shell alias / 小脚本，别指望配置项。
* **`--allow-untrusted` 只解决签名**，不解决依赖（缺 `luci-mod-status` 之类仍会失败 —— 它会去
  对方自己的源找，源里没有就报缺包），也**只在本次生效**、不会让以后的装包放行
  （`apk add --help` 原文：*Install packages with untrusted signature or no signature*）。

**跳过签名 = 放弃完整性保证** ⇒ 把 `sha256` 跟包一起给对方核对（这就是签名本来要干的活）。
实测 OpenWrt busybox **带 `sha256sum`**（`/usr/bin/sha256sum -> ../../bin/busybox`，设备端可直接算；
注意 `busybox | grep sha` 是**看不到**它的，别据此判定"没有"）。

另外：设备不认本树钥匙，反过来也一样（本树固件不认官方包的签名）—— 别把"装不上"当包坏了。

#### 答「我在网上下载别人的 apk 都能装，凭什么这个要认公钥」——两套模型，别混

**Android 的 `.apk` ≠ OpenWrt 的 apk。** 前者**自签名**，后者是**预置信任锚**：

| | Android `.apk` | OpenWrt apk / deb / rpm / Alpine apk |
|---|---|---|
| 签名给谁看 | 自己（自洽） | **本机密钥库** |
| 系统查什么 | 签名有效 + 与同包名已装应用**同一把钥匙**（只为防替换） | 签名者是否在 `/etc/apk/keys/` 之类的库里 |
| 签名者是谁 | 无所谓 ⇒ 任何开发者的包都能装 | 决定性 ⇒ 不在库里就 `UNTRUSTED`（rc=99） |
| 装别家源要做什么 | 什么都不用 | **导入该源的公钥**（=`rpm --import` / `apt-key add` / `pacman-key --add`） |

另一个常见经验来源：**老 OpenWrt 的 opkg `check_signature` 默认关**，那时网上下的第三方
`.ipk` 直接能装。换成 **apk-tools 3 后验签默认强制** ⇒ 这是**换代行为变化**，不是某个包特殊。

**为什么不能像 Android 那样只看自洽**：包从网络源下载，机器无法区分"开发者自签名"和
"攻击者自签名"。若只看自洽，任何能在下载路径上替换包的人（DNS 劫持、被控镜像、中间人）
都能让你装上后门且你察觉不到。**只有预置的钥匙能提供来源保证** —— 这就是"本树固件天生认本树包"
（构建时把 `public-key.pem` 装进 `/etc/apk/keys/`）的全部意义；换台设备就得显式加一把。

**`--allow-untrusted` 的语义**：不是"绕过检查"，是"我**已自行确认**这份包的字节没被篡改，
照样装"（典型场景：刚用 `scp` 当面拷过来的文件）。动设备前先 `--simulate` 试，别直接落盘。

## 交付话术（设备端）
```bash
scp <name>-<ver>-r1.apk root@<dev>:/tmp/
ssh root@<dev> 'apk add /tmp/<name>-<ver>-r1.apk'      # 若设备信任本树公钥，无需 --allow-untrusted
ssh root@<dev> '<name>…'                                # 或 /etc/init.d/<name> start（若包内带 init 脚本）
```
没有 procd 自启脚本时，用户得手动起（或后续再加 `/etc/init.d/<name>` + `/etc/config/<name>`）。

## 常见注意
- **设备是 aarch64 时不要用 `*-unknown-linux-gnu`**（glibc 解释器在 OpenWrt 上不存在）——必须 musl。
- 静态 musl 二进制动辄几 MB；设备 `/overlay` 空间要确认（`df -h /overlay`）。
- 想让它以后 `apk add <name>` 直接装，就把产物放进设备本地源目录并**重建索引**（见
  `openwrt-offline-kmod-repo` 的 `build-repo.sh`；注意那个脚本默认只收 `kmod-*.apk`，要给它加收别的包）。
- 交付前把 `apk adbdump` 的元数据、`file`、sha256 一起给用户；有 init 脚本就顺带给一句"怎么起"。
