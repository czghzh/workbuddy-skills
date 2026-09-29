#!/bin/bash
# 把本地 apk 仓库部署到 515xg 设备，挂成"指向本机"的本地源，并逐项验证。
#
# 用法: deploy-repo.sh [设备IP] [仓库目录]
#   默认: 192.168.1.1  /home/wen/kmods-p1
#   阶段 2 全量时: deploy-repo.sh 192.168.1.1 /home/wen/kmods-full
#
# 设计要点 / 踩过的坑:
#   * 设备上**没有 rsync**（OpenWrt 默认不装），走 tar | ssh tar。
#   * 落点 /www/kmods（uhttpd 默认 listen_http 0.0.0.0:80 + home=/www ⇒ 127.0.0.1 命中）。
#   * 源写 /etc/apk/repositories.d/customfeeds.list（conffile，跨 sysupgrade 保留），
#     内容就是**一行索引文件全路径**，没有 src/gz 前缀（apk 3 格式）。
#   * /www 在 overlay 上 ⇒ 每次 sysupgrade 后要重新跑本脚本。
#   * 验证步骤**故意不用 set -e**、也不把多条命令用 && 串在一起：一次无关失败会让整段
#     验证中途退出，看起来像"这一步没过"，其实是脚本自己的串法错了（v1 就这么坑过一次：
#     装了 wireguard 却去 modprobe 没装的 veth，&& 链断掉，后面几步全没跑）。
#     每条命令单独跑、单独判、最后汇总 PASS/FAIL。
set -uo pipefail

DEV=${1:-192.168.1.1}
REPO=${2:-/home/wen/kmods-p1}
SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 root@$DEV"

[ -d "$REPO" ] || { echo "✘ 仓库目录不存在: $REPO"; exit 1; }
[ -f "$REPO/packages.adb" ] || { echo "✘ 缺索引 $REPO/packages.adb"; exit 1; }

PASS=0; FAIL=0
ok()  { echo "  ✔ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✘ $1"; FAIL=$((FAIL+1)); }

echo "===== 1) 设备现状 ====="
$SSH "grep -A1 '^P:kernel\$' /lib/apk/db/installed | tail -1; df -h /overlay | tail -1; mount | grep ' /rom '"

echo
echo "===== 2) 上传仓库（tar over ssh） ====="
$SSH 'mkdir -p /www/kmods' || { echo "✘ 无法建 /www/kmods"; exit 1; }
tar -C "$REPO" -cf - . | $SSH 'tar -C /www/kmods -xf -' || { echo "✘ 上传失败"; exit 1; }
LOCAL_N=$(ls "$REPO"/*.apk | wc -l)
REMOTE_N=$($SSH 'ls /www/kmods/*.apk | wc -l')
echo "  宿主机包数=$LOCAL_N  设备包数=$REMOTE_N"
[ "$LOCAL_N" = "$REMOTE_N" ] && ok "包数一致" || bad "包数不一致"

echo
echo "===== 3) 写本地源 ====="
$SSH 'echo http://127.0.0.1/kmods/packages.adb > /etc/apk/repositories.d/customfeeds.list'
$SSH 'cat /etc/apk/repositories.d/customfeeds.list'

echo
echo "===== 4) HTTP 可达性 ====="
LSZ=$(stat -c%s "$REPO/packages.adb")
RSZ=$($SSH 'wget -qO /tmp/kmods-idx.adb http://127.0.0.1/kmods/packages.adb && wc -c < /tmp/kmods-idx.adb' 2>/dev/null)
echo "  宿主机索引=$LSZ  设备取到=$RSZ"
[ "$LSZ" = "$RSZ" ] && ok "索引经 HTTP 取到且字节一致" || bad "索引取不到或字节不一致"

echo
echo "===== 5) 只用本地源装"带依赖"的 kmod（关键验证） ====="
$SSH 'apk --repositories-file /dev/null --repository http://127.0.0.1/kmods/packages.adb add kmod-wireguard'
DEPN=$($SSH 'apk info 2>/dev/null | grep -cE "^kmod-(crypto-lib-chacha20poly1305|crypto-lib-curve25519|udptunnel4)$"')
[ "${DEPN:-0}" -ge 3 ] && ok "依赖闭包被自动补齐（chacha20poly1305/curve25519/udptunnel4 都在）" \
                       || bad "依赖没齐（只找到 $DEPN 个）"
$SSH 'modprobe wireguard' && ok "wireguard 模块可加载" || bad "wireguard 加载失败"

echo
echo "===== 6) 再从本地源装 veth/dummy，并真建接口 ====="
$SSH 'apk --repositories-file /dev/null --repository http://127.0.0.1/kmods/packages.adb add kmod-veth kmod-dummy' >/dev/null 2>&1
$SSH 'modprobe veth' && ok "veth 可加载" || bad "veth 加载失败"
$SSH 'modprobe dummy' && ok "dummy 可加载" || bad "dummy 加载失败"
$SSH 'ip link add v0 type veth peer name v1; ip link set v0 up; ip link set v1 up; ip -br link show v0; ip link del v0' \
  && ok "veth 对可建可删" || bad "veth 对建不起来"

echo
echo "===== 7) 走正常路径（带 distfeeds）装一个，模拟以后自动补依赖 ====="
if $SSH 'ping -c1 -W2 223.5.5.5 >/dev/null 2>&1'; then
  $SSH 'apk add kmod-tun' >/dev/null 2>&1 && ok "正常路径装成 kmod-tun" || bad "正常路径装失败"
else
  echo "  ! 设备当前出不去网（没配 WAN），跳过；kmod 依赖仍可由本地源满足"
fi

echo
echo "===== 8) 空间与只读层 ====="
$SSH 'df -h /overlay | tail -1; echo -n "/www/kmods: "; du -sh /www/kmods | cut -f1'
$SSH 'mount | grep " /rom " | grep -q "ro,"' && ok "/rom 仍是只读（未被写）" || bad "/rom 状态异常"

echo
echo "======================================"
echo "  验证结果: PASS=$PASS  FAIL=$FAIL"
echo "======================================"
echo "⚠️ 提醒：这台设备永远不要跑 apk upgrade（distfeeds 里有官方 snapshot 的"
echo "   kernel/base-files，会覆盖掉你的自编译内核）。"
[ "$FAIL" -eq 0 ] || exit 1
