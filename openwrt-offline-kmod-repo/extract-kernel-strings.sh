#!/bin/bash
# 从 OpenWrt 的 .itb(FIT) 里抽出内核、解压、导出字符/符号表，用于两版内核的 A/B 对比。
#
# 用法: extract-kernel-strings.sh <itb> <输出前缀>
#   产出: <输出前缀>.Image  （解压后的裸内核）
#         <输出前缀>        （排序去重后的 strings，每行一个字符串）
#
# 用途: 判断"开了 ALL_KMODS 之后，原本编进内核的驱动/子系统有没有被降级成模块或消失"。
#   OpenWrt 内核默认带 CONFIG_KALLSYMS + KALLSYMS_UNCOMPRESSED，所以裸内核里能直接
#   strings 出全部内置符号名，够做集合 A/B。
#
# 坑:
#   * FIT 里内核是 gzip 流，且可能有多段 gzip（dtb/initramfs 也可能是），
#     所以扫所有 1f 8b 08 魔数、取解压结果**最大**的那个（内核最大）。
#   * 一定要用 zlib.decompressobj(31)（31 = 自动识别 gzip/zlib 头），
#     用 decompress() 会在遇到第二段/截断时抛异常，被 except 吞掉后表现为"扫不到"。
set -euo pipefail

ITB=${1:?用法: $0 <itb> <输出前缀>}
OUT=${2:?用法: $0 <itb> <输出前缀>}

python3 - "$ITB" "$OUT" <<'PY'
import sys, zlib
itb, out = sys.argv[1], sys.argv[2]
data = open(itb, 'rb').read()
best = b''
i = 0
while True:
    i = data.find(b'\x1f\x8b\x08', i)
    if i < 0:
        break
    try:
        buf = zlib.decompressobj(31).decompress(data[i:i + 64 * 1024 * 1024])
        if len(buf) > len(best):
            best = buf
    except Exception:
        pass
    i += 1
if not best:
    print("✘ 找不到可解压的内核 gzip 流", file=sys.stderr)
    sys.exit(1)
open(out + '.Image', 'wb').write(best)
print("内核解压后大小: %d 字节 (%.2f MiB)" % (len(best), len(best) / 1048576))
PY

strings -a -n 4 "$OUT.Image" | LC_ALL=C sort -u > "$OUT"
echo "导出字符串行数: $(wc -l < "$OUT")"
