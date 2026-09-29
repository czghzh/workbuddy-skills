---
name: openwrt-firmware-defaults
description: 改 OpenWrt / ImmortalWrt 固件的「出厂默认项」——LuCI 默认主题、WiFi 国家代码（regulatory domain）、信道宽度 htmode、默认 SSID/时区/root 密码等，并且要**编进镜像**而不是刷完手改。适用于「默认主题改回 bootstrap / 删掉 argon」「wifi 国家代码改成中国 CN」「5G 通道宽度改成 160MHz」「默认 SSID」「出厂默认不生效」「/etc/config/wireless 里 country 是空」「htmode 只有 HE80」「改了默认值但刷完没变化」这类需求。内含三处权威定义位置（主题包的 uci-defaults、board.d 的 ucidef_set_country、wifi-scripts 的 mac80211.uc）、默认值的覆盖优先级链、以及「不刷机就能验证镜像里对不对」的离线抠包办法。
agent_created: true
---

# 改 OpenWrt 固件的出厂默认项

## 什么时候用

- 用户要「默认主题改成 X」「wifi 国家代码改成中国」「5G 带宽改成 160MHz」「默认 SSID 改成 X」
  「时区/密码出厂就设好」——即**刷完机第一次开机就该是那样**，不是刷完手动改。
- 反过来的症状：**改过了但刷完没生效**、`/etc/config/wireless` 里 `option country ''` 是空、
  5G 只有 HE80、LuCI 进去是别的主题。

## 总原则：先找出「这个值是谁写进去的」

同一个默认值往往有三条来源，**先 grep 定位，再决定删还是改**：

| 来源 | 什么时候执行 | 典型路径 |
| --- | --- | --- |
| ① 包自带的默认 conffile | 装包时（编进镜像就带着） | `/etc/config/luci`、`/etc/config/wireless` |
| ② 包的 `uci-defaults` 脚本 | **首次启动**（`/etc/board.d` 之后、wifi 起来之前） | `package/*/files/root/etc/uci-defaults/30_xxx` |
| ③ `board.d` 脚本 | 首次启动很早，生成 `/etc/board.json` | `target/linux/<t>/base-files/etc/board.d/NN_xxx` |

grep 例子：`grep -rn "mediaurlbase" feeds/ package/ target/`、
`grep -rn "ucidef_set_country" .`。
**别猜**——同一棵树里两处写同一个值是常态，优先级按上面的 ③→②→① 反向（越靠后启动的越"最终"）。

## 各项默认值的权威位置

### 1) LuCI 默认主题

- 真正的开关 = `/etc/config/luci` 里 `luci.main.mediaurlbase`。
- `luci-base` 自带的默认 conffile **本来就是** `option mediaurlbase '/luci-static/bootstrap'`。
- 所以「默认主题是 argon」这类现象，**几乎都是主题包自己的 `uci-defaults` 抢的**：
  `feeds/luci/themes/luci-theme-argon/root/etc/uci-defaults/30_luci-theme-argon`
  ```sh
  if [ "$PKG_UPGRADE" != 1 ]; then
      uci get luci.themes.Argon >/dev/null 2>&1 || \
      uci batch <<-EOF
          set luci.themes.Argon=/luci-static/argon
          set luci.main.mediaurlbase=/luci-static/argon
          commit luci
      EOF
  fi
  ```
- ⇒ **删掉那个主题包就够了**，不用另写配置。配置文件里写显式一行压住 Kconfig 默认：
  `# CONFIG_PACKAGE_luci-theme-argon is not set`（见「坑」第 2 条）。
- bootstrap 自己的 `30_luci-theme-bootstrap` 只注册 `luci.themes.Bootstrap*`，
  且**仅在 `mediaurlbase` 没设过时才**补 `/luci-static/bootstrap` ⇒ 双保险。
- ⚠️ 注意 `luci-app-<theme>-config` 这类附属包也要一起 not set（否则可能把主题拉回来）。

### 2) WiFi 国家代码（regulatory domain）

