#!/bin/bash
# verify-kmod-image.sh —— 交付/刷机前的离线门禁（专治"刷了就死"的镜像）
#
# 用法:
#   verify-kmod-image.sh <构建树> --since <时间戳或文件> [--image <itb>] \
#       [--expect-pkgs 191] [--expect-kmods 70] [--expect-ver '6.18.52~<hash>-r1'] \
#       [--old-offset 0x444] [--module airoha-xpon] [--expect-kmods-dir 1192]
#
# --since  : "内核配置最后一次发生实质变更"的时刻。**建议直接给改配置前备份的 .config 路径**
#            （例：--since /home/wen/.config.zn515xg.p1.bak）。镜像里每个 .ko 都必须比它新。
# --old-offset / --module : 可选，偏移门禁。若某模块曾用旧结构体偏移，检查它现在是否已改掉。
# --expect-kmods-dir N : 可选，镜像**有意内嵌**本地 kmod 仓库时用。断言 /www/kmods 存在、
#                        内含 N 个 .apk、packages.adb 非空，且 customfeeds.list 指向本地源。
#                        不给这个参数时，/www/kmods 存在只会打一条「注意」不算失败。
#
# 为什么需要它：内核配置一变（例如开 CONFIG_ALL_KMODS），内核自带模块会被 kbuild 重编，
# 但**外部 kmod 包**（feeds/*、package/kernel/*）可能"看起来编过了、其实是旧字节"，
# 于是模块用旧的结构体偏移去锁新内核的字段 → probe 自旋死等、开机卡死。
# 详细机理见 SKILL.md「坑 5」。
set -uo pipefail

TREE=${1:?用法: verify-kmod-image.sh <构建树> --since <时间|文件> [...]}; shift
SINCE=""; IMAGE=""; ROOTIN=""; EXPECT_PKGS=""; EXPECT_KMODS=""; EXPECT_VER=""; OLD_OFFSET=""; MODULE=""
EXPECT_KMODS_DIR=""
while [ $# -gt 0 ]; do
	case "$1" in
		--since) SINCE=$2; shift 2 ;;
		--image) IMAGE=$2; shift 2 ;;
		--root) ROOTIN=$2; shift 2 ;;   # 直接给已解包的 rootfs 目录（自测/回归用）
		--expect-pkgs) EXPECT_PKGS=$2; shift 2 ;;
		--expect-kmods) EXPECT_KMODS=$2; shift 2 ;;
		--expect-ver) EXPECT_VER=$2; shift 2 ;;
		--old-offset) OLD_OFFSET=$2; shift 2 ;;
		--module) MODULE=$2; shift 2 ;;
		--expect-kmods-dir) EXPECT_KMODS_DIR=$2; shift 2 ;;
		*) echo "未知参数: $1" >&2; exit 2 ;;
	esac
done
[ -n "$SINCE" ] || { echo "必须给 --since（改配置前备份的 .config 路径最方便）" >&2; exit 2; }
[ -e "$SINCE" ] && SINCE=$(stat -c %Y "$SINCE")

cd "$TREE"
PASS=0; FAIL=0
ok()   { echo "  ✔ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✘ $*"; FAIL=$((FAIL+1)); }
note() { echo "  · $*"; }

SD=$(dirname "$(readlink -f "$0")")
MK=$(ls staging_dir/host/bin/mkimage 2>/dev/null | head -1)
TC=$(ls -d staging_dir/toolchain-*/bin 2>/dev/null | head -1)
OD=$TC/aarch64-openwrt-linux-musl-objdump

[ -n "$IMAGE" ] || IMAGE=$(ls -t bin/targets/*/*/*squashfs-sysupgrade.itb 2>/dev/null | head -1)
echo "=== 门禁 0：镜像 ==="
if [ -n "$ROOTIN" ]; then
	note "已指定 --root，跳过镜像文件检查（用于回归自测）"
elif [ -n "$IMAGE" ] && [ -f "$IMAGE" ]; then
	note "$(basename "$IMAGE")  $(stat -c%s "$IMAGE") B  $(stat -c%y "$IMAGE" | cut -c1-16)"
	sha256sum "$IMAGE" | sed 's/^/  · sha256 /'
