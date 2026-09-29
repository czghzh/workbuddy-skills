---
name: musl-aarch64-python-install-feasibility
description: 判断某个 Python 项目（尤其带大量编译型依赖的）能否装进 musl libc 的 aarch64 嵌入式设备（OpenWrt / ImmortalWrt / 精简 Linux），并在设备上实做最小安装验证。也涵盖「设备上编译太慢 → 改在 x86_64 宿主机交叉编译」的完整流程（musl 交叉工具链、pyconfig.h 取用、DT_RELR 链接陷阱、重编译 _sqlite3 恢复 load_extension），大工程（100+ 包）的**首选工作流**——「宿主机并行备 wheel（xargs -P8）+ 设备离线安装（--no-index --no-deps）」，以及**把流程产品化**成一键安装脚本 + GitHub Release 分发包（install.sh 八步结构、$0 匹配陷阱、pip --target 需 --upgrade 否则重装等于没装、pip 解包峰值 2 倍空间、busybox 无 stat、procd 自启、幂等性设计、交付前实机验证清单）。当用户要求在这些设备上「安装某个 Python 项目/工具/服务」「做一键安装脚本/安装包」「发布到 GitHub Release」，或遇到 wheel 平台不匹配、pip 报 "no matching distribution"、"ResolutionImpossible"、pip 解析极慢/一核满载、/tmp 爆满、"Target directory already exists"、装完后二进制跑不起来、sqlite3 缺 load_extension、ZoneInfoNotFoundError、脚本找不到同目录文件时使用。
agent_created: true
---

# 在 musl-aarch64 设备上评估并实做 Python 项目安装

## 核心认知

**musl ≠ glibc。** PyPI 上的 wheel 有 `manylinux`（glibc）和 `musllinux` 两套标签，
绝大多数带 C/Rust 扩展的包**只发 manylinux**。在 OpenWrt 类设备上，以下三类东西是常见杀手：

1. **无 musllinux wheel 的编译型包**（如 playwright、sqlite-vec、onnxruntime）
2. **wheel 里打包了 glibc 动态链接二进制**（即使 Python 层是纯 py3）
3. **OpenWrt 的 Python 编译期裁掉了能力**（如 `sqlite3` 的 `load_extension`）

**关键：不要只看 pip 报错就下结论，必须实测二进制能否加载/执行。**

## 阶段一：环境侦察（只读）

```sh
ssh root@<device> "
  uname -m                                    # 期望 aarch64
  cat /etc/openwrt_release 2>/dev/null         # 发行版与 target
  free -m                                      # 内存！Embedded 常 512MB~1GB 且无 swap
  df -h                                        # /overlay 才是可写空间（常挂大容量 sda）
  which opkg apk python3 pip3 gcc make         # 包管理器：新版用 apk，老版 opkg
  ip -4 addr show | grep inet
"
```

要点：
- **`/rom` 只读且常常 100% 满**，真正空间在 `/overlay`（overlayfs 上层）
- `DISTRIB_TAINTS='no-all busybox'` 表示是精简镜像，`hostname`/`free` 之外的命令大量缺失
- **无 swap 是硬伤**：编译大项目或跑 embedding 必 OOM

## 阶段二：查包的发行矩阵（在宿主机做，不用污染设备）

```sh
python3 - <<'PYEOF'
import json, urllib.request
for p in ['pydantic-core','cryptography','numpy','tokenizers','sqlite-vec','playwright']:
    with urllib.request.urlopen('https://pypi.org/pypi/%s/json' % p, timeout=25) as r:
        d = json.load(r)
    urls = d['urls']
    musl = [u['filename'] for u in urls if 'musllinux' in u['filename'] and 'aarch64' in u['filename']]
    cps  = sorted({f.split('-')[2] for f in musl})
    pure = [u['filename'] for u in urls if u['filename'].endswith('none-any.whl')]
    print('%-18s %-10s musl-aarch64 tags=%s pure=%s' % (p, d['info']['version'], cps or 'NONE', bool(pure)))
PYEOF
```

**逐个依赖判定四类**：
| 判定 | 依据 | 处理 |
|---|---|---|
| `PURE` | 有 `py3-none-any.whl` | 直接装，无风险 |
| `MUSL-OK` | 有 `musllinux_*_aarch64` + 目标 cpXXX | 直接装 |
| `NO-CPXXX` | 有 musl wheel 但没目标 Python 版本的 tag | 需降 Python 版本，或编译 |
| `NEED-COMPILE` | 只有 manylinux / 只有 sdist | 进入阶段三实测 |

**排查 PyPI 的快捷命令**（看某包所有版本的平台覆盖）：
```sh
curl -s https://pypi.org/pypi/<pkg>/json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for v,fs in d['releases'].items():
    if fs: print(v, sorted({f['filename'].split('-',2)[2] for f in fs})[:3])
"
```

## 阶段三：强拉跨平台 wheel 并实测（关键！）

**语法**（注意 `--python-version` 要写设备的真实版本）：
```sh
pip3 download --no-deps --no-cache-dir -d ./wheels \
  --platform manylinux_2_17_aarch64 \
  --python-version 3.14 \
  --only-binary=:all: \
  '<pkg>'
```

拿到 wheel 后**必须做二进制体检**：