消费端（生成 `/etc/config/wireless` 的地方）在
`package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc`：

```
country = board.wlan.defaults.country;     // 就这么一个来源
...
print(`set ${s}.country='${country || ''}'`);
```

生产端用 OpenWrt 官方函数 `ucidef_set_country`（定义在
`package/base-files/files/lib/functions/uci-defaults.sh`），它写进 `/etc/board.json` 的
`wlan.defaults.country`。**做法：新加一个 board.d 脚本**

```sh
#!/bin/sh
. /lib/functions/uci-defaults.sh

board_config_update

case "$(board_name)" in
myvendor,myboard)
	ucidef_set_country CN
	;;
esac

board_config_flush

exit 0
```

放到 `target/linux/<target>/base-files/etc/board.d/04_wifi`（**权限 755**，
`$PLATFORM_DIR/base-files/*` 由 `package/base-files` 的 `Package/base-files/install` 拷进 rootfs）。

为什么不用 `uci-defaults` 写 country：**board.d 在 board.json 生成期就带上值，
而 uci-defaults 跑的时候 `/etc/config/wireless` 可能还没生成**（它由 wifi 设备热插拔时的
`/sbin/wifi config` 产出）⇒ 塞 uci-defaults 会有时序/假 section 风险。

⚠️ **覆盖链**：`04_wifi` → `05_fw_defaults`（由 `package/boot/uboot-tools` 提供，
只在 U-Boot env 变量 `owrt_country` 存在时才调 `ucidef_set_country`）。而
`fw_loadenv` 要先有 `/etc/fw_env.config` 才读得到 env ⇒ **设备上没有这个文件时，
你的 CN 就是最终值**。检查：`ls /etc/fw_env.config`。

### 3) 信道宽度（htmode）

同一個 `mac80211.uc`：

```ucode
let width = band.max_width;
if (band_name == "2G")
	width = 20;
else if (width > 80)
	width = 80;          // ← 上游故意的保守默认：5G/6G 一律砍到 80
let htmode = filter(htmode_order, (m) => band[lc(m)])[0];   // 取 EHT/HE/VHT/HT
htmode += width;                                              // → "HE160"
```

`band.max_width` 是 `usr/share/hostap/wifi-detect.uc` 探测出来的：非 2G 频段里
`he_phy_cap & 0x18` ⇒ 160、`he_phy_cap & 4` ⇒ 80、否则 40/20。

⇒ 想默认 160MHz：把 `else if (width > 80) width = 80;` 改成 `> 160 → 160`。
**只放上限、不硬写 160** ——驱动只上报 80 的频段仍回落 HE80，不会生成 hostapd 起不来的配置。

⚠️ 160MHz 在 5G 会覆盖 DFS 信道（52–64），hostapd 要做 CAC；法规域（上面那条 country）
必须允许，否则频宽会被打回去。**这一项只能在设备上验证**（方法见下节「刷到设备后怎么确认真的生效」）。

#### 160MHz 落在哪几个信道 —— 由 regdb 决定，不是随便挑

实测 `country CN`（regdb 规则，`iw reg get`）：

```
country CN: DFS-FCC
	(2400 - 2483 @ 40), (N/A, 30), (N/A)      ← 2.4G 最多 40MHz
	(5150 - 5350 @ 160), (N/A, 30), (N/A)     ← ★ 唯一能凑出 160MHz 的段
	(5725 - 5850 @ 80), (N/A, 33), (N/A)      ← 5.8G 段最多 80MHz
```

160MHz = 连续 8 个 20MHz 信道 ⇒ **在 CN 法规下只有 `36/40/44/48/52/56/60/64`
凑得满**（center1 = 5250 MHz）。推论：

- 想保住 160MHz，**信道必须留在 36–64**；LuCI 里把信道改成 149/153/…（5.8G 段）
  会**静默掉回 HE80**，因为 5725–5850 只给 80MHz。
