#!/usr/bin/env python3
"""从 OpenWrt 的 .itb(FIT) 里抠出 squashfs（rootfs）段落。
用法: carve-squashfs.py <itb> <输出.sqfs>
坑: 超级块是 5 个 u32 + 6 个 u16（共 96 字节），少写一个字段会被 except 吞掉、表现为"扫不到"。
"""
import struct, sys
SB = struct.Struct('<IIIIIHHHHHHQQQQQQQQ')
assert SB.size == 96
data = open(sys.argv[1], 'rb').read()
hits, i = [], 0
while True:
    i = data.find(b'hsqs', i)
    if i < 0:
        break
    try:
        v = SB.unpack_from(data, i)
        if v[9] == 4 and v[3] in (4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576) \
           and 0 < v[12] <= len(data) - i:
            hits.append((i, v[12]))
    except Exception:
        pass
    i += 4
if not hits:
    print("✘ 找不到 squashfs", file=sys.stderr); sys.exit(1)
off, used = hits[0]
open(sys.argv[2], 'wb').write(data[off:off + used])
print("squashfs offset=%d size=%d" % (off, used))
