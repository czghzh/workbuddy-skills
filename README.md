# workbuddy-skills

给 AI 编程助手（WorkBuddy / CodeBuddy）写的一批**自建技能**，领域集中在
OpenWrt 固件编译、Airoha 光猫移植、嵌入式设备调试。

每个子目录是一个技能，入口文件是 `SKILL.md`（YAML frontmatter + Markdown 正文）。
助手在遇到匹配的任务时会读它，把踩过的坑、验证过的命令、判据直接复用，
不用每次都从零摸索。

## 内容

| 技能 | 用途 |
|---|---|
| `airoha-hw-offload-verify` | 判定 Airoha（AN7581/EN7581）光猫上某个转发方向**有没有真的走硬件卸载**，含单向卸载、代理流量不卸载、无线客户端双向不卸载的判据 |
| `luci-block-overlay-customize` | 改造 LuCI 页面，覆盖层（`files/`）与独立 apk 两条路 |
| `musl-aarch64-python-install-feasibility` | 在 musl aarch64 设备上评估并实做 Python 项目安装 |
| `openwrt-apk-external-package` | 把外部项目打成 OpenWrt apk 包 |
| `openwrt-brick-offline-triage` | 离线定位 OpenWrt 变砖根因 + 固化内核补丁 |
| `openwrt-device-port-from-vendor-tree` | 把厂商树里的设备移植到主线 OpenWrt |
| `openwrt-device-probe` | 通过跳板机探测 OpenWrt / 嵌入式设备 |
| `openwrt-firmware-defaults` | 改 OpenWrt 固件的出厂默认项 |
| `openwrt-luci-menu-missing` | LuCI 装了包却看不到菜单的诊断手册 |
| `openwrt-offline-kmod-repo` | 给 OpenWrt 设备做设备内离线 kmod 源（含 7 个配套脚本） |
| `openwrt-usb-tree-disk-loss-recovery` | 外置盘上的 OpenWrt 源码树掉盘 / 换盘后的恢复 |
| `openwrt-wifi-txpower-regdb` | OpenWrt WiFi 发射功率与 regdb 调整 |
| `trae-relay-model-audit` | 给 Trae CN 反代暴露的模型做批量体检：哪些真会调客户端工具、费用排序、选型建议 |
| `vendor-ko-mainline-port` | 厂商预编译 .ko → 主线内核移植与打包（含 vermagic 替换脚本） |

共 14 个技能、25 个文件。

## 来源

这些技能不是写的文档，是**实际调通过的东西**：命令在真机上跑过、判据用输出验证过、
坑是真踩了才记下来的。每个技能末尾通常都有「怎么验证它生效」一节。

## 怎么用

放到助手的技能目录里即可，每个技能一个子目录：

```
~/.workbuddy/skills/<skill-name>/SKILL.md
```

```bash
git clone git@github.com:czghzh/workbuddy-skills.git
cp -r workbuddy-skills/*/ ~/.workbuddy/skills/
```

助手按 `SKILL.md` frontmatter 里的 `description` 判断什么时候读它，不需要额外配置。

## 有意不含什么

- **第三方技能**（如 `ponytail` 系列）没有收进来 —— 那些有上游仓库，
  直接从上游装。
- **任何凭据、私钥、内网拓扑**。涉及真实设备登录信息的技能被整体排除，
  不脱敏、不留半截。仓库里剩下的都是方法学文字。

`openwrt-offline-kmod-repo` 等技能里提到的 `private-key.pem`
指的是 OpenWrt 构建树自己生成的 APK 签名钥匙路径，钥匙文件本身不在这个仓库里。

## 同步

`sync.sh` 一条命令完成「从技能目录同步 → 扫敏感词 → 提交 → 推送」：

```bash
./sync.sh                  # 同步 + 扫描 + 提交 + 推送
./sync.sh --check          # 只同步 + 扫描，不提交不推送
```

扫描门禁留空才允许推送；扫出东西会停下报错，不会硬推。

## License

[MIT](LICENSE)