- 160MHz 必然覆盖 52–64。⚠️ **别一看到 `iw reg get` 里的 `DFS-FCC` 就以为 52–64 要 CAC**：
  那只是 regdb 的 dfs_region 标记，某条信道是否真要雷达检测看的是它有没有 `no-IR`/DFS 属性。
  实测 `iw phy phyN info` 里 5260–5320 显示 `(26.0 dBm)` 且**不带 `radar detection`**
  ⇒ 这条链路上 36–64 整段可直接起来（实测已跑满 160MHz）。判据永远是 phy 的 Frequencies 列表，
  不是 reg 的标题行。
- 别把「regdb 允许」和「驱动能力」混为一谈：`iw phy phyN info | grep -c "HE160/5GHz"`
  看的是硬件能力，`iw reg get` 看的是法规许可，**两个都通过才起得来**。

### 4) 其它出厂默认项（都在同一个函数库里）

`grep -n "^ucidef_set_" package/base-files/files/lib/functions/uci-defaults.sh` 拿到全表，常用的：

| 想要 | 函数 |
| --- | --- |
| 默认 SSID / 加密 / 密码 | `ucidef_set_wireless <2g\|5g\|6g\|all> <ssid> <enc> <key>` |
| 时区 | `ucidef_set_timezone <IANA>` |
| root 密码 | `ucidef_set_root_password_plain` / `_hash` |
| 默认 LAN 网段 | `ucidef_set_interface_lan <ip>` |
| 每频段 MAC 数 | `ucidef_set_wireless_mac_count <band> <n>` |

照第 2 条的样子放进自己的 board.d 脚本即可（一个脚本里可以设多项）。

## 改完怎么编、怎么验

**编：**

```bash
cd <tree>
# 净化 WorkBuddy 的 rm 外壳（详见 openwrt-offline-kmod-repo）
unset -f rm unlink rmdir; unset CODEBUDDY_SESSION_ID CLAUDE_SESSION_ID CODEBUDDY_SAFE_DELETE_ENABLED
export PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v 'shim/safe-bin' | paste -sd:)

make package/network/config/wifi-scripts/clean     # ← 改了它的 files/ 就必须 clean
make package/base-files/clean                      # target base-files 会因 PKG_FILE_DEPENDS 自动重编，clean 更稳
/bin/rm -rf build_dir/target-*/root-<target>       # 强制重放 rootfs
/bin/rm -f  staging_dir/target-*/stamp/.package_install
make -j$(nproc) IGNORE_ERRORS=m
```

**验（不用刷机，直接从 .itb 里抠）：**

```bash
OFF=$(python3 -c "d=open('<img>.itb','rb').read(); print(d.find(b'hsqs'))")
unsquashfs -o $OFF -cat <img>.itb etc/config/luci | grep mediaurlbase
unsquashfs -o $OFF -cat <img>.itb lib/wifi/mac80211.uc | grep -A3 "max_width"
unsquashfs -o $OFF -ls  <img>.itb | grep -c "luci-static/argon"     # 期望 0
```

（`hsqs` 是 squashfs 的 magic；`-o` 传偏移，`-cat` 直接吐文件内容。）

抠镜像只能证明「**打进去了**」，证明不了「**运行时生效了**」。刷完机要再走一遍下面这套。

## 刷到设备后怎么确认真的生效

### 0) 先确认刷的是哪一版 —— 别看文件 mtime

OpenWrt 用 `SOURCE_DATE_EPOCH` 做可复现构建 ⇒ 镜像里**所有文件的 mtime 是最近 commit 的时间**，
不是编译时刻（实测：09-29 编的镜像，新增文件 mtime 显示 `Sep 26 21:18`）。拿 mtime 判版本会误判。

靠谱判据 = **「这一版才新增的文件在不在」**：

```sh
ls -la /etc/board.d/04_wifi     # 本版才加的 board.d 脚本，在 ⇒ 就是这版或更新
apk list --installed | wc -l    # 再与交付的 .manifest 逐包比对（见下）
```

逐包比对（设备是 `name-version` 连写，manifest 是 `name - version`，**必须规范化再 comm**）：