```sh
# 1) 看 wheel 里有哪些 .so / 二进制
python3 -c "
import zipfile
z=zipfile.ZipFile('xxx.whl')
for n in z.namelist():
    if n.endswith('.so') or '/node' in n or '/bin/' in n:
        print(n, z.getinfo(n).file_size)
"

# 2) 提取并检查 PT_INTERP（是不是 glibc 动态链接）
python3 - <<'PYEOF'
import struct
f=open('/tmp/extracted.so','rb'); head=f.read(64)
if head[:4]!=b'\x7fELF': print('非 ELF'); raise SystemExit
f.seek(32)
e_phoff=int.from_bytes(f.read(8),'little'); e_phentsize=int.from_bytes(f.read(2),'little')
e_phnum=int.from_bytes(f.read(2),'little'); f.seek(e_phoff)
for i in range(e_phnum):
    ph=f.read(e_phentsize)
    if int.from_bytes(ph[0:4],'little')==3:
        off=int.from_bytes(ph[8:16],'little'); sz=int.from_bytes(ph[32:40],'little')
        f.seek(off); print('PT_INTERP =', f.read(sz).rstrip(b'\x00').decode()); break
else: print('无 PT_INTERP（静态）')
PYEOF

# 3) ldd 看缺什么（关键：找 ld-linux / libstdc++ / glibc 专有符号）
ldd /tmp/extracted.so

# 4) 直接执行试（针对打包的可执行文件）
chmod +x /tmp/extracted_node && /tmp/extracted_node --version
```

**判读规则**：
- `PT_INTERP` 指向 `/lib/ld-linux-*.so.*` → **glibc，musl 上必失败**
- `ldd` 报 `libstdc++.so.6 not found` / `ld-linux-aarch64.so.1 not found` → 同上
- 报 `__memcpy_chk` / `__fread_chk` / `__*_chk` 等符号缺失 → **glibc 专有符号，无解**（除非自己编译）
- 设备 `/lib/` 下只有 `ld-musl-aarch64.so.1` → 对照确认

## 阶段四：检查 Python 自身能力（OpenWrt 特有坑）

```sh
python3 -c "
import sqlite3
print('load_extension:', hasattr(sqlite3.Connection,'load_extension'))
print('enable_load_extension:', hasattr(sqlite3.Connection,'enable_load_extension'))
"
```

**OpenWrt 的 python3 常常把 `load_extension` / `enable_load_extension` 编译期裁掉。**
一旦为 False，**所有依赖 SQLite 扩展的项目（sqlite-vec、向量检索、部分 langgraph 后端）彻底无解**——
不是"编译一下就行"，而是 Python 层没有 API 能挂载。

其它要检查的能力：
```sh
python3 -c "import ssl, ctypes, sqlite3, zlib, bz2, lzma; print('stdlib ok')"
python3 -c "import venv" 2>&1     # OpenWrt 常没有 venv / ensurepip
```

## 阶段五：实做最小安装

**用 `--target` 装到 /overlay，绝不污染系统 site-packages**：
```sh
apk add python3 python3-dev python3-pip python3-setuptools
mkdir -p /overlay/myapp && cd /overlay/myapp
pip3 install --no-cache-dir --target /overlay/myapp <包名>
```

**包名注意**：OpenWrt 是 `python3-pip`（不是 `py3-pip`），`python3-setuptools`。
搜索用 `apk search -v '*pip*'`，**不要假设 `py3-` 前缀**。

**apk 锁问题**：偶发 `Unable to lock database`，清理：
```sh
rm -f /var/lock/apk* /lib/apk/db/lock
```

**⚠️ 致命陷阱：apk 命令是原子的，一个包不存在会导致整条命令回滚。**
```sh
# 反例：musl-dev / linux-headers 在 ImmortalWrt 源里不存在
apk add gcc make musl-dev linux-headers   # → 全部失败，gcc 也没装上！
# 正解：分开装，或先确认包名存在
apk add gcc
```
**别因为一次 `apk add` 失败就断定"设备不能编译"。** 实测发现：
`apk add gcc` 单独执行会成功，而且**musl 标准 C 头文件（stdio.h/stdlib.h/pthread.h/sys/）
是随 gcc 包一起提供的**，不在单独的 musl-dev 里。验证方法：
```sh
printf '#include <stdio.h>\nint main(void){printf("ok\\n");return 0;}\n' > /tmp/h.c
gcc /tmp/h.c -o /tmp/h && /tmp/h        # 能跑就说明编译环境完备
```

## 阶段六：无 musl wheel 时，现场编译 C 扩展（可行！）

很多 C 扩展（如 sqlite-vec）源码很小，可以在设备上直接编译出 musl 版。
以 sqlite-vec 为例（**实测成功**）：

```sh
# 1) 装 gcc
apk add gcc

# 2) 用 GitHub API 的 download_url 拉全部源码（raw URL 对某些文件不可靠）
wget -q -O /tmp/list.json "https://api.github.com/repos/asg017/sqlite-vec/contents/"
python3 -c "
import json,urllib.request
d=json.load(open('/tmp/list.json'))
for it in d:
    if it['type']=='file' and it['name'].endswith(('.c','.h')):
        data=urllib.request.urlopen(it['download_url'],timeout=30).read()
        open('/tmp/sqlite-vec-src/'+it['name'],'wb').write(data)
"

# 3) 拉 SQLite amalgamation 拿 sqlite3.h / sqlite3ext.h
wget -q -O /tmp/sq.zip https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip

# 4) 补构建系统生成的宏（源码里没有，必须手工传）
gcc -shared -fPIC -O2 -I. \
  -DSQLITE_VEC_VERSION='"0.1.9"' \
  -DSQLITE_VEC_VERSION_MAJOR=0 -DSQLITE_VEC_VERSION_MINOR=1 -DSQLITE_VEC_VERSION_PATCH=9 \
  -DSQLITE_VEC_DATE='"2026-09-23"' -DSQLITE_VEC_SOURCE='"local"' -DSQLITE_VEC_API= \
  sqlite-vec.c -o /tmp/vec0.so
```