else
	bad "找不到 sysupgrade 镜像"; echo "FAIL=$FAIL PASS=$PASS"; exit 1
fi

echo "=== 门禁 1：FIT 里是不是"正常内核"（防 initramfs 陷阱）==="
if [ -z "$IMAGE" ] || [ ! -f "$IMAGE" ]; then
	note "没有镜像文件，跳过"
elif [ -n "$MK" ]; then
	KSZ=$($MK -l "$IMAGE" 2>/dev/null | awk '/Image 0 \(kernel/{f=1} f&&/Data Size/{print $3; exit}')
	[ -n "$KSZ" ] || KSZ=0
	if [ "$KSZ" -gt 8000000 ]; then
		bad "FIT 内核 ${KSZ} B（过大）⇒ 很可能踩了 initramfs 趟次陷阱：touch .config && rm -f build_dir/*/linux-*/Image 后重编"
	else
		ok "FIT 内核 ${KSZ} B（正常量级）"
	fi
else
	note "没有 mkimage，跳过"
fi

echo "=== 门禁 2：镜像内容 ==="
WORK=$(mktemp -d)
if [ -n "$ROOTIN" ]; then
	ROOT=$ROOTIN
	ok "使用外部 rootfs：$ROOTIN"
else
	python3 "$SD/carve-squashfs.py" "$IMAGE" "$WORK/rootfs.sqfs" >/dev/null 2>&1 || bad "抠 squashfs 失败"
	unsquashfs -f -d "$WORK/root" -q "$WORK/rootfs.sqfs" >/dev/null 2>&1
	ROOT=$WORK/root
	[ -d "$ROOT/lib" ] && ok "squashfs 解包完成（$(find "$ROOT" | wc -l) 条目）" || bad "解包失败"
fi

NP=$(grep -c '^P:' "$ROOT/lib/apk/db/installed" 2>/dev/null)
NK=$(grep -c '^P:kmod-' "$ROOT/lib/apk/db/installed" 2>/dev/null)
KV=$(grep -A1 '^P:kernel$' "$ROOT/lib/apk/db/installed" 2>/dev/null | tail -1 | cut -c3-)
note "已装包 $NP / kmod $NK / 内核 $KV"
[ -n "$EXPECT_PKGS" ] && { [ "$NP" = "$EXPECT_PKGS" ] && ok "包数 = $EXPECT_PKGS" || bad "包数 $NP ≠ 期望 $EXPECT_PKGS"; }
[ -n "$EXPECT_KMODS" ] && { [ "$NK" = "$EXPECT_KMODS" ] && ok "kmod 数 = $EXPECT_KMODS" || bad "kmod 数 $NK ≠ 期望 $EXPECT_KMODS"; }
[ -n "$EXPECT_VER" ] && { [ "$KV" = "$EXPECT_VER" ] && ok "内核版本串一致" || bad "内核版本串不符：$KV"; }
[ -e "$ROOT/etc/apk/keys/public-key.pem" ] && cmp -s "$ROOT/etc/apk/keys/public-key.pem" public-key.pem \
	&& ok "镜像内公钥 = 本树 public-key.pem" || bad "公钥缺失或与树不一致"
