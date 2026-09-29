#!/usr/bin/env python3
"""静态推演某个包 Makefile 里「受 ifdef 守卫的编译宏」在两个 .config 下的真假差异。

用途：排查「开 ALL_KMODS 后某个驱动被带上了不该有的编译宏」这类问题
      （真实案例：package/kernel/mt76 里选中 kmod-mt7996e 会给整个 mt76 包加
        -DCONFIG_MT76_NPU，把 NPU 卸载代码注进 mt7915e，导致设备 panic 重启循环）。

用法: diff-pkg-flags.py <包的 Makefile> <配置A> <配置B> [<配置C> ...]
输出: 每个受条件守卫的 PKG_MAKE_FLAGS / NOSTDINC_FLAGS 在各配置下的开/关，
      以及有差异的条目数。

注意:
  * 解析的是 Makefile 的 ifdef/ifndef/endif 嵌套栈；条件是 CONFIG_PACKAGE_x 这类符号。
  * 判真值只看 .config 里的 `SYM=y` / `SYM=m`（其它一律当作 n）。
  * 把某一版的 .config 备份成文件放在树外，就能回头对比（distclean 会删树内的）。
"""
import re
import sys


def val(txt: str, sym: str) -> str:
    if re.search(r'^' + re.escape(sym) + r'=y$', txt, re.M):
        return 'y'
    if re.search(r'^' + re.escape(sym) + r'=m$', txt, re.M):
        return 'm'
    return 'n'


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    mk_path, cfg_paths = sys.argv[1], sys.argv[2:]
    names = [p.split('/')[-1] for p in cfg_paths]
    texts = [open(p, errors='replace').read() for p in cfg_paths]

    stack, flags = [], []
    for ln in open(mk_path, errors='replace'):
        s = ln.strip()
        if s.startswith('ifdef '):
            stack.append(s.split()[1])
        elif s.startswith('ifndef '):
            stack.append('!' + s.split()[1])
        elif s.startswith('endif'):
            if stack:
                stack.pop()
        elif s.startswith('PKG_MAKE_FLAGS') or s.startswith('NOSTDINC_FLAGS'):
            flags.append((list(stack), s))

    print("包: %s" % mk_path)
    print("配置: %s" % ', '.join(names))
    print()
    diff = 0
    for conds, fl in flags:
        if not conds:
            continue
        res = []
        for txt in texts:
            ok = True
            for c in conds:
                neg, sym = c.startswith('!'), c.lstrip('!')
                v = val(txt, sym)
                ok = ok and ((v != 'n') if not neg else (v == 'n'))
            res.append(ok)
        changed = len(set(res)) > 1
        if changed:
            diff += 1
        print("  %-50s %-30s %s%s" % (
            fl[:50], '&'.join(conds)[:30],
            '  '.join('%s=%s' % (n, '开' if r else '关') for n, r in zip(names, res)),
            '   ← 有变化' if changed else ''))
    print()
    print("有差异的条目数：%d" % diff)
    if diff:
        print("⇒ 这些宏会改变该包的编译结果；若不希望如此，把触发它的那个 kmod 包显式置 not set")
        print("   （注意：kconfig 的 select 会覆盖 n，需连同依赖它的包一起关）")
    return 0


if __name__ == '__main__':
    sys.exit(main())