**⚠️ 输出文件名决定入口符号！** SQLite 按文件名推导入口：
`vec0-musl.so` → 期望 `sqlite3_vec0musl_init` → 报 `Symbol not found`。
**必须命名为 `vec0.so`**。

## 阶段七：Python 层无法加载扩展时的绕过（ctypes）

OpenWrt 的 CPython 常把 `sqlite3.Connection.load_extension` /
`enable_load_extension` 从**方法表**里删掉（`_sqlite3.so` 里连符号名都不存在），
但**底层 `libsqlite3.so` 是完整支持的**。验证：
```sh
python3 -c "
import ctypes
lib=ctypes.CDLL('libsqlite3.so.0')
print('enable:', hasattr(lib,'sqlite3_enable_load_extension'))
print('load  :', hasattr(lib,'sqlite3_load_extension'))
"
```

**可以绕过的方案（实测 C 层完全可用）**：
```python
import ctypes
lib = ctypes.CDLL('libsqlite3.so.0')
lib.sqlite3_load_extension.argtypes=[ctypes.c_void_p, ctypes.c_char_p,
                                     ctypes.c_char_p, ctypes.POINTER(ctypes.c_char_p)]
db = ctypes.c_void_p()
lib.sqlite3_open(b':memory:', ctypes.byref(db))
lib.sqlite3_enable_load_extension(db, 1)
lib.sqlite3_load_extension(db, b'/path/vec0.so', None, ctypes.byref(errmsg))
# 之后用 lib.sqlite3_exec / sqlite3_prepare_v2 操作
```

**两条走不通的 Python 层绕过（别浪费时间）**：
- `setconfig(SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, True)` → 开关能打开（`getconfig` 变 True），
  但 SQL 的 `load_extension()` 被 pysqlite **内建 authorizer** 拦住（`not authorized`）
- `set_authorizer()` 放行 → **无效**，pysqlite 在 C 层装了自有 authorizer，Python 层盖不住

若必须让**上层 Python 库**（如 langgraph-checkpoint-sqlite）正常工作，
唯一路径是**重编译 `_sqlite3` 模块**。详见下面的「阶段八」实操手册（已实测成功）。

## 阶段八：重编译 `_sqlite3` 恢复 load_extension（2026-09 实测成功）

### 关键认知：为什么官方模块是残的

CPython 的 `Modules/_sqlite/connection.c` 与方法表**由 `PY_SQLITE_ENABLE_LOAD_EXTENSION` 宏保护**：

```c
// Modules/_sqlite/connection.c:1703
#ifdef PY_SQLITE_ENABLE_LOAD_EXTENSION
    ... pysqlite_connection_enable_load_extension_impl ...
    ... pysqlite_connection_load_extension_impl ...
#endif                                          // :1776

// Modules/_sqlite/clinic/connection.c.h:1000
#if defined(PY_SQLITE_ENABLE_LOAD_EXTENSION)
#define PYSQLITE_CONNECTION_LOAD_EXTENSION_METHODDEF \
    {"load_extension", _PyCFunction_CAST(pysqlite_connection_load_extension), ...},
#endif                                          // :1131
// :1909-1915 有 #ifndef 兜底空定义
```

OpenWrt 编译时**没定义这个宏**，于是方法和方法表条目一起消失。源码本身是完整的。

**⚠️ 三个宏极易混淆，必须用对：**

| 宏 | 作用域 | 含义 |
|---|---|---|
| `PY_SQLITE_ENABLE_LOAD_EXTENSION` | **CPython** wrapper | **必须定义**，否则 Python 方法消失 |
| `SQLITE_ENABLE_LOAD_EXTENSION` | SQLite 本体 | 定义后 `compile_options()` 出现该项 |
| `SQLITE_OMIT_LOAD_EXTENSION` | SQLite 本体 | **绝不能定义**（哪怕 `=0` 也视为已定义，会关掉能力） |

### 步骤（在 x86_64 宿主机交叉编译，比设备上快 10 倍以上）

**1. 装 musl 交叉工具链（一次性）**
```sh
wget https://musl.cc/aarch64-linux-musl-cross.tgz    # ~103 MB
tar -xzf aarch64-linux-musl-cross.tgz
CC=$PWD/aarch64-linux-musl-cross/bin/aarch64-linux-musl-gcc
$CC --version        # GCC 11.2.1，target: aarch64-linux-musl
```

**2. 备齐三类输入**
```sh
# (a) CPython 源码（版本必须与设备 Python 完全一致）
wget https://www.python.org/ftp/python/3.14.5/Python-3.14.5.tgz
tar -xzf Python-3.14.5.tgz Python-3.14.5/Modules/_sqlite Python-3.14.5/Include

# (b) 设备上真实生成的 pyconfig.h（源码包里没有，必须从设备取！）
scp root@<device>:/usr/include/python3.14/pyconfig.h .

# (c) SQLite amalgamation 的 sqlite3.h / sqlite3ext.h（版本对齐设备的 sqlite_version）
wget https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip
```