if [ -n "$EXPECT_KMODS_DIR" ]; then
	# 内嵌仓库场景：显式断言 /www/kmods 存在、apk 个数、索引非空
	if [ ! -d "$ROOT/www/kmods" ]; then
		bad "/www/kmods 不存在（期望内嵌 $EXPECT_KMODS_DIR 个 apk）"
	else
		NAPK=$(ls "$ROOT"/www/kmods/*.apk 2>/dev/null | wc -l)
		[ "$NAPK" = "$EXPECT_KMODS_DIR" ] && ok "/www/kmods 内嵌 $NAPK 个 apk" \
			|| bad "/www/kmods apk 数 $NAPK ≠ 期望 $EXPECT_KMODS_DIR"
		if [ -s "$ROOT/www/kmods/packages.adb" ]; then
			ok "/www/kmods/packages.adb 存在（$(stat -c%s "$ROOT/www/kmods/packages.adb") B，md5 $(md5sum "$ROOT/www/kmods/packages.adb" | cut -c1-16)…）"
		else
			bad "/www/kmods/packages.adb 缺失或为空 ⇒ 本地源不可用"
		fi
	fi
	[ -s "$ROOT/etc/apk/repositories.d/customfeeds.list" ] \
		&& grep -q '^http' "$ROOT/etc/apk/repositories.d/customfeeds.list" \
		&& ok "customfeeds.list 含本地源：$(grep -m1 '^http' "$ROOT/etc/apk/repositories.d/customfeeds.list")" \
		|| bad "customfeeds.list 缺失或无 http 源"
elif [ -d "$ROOT/www/kmods" ]; then
	note "注意：镜像里已存在 /www/kmods（若非有意内嵌，请查证）"
else
	ok "/www/kmods 未被预置（符合预期）"
fi

echo "=== 门禁 3：模块新鲜度（镜像里的 .ko 必须 = 最新打包副本，且晚于 --since）==="
# 关键：镜像里的模块是 **strip 过** 的，只有"打包后副本"才有资格逐字节比较。
# 只按文件名比时间戳会漏判——构建目录里可能已有新的同名产物，而镜像里装的是旧的。
IDX=$WORK/ko.idx
find build_dir/*/linux-* -name '*.ko' \( -path '*ipkg-*' -o -path '*.pkgdir*' \) \
	-printf '%T@ %TY-%Tm-%Td_%TH:%TM %p\n' 2>/dev/null > "$IDX"
NSTALE=0; NTOT=0; NOK=0
for f in "$ROOT"/lib/modules/*/*.ko; do
	[ -f "$f" ] || continue
	n=$(basename "$f"); NTOT=$((NTOT+1))
	best=$(grep -E "/$n\$" "$IDX" | sort -rn | head -1)
	if [ -z "$best" ]; then note "未找到打包副本（跳过）：$n"; continue; fi
	p=$(echo "$best" | awk '{print $3}')
	ts=$(echo "$best" | awk '{print $1}')
	if cmp -s "$p" "$f"; then
		NOK=$((NOK+1))
		if [ "$(printf '%.0f' "$ts")" -lt "$SINCE" ]; then
			bad "打包副本本身早于 --since：$n （$(echo "$best" | awk '{print $2}')）"
			NSTALE=$((NSTALE+1))
		fi
	else
		bad "陈旧模块：$n 与最新打包副本不一致（镜像 $(stat -c%s "$f") B vs 成品 $(stat -c%s "$p") B，成品 $(echo "$best" | awk '{print $2}')）"
		NSTALE=$((NSTALE+1))
	fi
done
[ "$NSTALE" -eq 0 ] && ok "镜像里 $NTOT 个 .ko 全部 $( [ "$NOK" = "$NTOT" ] && echo '与最新打包副本逐字节一致' )（无陈旧模块）"

echo "=== 门禁 4：结构体偏移一致性（可选）==="
if [ -n "$OLD_OFFSET" ] && [ -n "$MODULE" ] && [ -n "$OD" ]; then
	f=$(ls "$ROOT"/lib/modules/*/"$MODULE".ko 2>/dev/null | head -1)
	if [ -n "$f" ]; then
		n_old=$($OD -d "$f" 2>/dev/null | grep -c "add\s*x[0-9]*, x[0-9]*, #$OLD_OFFSET")
		if [ "$n_old" -eq 0 ]; then ok "$MODULE.ko 已无旧偏移 $OLD_OFFSET"
		else bad "$MODULE.ko 仍含旧偏移 $OLD_OFFSET（$n_old 处）⇒ 模块与内核布局不一致"; fi
	else
		note "镜像里没有 $MODULE.ko，跳过"
	fi
fi

rm -rf "$WORK"
echo
echo "===== 结果：PASS=$PASS  FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ] || echo "⚠ 有 FAIL，别刷：先按提示修，再重跑本门禁。"
exit $(( FAIL > 0 ? 1 : 0 ))
