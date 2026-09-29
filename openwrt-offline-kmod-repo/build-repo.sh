#!/bin/bash
# 从 OpenWrt 构建树收集 .apk，生成**已签名**的 apk 索引（apk 3 的 packages.adb）
#
# 用法: build-repo.sh <openwrt树> <输出目录> [--with-kernel]
#   --with-kernel  额外把 kernel-*.apk 也放进去（默认不放：内核已装在设备上，
#                  其依赖由"已安装的 kernel 包"满足，放进去反而多一个可替换项）
#
# 环境变量:
#   EXTRA_PKGS="daed daed-geoip luci-app-daed"   额外收进来的**非 kmod** 包名单
#
# 要点:
#   * bin/targets/<board>/<sub>/packages/ 里是**真实文件**；staging_dir/packages/<board>/
#     里是软链，从那里拷必须 cp -L。
#   * ⚠️ **非 kmod 的 arch 包不在上面那个目录里**：它们落在
#     bin/packages/<arch>/<feed>/（如 daed → bin/packages/aarch64_cortex-a53/packages/、
#     luci-app-daed → .../luci/）。kmod 才是 target 级的。混放没关系——apk 索引里
#     两者可以共存，设备上一条源就能同时补齐 kmod 依赖和普通包。
#   * 索引必须只覆盖"实际拷进本目录的那批包"——绝不能用构建系统生成的
#     staging_dir/packages/<board>/packages.adb（它覆盖全部包，apk 会去找不存在的文件）。
#   * 必须用**构建这棵树时生成的那把 private-key.pem** 签名：镜像里 /etc/apk/keys/
#     装的是配对的 public-key.pem，用别的钥匙签就变成 UNTRUSTED。
#   * 建完索引会**检测"空壳包"**并单独列出：某些 kmod 的内核选项在这份内核配置里最终
#     是 =y（编进内核、不产 .ko）或压根没生效，于是包只有几百字节、装上去也没有模块
#     （kmod-nls-base / kmod-thermal / kmod-nf-log6 长期如此；kmod-ifb 在 6.18 上因
#     CONFIG_NET_CLS_ACT 没被拉起而编不出 ifb.ko）。**空壳不要删**——它们常被别的包
#     当依赖锚点（如 kmod-crypto-kpp 被 kmod-crypto-lib-curve25519 依赖），删了会让
#     依赖解析失败。只报告，不剔除。
set -euo pipefail

TREE=${1:?用法: $0 <openwrt树> <输出目录> [--with-kernel]}
OUT=${2:?用法: $0 <openwrt树> <输出目录> [--with-kernel]}
APK="$TREE/staging_dir/host/bin/apk"
PKGS="$TREE/bin/targets/airoha/an7581/packages"

[ -x "$APK" ]                || { echo "✘ 找不到 $APK（先在这个树里编译过）"; exit 1; }
[ -f "$TREE/private-key.pem" ] || { echo "✘ 找不到 $TREE/private-key.pem"; exit 1; }
[ -d "$PKGS" ]               || { echo "✘ 找不到 $PKGS"; exit 1; }

n=$(ls "$PKGS"/kmod-*.apk 2>/dev/null | wc -l)
[ "$n" -gt 0 ] || { echo "✘ $PKGS 里没有 kmod-*.apk"; exit 1; }
echo "== 找到 $n 个 kmod 包 =="

mkdir -p "$OUT"
rm -f "$OUT"/*.apk "$OUT"/packages.adb
cp -L "$PKGS"/kmod-*.apk "$OUT"/
[ "${3:-}" = "--with-kernel" ] && cp -L "$PKGS"/kernel-*.apk "$OUT"/ || true

# ---------------------------------------------------------------- 额外 arch 包
# daed / luci-app-daed 这类包**不在** targets/<board>/<sub>/packages/ 里，
# 而在 bin/packages/<arch>/<feed>/ 下（kmod 才是 target 级的）。这里把它们一并收进来。
if [ -n "${EXTRA_PKGS:-}" ]; then
	echo
	echo "== 额外收进非 kmod 的 arch 包（EXTRA_PKGS）=="
	NE=0; MISS=""
	for p in $EXTRA_PKGS; do
		f=""
		for c in "$TREE"/bin/packages/*/*/"$p"-*.apk; do
			[ -e "$c" ] || continue
			if [ -z "$f" ] || [ "$c" -nt "$f" ]; then f=$c; fi
		done
		if [ -n "$f" ]; then
			cp -L "$f" "$OUT"/
			printf '  + %-46s %s B\n' "$(basename "$f")" "$(stat -c%s "$f")"
			NE=$((NE+1))
		else
			printf '  ✘ 找不到 %s 的 apk\n' "$p"
			MISS="$MISS $p"
		fi
	done
	echo "  共收 $NE 个"
	# 缺了不直接死——有时只是想先建 kmod 源；但必须显式喊出来，否则设备上
	# apk 解析 daed 的依赖时会报"所有仓库都未提供"。
	[ -n "$MISS" ] && echo "  ⚠ 以下包没进索引，设备上装的时候会缺依赖:$MISS"
fi

cd "$OUT"
"$APK" mkndx --root "$TREE" --keys-dir "$TREE" --allow-untrusted \
       --sign "$TREE/private-key.pem" --output packages.adb *.apk

echo "== 结果 =="
echo "包数: $(ls "$OUT"/*.apk | wc -l)"
echo "体积: $(du -sh "$OUT" | cut -f1)"
echo "索引: $(stat -c%s "$OUT/packages.adb") B"
echo -n "索引里的内核绑定: "
"$APK" adbdump "$OUT/packages.adb" | grep -o 'kernel=[0-9.]*~[0-9a-f]*' | sort -u | tr '\n' ' '
echo
echo "（应与本树 bin/targets/airoha/an7581/packages/kernel-*.apk 文件名里的 hash 完全一致）"

echo
echo "== 空壳包检测（仅 kmod-*：installed-size < 20 字节 ⇒ 内核没编出 .ko） =="
"$APK" adbdump "$OUT/packages.adb" \
| awk '/^  - name: /{ if (n != "") print n, sz; n=$3; sz=0 }
       /installed-size: /{ sz=$2 }
       END{ if (n != "") print n, sz }' \
| awk '$1 ~ /^kmod-/ { if ($2 < 20) { printf "  ⚠ %s  (installed-size=%s)\n", $1, $2; h++ } n++ }
       END{ if (!h) print "  （无）"; else printf "  共 %d 个空壳 / kmod 总数 %d\n", h, n }'
echo "  注：空壳不要删——它们常被别的包当依赖锚点，删了会导致依赖解析失败。"
echo "  注：非 kmod 包（daed 之类）不参与空壳判定，它们的 installed-size 本来就小。"