**3. 编译 sqlite3.o（静态并入，避免链接 glibc/RELR 库）**
```sh
$CC -fPIC -O2 -Os -pipe -mcpu=cortex-a53 -fno-plt -fstack-protector -DNDEBUG \
  -DSQLITE_ENABLE_LOAD_EXTENSION=1 -DSQLITE_ENABLE_FTS5=1 -DSQLITE_ENABLE_RTREE=1 \
  -DSQLITE_ENABLE_COLUMN_METADATA=1 -DSQLITE_ENABLE_JSON1=1 -DSQLITE_ENABLE_MATH_FUNCTIONS=1 \
  -DSQLITE_THREADSAFE=1 \
  -Isqlite-amalg -c sqlite3.c -o sqlite3.o          # 8 核约 60 秒
```

**4. 编译 `_sqlite3` 的 9 个源文件（关键是那个宏）**
```sh
CFLAGS="-fPIC -O2 -Os -pipe -mcpu=cortex-a53 -fno-plt -fno-strict-overflow \
 -Wsign-compare -DNDEBUG -Wall -fstack-protector \
 -DPY_SQLITE_ENABLE_LOAD_EXTENSION=1 \
 -DSQLITE_ENABLE_LOAD_EXTENSION=1 \
 -I<inc> -I<inc>/internal -I<_sqlite> -Isqlite-amalg"

for c in connection cursor module prepare_protocol statement util row blob microprotocols; do
  $CC $CFLAGS -c $_sqlite/$c.c -o $c.o
done
```

**5. 链接（不要试图链接系统的 libsqlite3.so / libz.so）**
```sh
$CC -shared -fPIC -o _sqlite3.so *.o sqlite3.o \
  -Wl,--allow-shlib-undefined -Wl,-z,now -Wl,-z,relro -Wl,-z,max-page-size=4096
```

**6. 验证产物（本地先自查，再上设备）**
```sh
strings -a _sqlite3.so | grep -c load_extension    # 应 ≥ 5，含方法名与 docstring
objdump -T _sqlite3.so | grep PyInit__sqlite3      # 入口符号必须在
objdump -p _sqlite3.so | grep NEEDED               # 理想只有 libc.so
readelf -l _sqlite3.so | grep -i interp            # 扩展模块必须无 PT_INTERP
```

**7. 部署（务必先备份，再用 md5 核对传输是否成功）**
```sh
SO=/usr/lib/python3.14/lib-dynload/_sqlite3.cpython-314-aarch64-linux-musl.so
cp -a $SO $SO.orig                       # 备份！
scp _sqlite3.so root@<device>:$SO
md5sum _sqlite3.so root@<device>:$SO     # 两边必须一致
```

**8. 验收**
```sh
python3 -c "
import sqlite3
c=sqlite3.connect(':memory:')
print(hasattr(c,'load_extension'), hasattr(c,'enable_load_extension'))
opts=[r[0] for r in c.execute('pragma compile_options')]
print('OMIT :', any('OMIT_LOAD_EXTENSION' in o for o in opts))   # 必须 False
"
```

### 踩过的坑（都会让你白忙一场）

1. **`ld.bfd` 拒绝带 `DT_RELR` 的库** → 报 `error adding symbols: file in wrong format`。
   OpenWrt 用 `-z pack-relative-relocs` 编的 `.so` 都带 `RELR` 段。
   **解法：别链它们，用 amalgamation 静态编译 sqlite3，或直接 `-Wl,--allow-shlib-undefined`。**
2. **源码包里的 `pyconfig.h` 是空的** → 它由 configure 生成，`Include/` 目录里没有。
   **必须从设备 `scp` 一份**，否则报 `fatal error: pyconfig.h: No such file or directory`。
3. **改完宏别忘了重编 `connection.o`**，`sqlite3.o` 可以复用（它跟那个宏无关）。
4. **传完文件一定 md5 核对**。曾在设备上实测发现方法仍为 False，追查是**部署的还是旧文件**。
5. **验证要在设备上做**：宿主机上 `strings` 有方法名 ≠ 设备上能 import。两层都要验。
6. GCC 11 编 sqlite-vec 的 NEON 路径会报 `vpaddlq_u8` 类型错误 → 加 `-flax-vector-conversions`。

### 顺带：sqlite-vec 的 vec0.so 交叉编译

```sh
# 源码（raw.githubusercontent.com 逐个下，主仓的 sqlite-vec.h 是 404）
for f in sqlite-vec.c sqlite-vec-diskann.c sqlite-vec-ivf.c sqlite-vec-rescore.c sqlite-vec-ivf-kmeans.c; do
  curl -sLO https://raw.githubusercontent.com/asg017/sqlite-vec/main/$f
done
# 自建 sqlite-vec.h，补上构建系统才生成的宏
cat > sqlite-vec.h <<'EOF'
#define SQLITE_VEC_VERSION "v0.1.9"
#define SQLITE_VEC_VERSION_MAJOR 0
#define SQLITE_VEC_VERSION_MINOR 1
#define SQLITE_VEC_VERSION_PATCH 9
#define SQLITE_VEC_DATE "2026-09-23"
#define SQLITE_VEC_SOURCE "asg017/sqlite-vec@main"
#define SQLITE_VEC_API
EOF

$CC -fPIC -O2 -Os -mcpu=cortex-a53 -fno-plt -fstack-protector -DNDEBUG \
  -DSQLITE_VEC_ENABLE_NEON=1 -flax-vector-conversions -I. \
  -shared sqlite-vec.c -o vec0.so -lm
```

