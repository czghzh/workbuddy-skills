#!/bin/sh
# Airoha (AN7581/EN7581) 硬件卸载体检
# 用法：ssh -o StrictHostKeyChecking=no root@<IP> 'sh -s' < probe-offload.sh
# 只读，不改任何配置。

B=/sys/kernel/debug/ppe/bind
C=/sys/kernel/debug/ppe/config
NP="CDM1 GDM1 GDM2 GDM3 PPE1 CDM2 CDM3 CDM4 PPE2 GDM4 CDM5 . . . . DROP"
IF() { cat /sys/class/net/$1/statistics/$2 2>/dev/null; }
name() { echo $NP | cut -d' ' -f$(( $1 + 1 )); }
sepp() { v=$((0x$1)); echo $(( (v >> 5) & 15 )); }
fp()   { v=$((0x$1)); echo $(( (v >> 10) & 1 )); }

echo "===================== 0) 基本状态 ====================="
echo "uptime: $(cut -d' ' -f1 /proc/uptime) s"
echo
echo "--- ppe/config ---"
cat $C 2>&1
echo
echo "--- flowtable devices ---"
nft list flowtables 2>&1 | grep -A2 'flowtable'
echo
echo "--- conntrack 规模 ---"
echo "  总条目        : $(grep -c . /proc/net/nf_conntrack 2>/dev/null)"
echo "  [HW_OFFLOAD]  : $(grep -c HW_OFFLOAD /proc/net/nf_conntrack 2>/dev/null)"
echo "  [UNREPLIED]   : $(grep -c UNREPLIED /proc/net/nf_conntrack 2>/dev/null)  (这些本来就不该卸载)"

echo
echo "===================== 1) FOE 表方向分布 ====================="
echo "BND 总条目  : $(grep -c ' BND ' $B 2>/dev/null)"
grep 'BND IPv4' $B 2>/dev/null | grep -c 'orig=192\.168\.\|orig=10\.\|orig=172\.1[6-9]\.\|orig=172\.2[0-9]\.\|orig=172\.3[01]\.' \
  | sed 's/^/  IPv4 LAN→WAN(orig=内网) : /'
grep 'BND IPv4' $B 2>/dev/null | grep -vc 'orig=192\.168\.\|orig=10\.\|orig=172\.1[6-9]\.' \
  | sed 's/^/  IPv4 WAN→LAN(orig=公网) : /'
grep 'BND IPv6' $B 2>/dev/null | grep -c 'orig=2409:\|orig=2408:\|orig=240e:\|orig=2400:\|orig=fd' \
  | sed 's/^/  IPv6 LAN→WAN(orig=内网) : /'

echo
echo "===================== 2) 出口端口 PSE_PORT 分布 ====================="
echo "  (2=GDM2 uplink loopback, 9=GDM4 LAN 口, FAST_PATH=1 只出现在 LAN 出口)"
for fam in IPv4 IPv6; do
  echo "  --- $fam ---"
  grep "BND $fam" $B 2>/dev/null | sed -n 's/.*ib2=\([0-9a-f]*\).*/\1/p' | while read -r h; do
    p=$(sepp $h); f=$(fp $h); echo "    PSE_PORT=$p ($(name $p))  FAST_PATH=$f"
  done | sort | uniq -c | sort -rn
done

echo
echo "===================== 3) 样本 ====================="
echo "--- LAN→WAN（orig=内网）前 4 条 ---"
grep 'BND IPv4' $B 2>/dev/null | grep 'orig=192\.168\.' | head -4 | while read -r l; do
  ib=$(echo "$l" | sed -n 's/.*ib2=\([0-9a-f]*\).*/\1/p'); p=$(sepp $ib); f=$(fp $ib)
  echo "  ${l%% eth=*}  ==> pse=$p($(name $p)) fp=$f"
done
echo "--- WAN→LAN（orig=公网）前 4 条 ---"
grep 'BND IPv4' $B 2>/dev/null | grep -v 'orig=192\.168\.\|orig=10\.' | head -4 | while read -r l; do
  ib=$(echo "$l" | sed -n 's/.*ib2=\([0-9a-f]*\).*/\1/p'); p=$(sepp $ib); f=$(fp $ib)
  echo "  ${l%% eth=*}  ==> pse=$p($(name $p)) fp=$f"
done

echo
echo "===================== 4) 流量路径（35 秒两拍）====================="
snap() {
  echo "### $1"
  awk 'NR>1 && $1=="Ip:"{printf "  Ip: ForwDatagrams=%s InReceives=%s InDelivers=%s OutRequests=%s\n",$7,$4,$10,$11}' /proc/net/snmp
  echo "  cpu: $(grep '^cpu ' /proc/stat)"
  for i in pon0 pppoe-wan br-lan phy0-ap0 phy1-ap0 lan1 lan2 lan3 lan4; do
    [ -d /sys/class/net/$i ] && printf "  %-10s rx=%s tx=%s\n" "$i" "$(IF $i rx_packets)" "$(IF $i tx_packets)"
  done
  echo "  HW_OFFLOAD=$(grep -c HW_OFFLOAD /proc/net/nf_conntrack 2>/dev/null)"
}
snap T0
sleep 35
echo
snap "T1(+35s)"
echo
echo "判读：把 (上行 = LAN口rx 与 pon0tx)、(下行 = pon0rx 与 LAN口tx) 各自做差，"
echo "      再看 Ip:InReceives 增量 —— 若远小于 pon0 总量 ⇒ 绝大部分由硬件转发。"
