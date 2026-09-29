---
name: openwrt-wifi-txpower-regdb
description: OpenWrt/ImmortalWrt 设备 WiFi 发射功率的诊断与调整：读 mt76 真实功率表、regdb 钳制原理、打补丁重编、设备立即生效的正确姿势。适用于"功率低/虚标/改成驱动默认"类问题。
agent_created: true
---

# OpenWrt WiFi 发射功率与 regdb 调整

## 原理（先懂再动）

1. **三层功率**：EEPROM 校准值（硬件真实能力）→ regdb 法规上限（钳制）→ 显示值（iwinfo）。
   最终功率 = min(校准, 法规)。mt76 双链显示值 = (每链半dB值 + 6) / 2（`mt76_tx_power_path_delta`
   = {0,6,9,12,14} 半 dB，双链合成 +3 dB，见 `mt76.h`）。
2. **真实功率表**：`/sys/kernel/debug/ieee80211/phy*/mt76/txpower_sku`（0.5 dBm 单位，每速率一行）。
   表被钳平（全是同一个数）= regdb 钳制生效；逐速率起伏 = 未钳制。`Tx power (bbp)` 是 bbp 目标。
3. **对照芯片标称**：MT7916AN 模块规格（如 AW7916）11b 23±1.5 / 11g 21±1.5 / 5G HE20 20±1.5 dBm。
   校准值应落在标称 ±1.5 内；regdb 写 30 只意味着"不钳制"（硬件根本发不到 30）。

## 诊断步骤

```sh
iwinfo phy0-ap0 | grep Tx-Power     # 显示值（EIRP 概念）
iw reg get                           # 当前法规表（每频段上限）
iw phy1 info | sed -n '/Band 2:/,/Band 3:/p'   # 每信道上限（regdb 钳制结果）
cat /sys/kernel/debug/ieee80211/phy0/mt76/txpower_sku   # 真实每速率表
md5sum /lib/firmware/regulatory.db   # 与其他设备/上游原版对比
# regdb 来源核对：OpenWrt 树 package/firmware/wireless-regdb/（db2fw.py 从 db.txt 生成）；
# dl/wireless-regdb-*.tar.xz 解包可得上游原版 db.txt 的 CN 段
```

## 改功率的正确路径（树里固化）

1. **打补丁**：`package/firmware/wireless-regdb/patches/501-*.patch`，改 `db.txt` 的 CN 段
   （不要拷二进制——包是 `db2fw.py` 从 db.txt 源码生成的，补丁进 git 可见可复现）。
   **陷阱**：db.txt 里多个国家有完全相同的行，`sed` 全局替换会误伤；必须用行号范围限定
   `sed -i '471,476s/…/…/' db.txt`，改完 `diff -u db.txt.orig db.txt` 逐行核对只动了目标国家。
2. **数值选法**："驱动默认=不钳制" 是诚实写法：EEPROM 每链值 ×2链 +3 dB。
   例：每链 23 → 写 26。写 30 效果等价但虚；写低于 26 会真的钳。
3. **重编**：净化环境（见宿主机 safe-bin 规则）→
   `make package/firmware/wireless-regdb/clean package/firmware/wireless-regdb/compile -j8`
   （PKG_CONFIG_DEPENDS 不含该包时必须 clean，否则不重编）。
4. **验证**：build_dir 里 `regulatory.db` md5 变化；最终镜像里抠出的与产物一致。

## 设备立即生效（不刷机的正确姿势）

替换 `/lib/firmware/regulatory.db` 后：
- `wifi reload` **无效**（内核只在启动时读 regdb 文件）；
- `iw reg reload` 只更新 `iw reg get` 的规则表，**mt76 固件功率表不会重建**（sku 不变）；
- **有效**：`uci set wireless.radio0.country=DE; uci commit wireless; wifi reload`，
  等几秒，再切回 `CN` 再 `wifi reload`。之后 sku 表恢复逐速率起伏、显示值到位。
- 回滚：overlay 里 `rm /lib/firmware/regulatory.db`（删上层副本露出 ROM 版）+ 同上切换流程。

## 其他坑

- 抠镜像 rootfs：先魔数定位 `data.find(b"hsqs")`（FIT 结构变了 offset 会漂，别用旧记录的固定值）。
- `scp` 到 OpenWrt 设备报 `sftp-server not found`：改 ssh 管道 `cat | ssh 'cat > file'`。
- 换镜像源前用 curl 逐条验 200；ImmortalWrt aarch64 官方**没有 video feed**（OpenWrt 才有）。
- 固化源进树：顶层 `files/` 覆盖 `/etc/apk/repositories.d/distfeeds.list`（rootfs 组装后覆盖，
  产物 root-airoha/ 可直接验证）；本地源走 `customfeeds.list`（conffile，跨刷机保留），
  两者不冲突。`.gitignore` 的 `/files/*` 会拦住新增子目录，需加 `!/files/etc/` 白名单。