**⚠️ 输出文件名必须是 `vec0.so`**：SQLite 按文件名推导入口符号
（`vec0-musl.so` → 期望 `sqlite3_vec0musl_init`，会报 `Symbol not found`）。

## 阶段九：宿主机并行备 wheel + 设备离线安装（2026-09 实测成功，**首选工作流**）

**这是大工程（100+ 包）在弱设备上安装的首选路线。** 实测把 Octop（197 包 / 833 MB）
装进 4 核 A53 / 952 MB 的 OpenWrt 设备，全程设备端零依赖求解。

### 核心认知：pip 的求解器是**单线程**的

在 4 核设备上跑 `pip install`，你会看到 **「一核满载、三核空闲」** ——
这不是配置问题，`pip`/`resolvelib` 的依赖求解是**串行算法**，天然无法并行化。

更糟的是**窄版本区间会触发暴力回溯**。真实案例：

```
aiobotocore==2.25.1 要求 boto3<1.40.62,>=1.40.46     # 只有 16 个候选版本
pip 从最新的 1.41.4 逐版往下试
每个候选都要下载 botocore（14 MB）
→ 14 分钟 + 547 MB 下载量，/tmp（tmpfs 465 MB）直接爆
```

**钉死区间端点后：14 分钟 → 48 秒（18 倍）。**

### 正确架构：算力放宿主机，设备只做解包

```
宿主机（x86_64, 8 核, 大内存）
  ├─ 解析出「真值清单」（包名 + 精确版本）
  ├─ 8 路并行下载 wheel
  └─ 打包成 tar.gz  →  scp  →  设备
设备（aarch64 musl 弱机）
  └─ pip install --no-index --no-deps  ← 零求解、零网络、纯解包
```

### 步骤 1：宿主机解析真值清单

```sh
# 关键：用跟设备一致的 python-version / platform 去解析
pip install --dry-run --ignore-installed --report report.json \
    --python-version 3.14 --only-binary=:all: \
    --platform musllinux_1_2_aarch64 'octop[all]' 2>/dev/null || true

# 从 report.json 抽出 name / version / kind / filename
python3 -c "
import json
r = json.load(open('report.json'))
for it in r['install']:
    m = it['metadata']
    url = it['download_info']['url']
    print(f\"{m['name']}\t{m['version']}\t{'wheel' if url.endswith('.whl') else 'sdist'}\t{url.rsplit('/',1)[-1]}\")
" | sort > pkgs.tsv
```

> `--dry-run --report` 只出元数据，不落盘。**但注意它仍会真的下载**（除非配合 `--no-deps`），
> 所以大工程仍建议按下面的并行方式分两步做。

### 步骤 2：并行下载 wheel（`xargs -P8`，真正用上多核）

```sh
# 只下「确定有 musl wheel」的那批，一个包一个独立 pip 进程
grep -P '\twheel\t' pkgs.tsv | cut -f4 | sort -u > want.txt
xargs -a want.txt -P8 -I{} sh -c '
    pip download --no-deps --only-binary=:all: \
        --platform musllinux_1_2_aarch64 --python-version 3.14 \
        --implementation cp --abi cp314 \
        -d /work/wheels-musl "{}" >/dev/null 2>&1 || echo "FAIL {}"
'
# 实测：40 个 musl 包，秒级拿到 35 个
```

```sh
# 纯 Python 包（py3-none-any）单独一批，平台参数反而不需要
xargs -a want-pure.txt -P8 -I{} sh -c '
    pip download --no-deps --only-binary=:all: -d /work/wheels-pure "{}" >/dev/null 2>&1 \
      || echo "SDIST-ONLY {}"
'
# 实测：157 个纯 py 成功 156 个，1 个只有 sdist
```

**⚠️ 两个 `-P8` 进程同时写同一个目录会互相踩**，务必分目录。

### 步骤 3：constraints 只钉**真正窄的区间**

```sh
# ✅ 对：只钉那个引发回溯的窄区间
cat > constraints-min.txt <<'EOF'
aiobotocore==2.25.1
boto3==1.40.61
botocore==1.40.61
s3transfer==0.14.0
EOF
pip download -c constraints-min.txt ...
```

```sh
# ❌ 错：把宿主机的完整解析结果全量当 constraints
pip freeze > constraints.txt && pip download -c constraints.txt ...
```

**这是踩过的坑**：宿主机（**glibc / cp313**）解析出 `websockets==16.1.1`，
但目标环境里 `lark-oapi 1.7.3` 要求 `websockets<16`；而且宿主机那份 freeze
可能来自**另一个 feature set**（如 `[all]` extra 单独解析，不含 lark-oapi），
于是设备端直接 `ResolutionImpossible`。

> **平台差异（glibc↔musl、cp313↔cp314）+ feature set 差异，会让解析结果不通用。**
> constraints 的作用是**省掉回溯**，不是**冻结世界**。