```sh
ssh root@dev "apk list --installed | awk '{print \$1}'" | sort > /tmp/dev.pkgs
awk -F' - ' '{print $1"-"$2}' sysupgrade-xxx.manifest | sort -u > /tmp/man.pkgs
comm -23 /tmp/dev.pkgs /tmp/man.pkgs   # 设备多装的
comm -13 /tmp/dev.pkgs /tmp/man.pkgs   # 出厂有但设备缺的 —— 这一列必须为空
```

「**缺的为空 + 只有多装**」= 固件完整且是这一版。

### 1) 主题

```sh
grep mediaurlbase /etc/config/luci        # 期望 /luci-static/bootstrap
ls -1 /www/luci-static/                   # argon 不应出现
ls /etc/uci-defaults/ | grep -c argon     # 期望 0
```

### 2) country

```sh
cat /etc/board.json | grep -A4 '"wlan"'   # wlan.defaults.country = "CN"
uci show wireless | grep country          # 每个 radio 都应是 CN
logread | grep "country code"             # 运行时 netifd 会打 "Setting country code to CN"
```

第三项是**运行时**证据 —— 配置对不对是一回事，netifd 有没有真的把国家码设下去是另一回事。

### 3) htmode / 频宽（四连，缺一不可）

```sh
uci show wireless | grep htmode           # ① 配置：HE160
iw dev | grep -E "Interface|channel"      # ② 实际：width: 160 MHz
iw dev <iface> station dump               # ③ ★最强证据：客户端协商速率带 160MHz
iw reg get                                # ④ 法规：country CN 允许 5150-5350 @160
iw phy phyN info | grep "HE160"           # ⑤ 硬件能力
```

③ 才是「真生效」的铁证：客户端能以 `HE-MCS x HE-NSS 2 160MHz` 关联、速率上 2Gbps+，
说明整条链路（regdb → hostapd → 驱动 → 对端）全都接受了 160MHz。只跑 ① 或 ② 都可能自欺。

**加一道稳定性验证**：`wifi reload` 后隔十几秒再看一次 ② 和 ③，仍是 160MHz 才算稳，
免得「刚好那次起来」。

### 4) 设备上没有 bash

这些机器是 **busybox ash**，`ssh root@dev 'bash -s'` 会报 `ash: bash: not found`。
传多行脚本要用 **`sh -s`**（或直接 `ssh root@dev 'cmd1; cmd2'`）。

## 坑

1. **`/etc/config/wireless`（以及所有 `/etc/config/*` conffile）只在首次生成**。
   刷机时选**保留配置**、或者 `sysupgrade` 升级（`PKG_UPGRADE=1`），新的默认项**不会生效**。
   要么让用户不保留配置刷，要么刷后手改：
   `uci set wireless.radioX.country=CN; uci set wireless.radioX.htmode=HE160;
    uci commit wireless && wifi reload`。
2. **`make defconfig` 会把 Kconfig `default y` 的包拉回来**。删包时要写**显式否定行**
   `# CONFIG_PACKAGE_xxx is not set`（写进 `.config` 和 `configs/<board>.config` 两边），
   改完跑一遍 `make defconfig` 看它是 `No change` 还是又变回 `=y`。
3. **改了包内 `files/` 的目录，`make` 不一定重编**（stamp 不追踪 `files/`）⇒
   必须 `make package/<path>/clean`。改 target 的 `base-files/` 会自动触发（`PKG_FILE_DEPENDS`）。
4. **别只看主镜像**：initramfs/recovery 镜像里也带用户空间（LuCI 等）⇒ 改了默认项它的大小和
   sha256 也会变。交付时别漏掉它。
5. **board.d 脚本权限**：全树惯例是 755；有的树只按 `-x` 过滤执行。
6. 改了 `configs/<board>.config` 之后记得**同步 `.config`**（不同树用法不一样：
   有的树 `.config` 就是从 configs 拷的，有的树 `.config` 是精简版）。
   判据：`diff .config configs/<board>.config | wc -l` 不为 0 是正常的，别乱覆盖。
