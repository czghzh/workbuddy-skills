#!/usr/bin/env python3
"""把 FOE 快照与 conntrack 做逐条双向配对，回答「每个方向的卸载覆盖」。

准备快照（在宿主机上执行；===SPLIT=== 是自造分隔符）：
    ssh <dev> 'cat /sys/kernel/debug/ppe/bind; echo ===SPLIT===; cat /proc/net/nf_conntrack' > snapshot.txt
然后：
    python3 foe-ct-pair.py snapshot.txt              # 自动识别内网网段
    python3 foe-ct-pair.py snapshot.txt 192.168.16   # 或手工指定 /24 前缀

输出：双向都有 / 只有上行 / 只有下行 / 都没有 的条数，以及双向都有的样例
（含两个方向各自的 PSE_PORT 与 FAST_PATH）。
"""
import re
import sys
import collections

NP = {0: "CDM1", 1: "GDM1", 2: "GDM2", 3: "GDM3", 4: "PPE1", 5: "CDM2",
      6: "CDM3", 7: "CDM4", 8: "PPE2", 9: "GDM4", 10: "CDM5", 15: "DROP"}


def hp(x):
    """'1.2.3.4:80' -> ('1.2.3.4', '80')；无端口时第二项 None。"""
    if not x:
        return (None, None)
    if ':' in x:
        a, p = x.rsplit(':', 1)
        return (a, p)
    return (x, None)


def key_from_pair(s):
    """'A:pa->B:pb' -> (A, pa, B, pb)。必须先按 '->' 拆，再各自拆 IP:port。"""
    parts = s.split('->')
    if len(parts) != 2:
        return None
    a, b = hp(parts[0]), hp(parts[1])
    return (a[0], a[1], b[0], b[1])


def parse_ct_tuples(line):
    """把 conntrack 行拆成 [tuple1, tuple2]；每个 tuple 收 src/dst/sport/dport/packets。"""
    out, cur = [], {}
    for tok in line.split():
        tok = tok.strip('[]')
        if '=' not in tok:
            continue
        k, v = tok.split('=', 1)
        if k == 'src' and cur:
            out.append(cur)
            cur = {}
        if k in ('src', 'dst', 'sport', 'dport', 'packets'):
            cur[k] = v
    if cur:
        out.append(cur)
    return out


def detect_lan(ct_txt):
    """从 conntrack 里挑出出现最多的内网 /24 前缀（如 '192.168.16'）。"""
    c = collections.Counter()
    for line in ct_txt.splitlines():
        if not (line.startswith('ipv4') or line.startswith('ipv6')):
            continue
        m = re.search(r'src=((?:\d{1,3}\.){3})\d{1,3}\b', line)
        if not m:
            continue
        p = m.group(1).rstrip('.')
        if p.startswith('192.168.') or p.startswith('10.') or p.startswith('172.'):
            c[p] += 1
    return c.most_common(1)[0][0] if c else None


def main(path, lan=None):
    raw = open(path, encoding='utf-8', errors='replace').read().split('===SPLIT===')
    if len(raw) < 2:
        sys.exit('快照里没找到 ===SPLIT=== 分隔符')
    foe_txt, ct_txt = raw[0], raw[1]

    if not lan:
        lan = detect_lan(ct_txt)
        if not lan:
            sys.exit('没能自动识别内网网段，请手工传第二个参数，如 192.168.1')
    tag = lan + '.'
    print(f'内网网段: {tag}*   (可用第二个参数覆盖)')

    foe = {}
    for line in foe_txt.splitlines():
        m = re.match(r'^([0-9a-f]+)\s+(\w+)\s+(\S+ \S+)\s+orig=(\S+)', line)
        if not m:
            continue
        idx, st, typ, o = m.groups()
        k = key_from_pair(o)
        if not k:
            continue
        ib = re.search(r'ib2=([0-9a-f]+)', line)
        v = int(ib.group(1), 16) if ib else 0
        foe[k] = (idx, st, typ, (v >> 5) & 15, (v >> 10) & 1)
    print(f'FOE orig 索引: {len(foe)}')

    ct = []
    for line in ct_txt.splitlines():
        if not (line.startswith('ipv4') or line.startswith('ipv6')):
            continue
        if tag not in line:                   # 只看内网源
            continue
        ts = parse_ct_tuples(line)
        if len(ts) < 2:
            continue
        o, r = ts[0], ts[1]
        if not all(k in o for k in ('src', 'dst', 'sport', 'dport')):
            continue
        if not all(k in r for k in ('src', 'dst', 'sport', 'dport')):
            continue
        ct.append((o, r, '[HW_OFFLOAD]' in line,
                   int(o.get('packets', 0) or 0), int(r.get('packets', 0) or 0)))
    print(f'内网源 conntrack: {len(ct)}   [HW_OFFLOAD]: {sum(1 for c in ct if c[2])}\n')

    def classify(items):
        c = collections.Counter()
        for o, r, _hw, _op, _rp in items:
            kf = (o['src'], o['sport'], o['dst'], o['dport'])
            kr = (r['src'], r['sport'], r['dst'], r['dport'])
            a, b = kf in foe, kr in foe
            c['两个方向都有条目' if (a and b) else
              '只有 LAN→WAN 条目' if a else
              '只有 WAN→LAN 条目' if b else
              'FOE 里没有（未卸载/未存活/UNREPLIED）'] += 1
        return c

    for label, items in (('全量', ct), ('只看 [HW_OFFLOAD]', [c for c in ct if c[2]])):
        print(f'=== {label} ({len(items)} 条) ===')
        tot = max(len(items), 1)
        for k, v in classify(items).most_common():
            print(f'  {k:34s} {v:5d}  ({v * 100 // tot}%)')
        print()

    print('=== 双向都有的样例 ===')
    n = 0
    for o, r, hw, op, rp in ct:
        kf = (o['src'], o['sport'], o['dst'], o['dport'])
        kr = (r['src'], r['sport'], r['dst'], r['dport'])
        if kf in foe and kr in foe and n < 6:
            a, b = foe[kf], foe[kr]
            print(f"  {o['src']}:{o['sport']} <-> {o['dst']}:{o['dport']}"
                  f"   (pkt 上行={op} 下行={rp}, hw={hw})")
            print(f"     上行 idx={a[0]} {a[1]} pse={a[3]}({NP.get(a[3], '?')}) fast_path={a[4]}")
            print(f"     下行 idx={b[0]} {b[1]} pse={b[3]}({NP.get(b[3], '?')}) fast_path={b[4]}")
            n += 1
    if n == 0:
        print('  （没有配上的。先确认 FOE 与 conntrack 是同一时刻抓的，')
        print('    且 FOE 条目建立有延迟；也确认网段过滤条件改对了）')


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'snapshot.txt',
         sys.argv[2] if len(sys.argv) > 2 else None)