### 步骤 4：设备端离线批量安装

```sh
# 设备：无网络、无求解、无回溯，纯解包 + 拷文件
python3 -m pip install \
    --no-index --no-deps \
    --target /overlay/<pkg-dir> \
    --disable-pip-version-check \
    /overlay/wheelhouse/*.whl
```

**为什么 `--target` 而不是普通安装**：装到可写的 `/overlay` 下，
避开 `/usr/lib/python3.14/site-packages`（只读 squashfs）。

**安装期会看到 `State: D` + `wchan: blk_mq_get_tag`** —— 这是 eMMC/SD 的 IO 队列堵塞
（143 MB 落盘），**不是卡死**。判断进度的方法：看 `pip-<random>/` 临时目录是否出现，
出现即已进入「拷文件」阶段。

### 步骤 5：无 musl wheel 的包 —— 三类处理

| 情况 | 处理 |
|---|---|
| **stub 换掉**（纯功能阉割可接受） | 手工造桩包（见下） |
| **可交叉编译**（C 扩展 / 纯 .so） | 宿主机编译 → 手工构造 wheel（见下） |
| **属于无关 extra**（如云存储 / 桌面） | 直接**跳过**，用 `--no-index --no-deps` 只装需要的 |

**先做 extra 审计**，别为无关依赖买单。实测 `orcakit-harness-agent[all]` 的 `[all]`
额外拉进 **33 个依赖**（AWS S3、阿里 OSS、华为 OBS、Docker、桌面 GUI 等），
对「最小可用」全部无关。

```sh
# 拆解 extra，看清 [all] 到底拉了什么
python3 -c "
import json,urllib.request
d=json.load(urllib.request.urlopen('https://pypi.org/pypi/<pkg>/json'))
print(json.dumps(d['info'].get('requires_dist'),indent=1,ensure_ascii=False))
"
```

### 步骤 6：裸 `.so` → 正式 wheel 的手工构造

上游没有 musl wheel，但你能自己编出 `.so` 时，**不要直接把 `.so` 拷进 site-packages**
（pip 不认，`No matching distribution found`）。要包成正式 wheel：

```python
import base64, hashlib, zipfile
from pathlib import Path

def urlsafe_b64_nopad(b):                      # RECORD 的哈希格式
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

dist = "sqlite_vec-0.1.9"                      # 关键：name 里的 - 要换成 _
files = {
    "sqlite_vec/__init__.py":  INIT_PY.encode(),
    "sqlite_vec/vec0.so":      Path("vec0.so").read_bytes(),
    f"{dist}.dist-info/METADATA": METADATA.encode(),
    f"{dist}.dist-info/WHEEL":    WHEEL.encode(),
    f"{dist}.dist-info/RECORD":   b"",          # 先占位，内容末尾统一回填
}
records = []
with zipfile.ZipFile("sqlite_vec-0.1.9-py3-none-any.whl", "w", zipfile.ZIP_DEFLATED) as z:
    for name, data in files.items():
        if name.endswith("RECORD"):
            continue
        z.writestr(name, data)
        h = urlsafe_b64_nopad(hashlib.sha256(data).digest())
        records.append(f"{name},sha256={h},{len(data)}")
    rec = ("\n".join(records + [f"{dist}.dist-info/RECORD,,"]) + "\n").encode()
    z.writestr(f"{dist}.dist-info/RECORD", rec)
```

要点：
- **`Tag: py3-none-any`**（即便内含 `.so`）—— 因为它是自己编的，不必挂 abi tag
- `RECORD` 每行 `路径,sha256=<urlsafe_b64 无填充>,<字节数>`
- **`dist-info` 目录名与 `METADATA` 里的 `Name` 必须一致**（`-` ↔ `_`）

### 步骤 7：桩包（stub package）的设计三要点

被硬阻断（如 `playwright` 的 driver 是 glibc 二进制）但下游只是**声明依赖**时，造个桩包最省事。

```python
# playwright/__init__.py
__version__ = "1.99.0"          # ★ 必须满足下游的最低版本要求（如 >=1.40）
__is_octop_stub__ = True

_DISABLED = ("playwright is not available on this platform (musl/aarch64 stub). "
             "Browser automation features are disabled.")

class _StubEntryPoint:
    def __init__(self, name): self._name = name
    def __call__(self, *args, **kwargs):
        raise ImportError(_DISABLED)          # ★ 只在「调用」时抛
    def __repr__(self): return f"<playwright stub {self._name}>"
```

```python
# playwright/sync_api.py      （async_api.py 同理）
from . import _StubEntryPoint
sync_playwright = _StubEntryPoint("sync_playwright")
```

| 要点 | 说明 |
|---|---|
| **版本号要够高** | 初版用 `1.0.0+octop.stub` → `Could not find a version that satisfies playwright>=1.40` |
| **可导入，别用模块级 `__getattr__` 抛错** | 模块级 `__getattr__` 直接 raise 会**拦掉 `from X import Y`**，连 `import` 都过不去 |
| **仅调用时抛错** | 用占位对象 + `__call__` raise，这样 `find_spec` / `import` 都正常，真用到浏览器才报错 |

### 步骤 8：musl 设备必装 `tzdata`（否则 ZoneInfo 崩）

OpenWrt 用 POSIX 时区串（`/etc/TZ = CST-8`），**`/usr/share/zoneinfo/` 是空的**，
apk 源里也不一定有 `tzdata` 包。Python 的 `zoneinfo` 于是报：

```
zoneinfo._common.ZoneInfoNotFoundError: 'No time zone found with key Asia/Shanghai'
```

（典型触发：`apscheduler` → `datetime.astimezone()`）

```sh
# 装 PyPI 的 tzdata wheel 即可（纯 Python，339 KB）
pip install --no-index --no-deps --target /overlay/<pkg-dir> tzdata-2026.4-py2.py3-none-any.whl
```

### 步骤 9：⚠️ 排查「一核满载、三核空闲」的**孤儿进程**

**症状**：安装早已结束，但某个核持续 100%，设备发热。

**根因（实测）**：通过 `ssh ... 'sh -s'` 跑的长脚本，**ssh 断开后其派生的子进程不会自动退出**，
变成孤儿继续跑（实测一个 `python3 -` 跑了 1 小时 41 分，`utime` 累积 446929 tick ≈ 74 分钟纯 CPU）。

**排查（busybox 无 `ps -aux`，用 `/proc` 手工遍历）**：

```sh
# 按 CPU 累计 tick（utime + stime，即 stat 的第 14、15 字段）倒序
for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    t=$(awk '{print $14+$15}' $p/stat 2>/dev/null) || continue
    echo "$t $pid $(tr '\0' ' ' < $p/cmdline 2>/dev/null)"
done | sort -rn | head -20
```

**辅助判据**：
- `/proc/<pid>/wchan` → `blk_mq_get_tag` = 卡在**磁盘 IO**；**空** = 纯 CPU 忙等
- `/proc/<pid>/status` 的 `State:` → `R` 运行 / `D` 不可中断 IO / `S` 睡眠
- `/proc/<pid>/status` 的 `PPid` → 若父进程是 `1` 或 `[kthreadd]`，基本可判定为孤儿

```sh
kill -9 <pid> <pid> <pid>     # busybox 无 pkill
```

**⚠️ 清理时别用 `case` 广匹配**：`ps | while read; do case "$l" in *pip*) kill ...;; esac; done`
会**匹配到循环自身**，造成「杀完还有」的假象。用 `"-m pip install"` 这类精确串。

### 步骤 10：一条铁律 —— **别在弱设备上编译**

交叉编译 `sqlite3.c`（8 核宿主机）约 60 秒；同文件在 A53 上要几十分钟，
且容易中途 ssh 断开留下孤儿进程（见步骤 9）。**所有 C 扩展、`.so`、wheel 构造，全部在宿主机完成。**

### 实测成绩单（Octop 197 包 → OpenWrt aarch64/musl/952 MB）

| 项目 | 结果 |
|---|---|
| 宿主机 8 路并行取 musl wheel | 40 个包 → 成功 35 个 |
| 宿主机并行取纯 py wheel | 157 个 → 成功 156 个 |
| 设备端离线安装 | 193 个 wheel，纯 IO，零求解 |
| 安装体积 | 833.5 MB（`/overlay`，可写） |
| 运行时内存 | **271 MB RSS**（设备 952 MB，无 swap） |
| 服务启动 | `Uvicorn running on http://0.0.0.0:8088`，健康检查 HTTP 200 |
| 核心依赖导入 | 20 / 20 全部成功 |
| pip 解析耗时 | **14 分钟 → 48 秒**（钉 constraints 后） |

## 阶段十：把安装流程产品化（一键脚本 + Release 包，2026-09 实测成功）

当安装流程需要**交付给别人或重复使用**时，把它固化成一键脚本 + 分发包。

### 交付架构：仓库轻量，大文件走 Release

```
GitHub 仓库（几百 KB）
├── install.sh              一键安装（8 步）
├── etc/init.d/<svc>        procd 开机自启
├── scripts/                启动器、辅助工具（如改密码）
├── prebuilt/               预编译产物（几 MB 级，可直接入库）
├── patches/                需要源码的适配（如桩包）
├── tools/                  宿主机侧复现工具
└── docs/                   安装 / 排错 / 重建文档
        ↓
GitHub Release 附件
└── <pkg>-runtime-<arch>-<abi>-v<ver>.tar.gz   （100+ MB，含全部 wheel）
```

**不要**把 wheel 提交进 git —— 仓库会臃肿到无法 clone。用 Release 附件 + 脚本自动下载。

### install.sh 的推荐结构（8 步）

1. **环境检查** —— root / 架构 / Python 版本 / 磁盘 / 内存，不满足要**明确报错**
2. **准备依赖包** —— 优先级：环境变量指定 → 包内自带 → 已下载缓存 → Release 下载
3. **离线安装** —— `pip install --no-index --no-deps --upgrade --target <dir> *.whl`
4. **修补系统组件** —— 如替换 `_sqlite3`，**先备份为 `.orig`**
5. **初始化** —— 首次初始化；**已存在数据则跳过**（幂等）
6. **安装服务与自启** —— procd 脚本 + `enable`
7. **启动并等待就绪** —— 轮询健康端点，超时可配
8. **打印访问信息** —— 地址 / 账号 / 密码 / 常用命令 / 文件位置

### ⚠️ 产品化最容易踩的五个坑（全部实测踩过）

**坑 1：`$0` 匹配不全，找不到同包文件（最隐蔽）**

```sh
case "$0" in
  */install.sh) SCRIPT_DIR=$(dirname "$0") ;;   # ❌
esac
```

`sh install.sh` 时 `$0` 是 **`install.sh`（不带斜杠）**，不匹配 `*/install.sh`；
只有 `/abs/path/install.sh` 才匹配。于是 `SCRIPT_DIR` 为空，
找不到包内 `prebuilt/`、`scripts/`，脚本退化成「必须联网下载」，
离线或 Release 未发布时报 404 并中止。
**影响最常见的用法**（解压后 `sh install.sh`）。

```sh
case "$0" in
  install.sh | */install.sh) SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) ;;
esac
```

必须测四种调用：`cd dir && sh install.sh`、`sh /abs/install.sh`、`cat | sh`、`/bin/sh install.sh`。

**坑 2：`pip --target` 遇到同名目录只警告、不覆盖**

```
WARNING: Target directory .../pydantic_core already exists.
         Specify --upgrade to force replacement.
```

后果：**重装等于没装** —— 旧文件保留、新 wheel 被跳过。
实测：不加 `--upgrade` 产生 N 个跳过警告；加了则 0 警告、正确覆盖。

两条都做最稳：**先 `rm -rf` 安装目录**（数据目录另放，不受影响）+ 加 `--upgrade`。

**坑 3：`pip --target` 的磁盘峰值约 2 倍**

pip 会先把全部 wheel 解压累积到 `<TMPDIR>/pip-target-<rand>/`，
**全部完成后再整体搬到** target。实测临时目录涨到 829 MB 才搬。
所以需求是「目标目录 + 一份等量临时空间」，不是「装完的体积」。
按 **2.2 倍**给建议值，并提示「空间不足可能在最后阶段失败」。

**坑 4：busybox 没有 `stat` / `sort -h` / `pkill`**

`stat -c%s file` 在 OpenWrt 上直接 `stat: not found`，`set -e` 下会中断脚本。
取文件大小改用 **`wc -c < file`**。
发货前把脚本用到的外部命令逐个在设备上 `command -v` 核一遍。

**坑 5：服务脚本里的路径硬编码**

procd 脚本写死 `PROG=/overlay/start-octop.sh`，自定义数据目录时服务指向错误位置。
应在**安装时用 sed 注入实际路径**：

```sh
sed -e "s|^PROG=.*|PROG=\"$OCTOP_DATA/start-octop.sh\"|" "$SRC" > /etc/init.d/svc
```

### 预编译产物可以跨设备复用

只要**架构 + libc + Python 版本**三者一致，`_sqlite3.so`、`vec0.so` 这类交叉编译产物
可直接打包分发，目标设备无需工具链、无需编译 —— 这是把安装压到「纯解包」的前提。

版本不一致时必须重编（阶段六 / 阶段八），因为 ABI tag（`cp314`）与 `pyconfig.h`
都绑定 Python 版本。

### 幂等性设计

一键脚本会被反复运行（升级、重装、排错），必须幂等：

| 操作 | 策略 |
|---|---|
| 清空安装目录 | 只在**非空**时 `rm -rf` |
| 备份系统文件 | 已存在 `.orig` 则**不覆盖**，保留真正的原版 |
| 初始化数据 | 检测到数据库存在即**跳过**，除非显式 `FORCE=1` |
| 启动服务 | 先清理同名残留进程再启动 |

### 交付前验证清单（必须实机跑）

- [ ] 全新安装：起服务、能登录、健康检查 OK
- [ ] **重复安装**：服务仍正常，数据未丢
- [ ] **重启设备**：服务自动起来（procd 的价值，实测 `reboot`）
- [ ] 依赖修补组件的功能可用（如向量检索）
- [ ] 四种脚本调用方式都能找到包内文件
- [ ] 脚本用到的每个外部命令在设备上都存在

> **教训**：上面五个坑里有四个是**实机跑才暴露**的，`sh -n` 静态检查全都通过。
> 一键安装脚本必须真的在目标设备上完整跑一遍，**包括装第二次**。

## musl-aarch64 wheel 生态现状（2026-09 实测基准）

**有 cp314 musl-aarch64 wheel（可直接装）**：
`pydantic-core`、`uvloop`、`httptools`、`cryptography`、`argon2-cffi-bindings`、
`psycopg-binary`、`numpy`、`pillow`、`greenlet`、`aiohttp`、`watchfiles`、
`PyYAML`、`lxml`、`orjson`、`regex`

**无 musl wheel（硬阻断）**：
- `playwright` — 只有 manylinux，且 driver/node 是 glibc 二进制
- `sqlite-vec` — 全版本无 musl，且引用 `__memcpy_chk`
- `onnxruntime` — 只有 manylinux（`cp311`）
- `tokenizers` — musl 仅到 `cp310`
- `mss` / `pynput` — 纯 py3 但依赖 X11

## 输出规范

给出的结论必须区分**三类原因**，不要混为一谈：
1. **平台阻断**：无 musl wheel / glibc 二进制 / Python 能力被裁 → 真正无解
2. **版本冲突**：pip 依赖解析打架 → 可通过钉版本解决
3. **资源不足**：内存/磁盘不够 → 换设备

最后给**明确的可行/不可行判定 + 替代方案**（通常是在 x86 宿主机用 Docker 跑，或换 glibc 设备）。
