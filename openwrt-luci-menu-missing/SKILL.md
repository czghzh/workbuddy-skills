---
name: openwrt-luci-menu-missing
description: 诊断「OpenWrt 设备上装了 luci-app-xxx / luci-i18n-xxx，但 LuCI 侧边栏里看不到那个菜单」。适用于 apk 或 opkg 设备。涵盖三条只读取证法（包文件是否到位 / 读 LuCI 菜单树缓存 / 验证会话 ACL 组）与一个高频根因模式：菜单挂的父分类没有 title，被前端 ui.js 的 getChildren() 整支丢掉（典型是老版 luci-app 用已被新版 LuCI 删除的 admin/nas 分类）。当任务是「装了包 LuCI 里没有菜单」「luci 界面不出现」「luci-app 装上了但看不到」时使用。
agent_created: true
---

# LuCI 装了包却看不到菜单 —— 诊断手册

## 什么时候用
在 OpenWrt 设备上 `apk add`（或 `opkg install`）了 `luci-app-*`，LuCI 里却没有对应菜单项；
或者装了 `luci-i18n-*` 以为会有界面。**先诊断，别急着删装包。**

## 三条只读取证（按顺序做，足够定性）

### 1. 包与文件是否到位
```sh
apk list -I 2>/dev/null | grep -iE '<app>|i18n'     # 装了哪些
ls /usr/share/luci/menu.d/ | grep -i <app>          # 菜单定义（关键）
ls /usr/share/rpcd/acl.d/ | grep -i <app>           # 权限组
ls /www/luci-static/resources/view/ | grep -i <app> # 视图
ls /usr/lib/lua/luci/i18n/ | grep -i <app>          # 翻译（*.lmo）
```
- **`luci-i18n-<app>-<lang>` 只是翻译**（`/usr/lib/lua/luci/i18n/<app>.<lang>.lmo`），
  **不提供菜单**；菜单来自 `luci-app-<app>` 的 `menu.d/*.json`。
- 顺手确认是"固件自带"还是"后装"：`/rom/<path>` vs `/overlay/upper/<path>`。
  注意 apk 安装的文件 **mtime 会被归零（Jan 1 1970）**，不能靠 mtime 判断来源；
  看 **父目录** 的 mtime（apk 写文件时会刷新目录 mtime）= 安装时刻。

### 2. 读 LuCI 的菜单树缓存（最直接，一步看到病灶）
LuCI 每次渲染会把构建好的菜单树缓存成 `/tmp/luci-indexcache.*.json`：
```sh
ssh root@<dev> 'ls -t /tmp/luci-indexcache.*.json | head -1'
ssh root@<dev> 'cat /tmp/luci-indexcache.<hash>.json' > /tmp/menu.json   # 拉到本地解析
```
用 node/python 列 `children.admin.children` 的 **title / satisfied / children**：
```
分类(admin 下)   title           satisfied  子菜单
network          Network         true       firewall,iptv,pon,...
services         Services        true       samba4        ← 正常
nas              (无)            true       samba4        ← ★ 无 title ⇒ 整支被丢
```
> 判据：**同级分类里只有它缺 `title`**（`uci`/`ubus`/`menu`/`translations` 这几个无 title 的是
> LuCI 内部功能节点，属正常，别误判）。

### 3. 会话 ACL 组是否加载（服务端过滤）
```sh
SID=$(ssh root@<dev> "ubus call session login '{\"username\":\"root\",\"password\":\"\"}' | jsonfilter -e '@.ubus_rpc_session'")
ssh root@<dev> "ubus call session access '{\"ubus_rpc_session\":\"$SID\",\"scope\":\"access-group\",\"object\":\"luci-app-<app>\"}'"
ssh root@<dev> "ubus call session destroy '{\"ubus_rpc_session\":\"$SID\"}'"   # 用完销毁
```
没有该组 ⇒ `dispatcher.uc::check_acl_depends()` 返回 `null` ⇒ 该节点 `satisfied = false` ⇒ 不显示。
（装完新包一律 `/etc/init.d/rpcd restart` + **重新登录**，ACL 组才是 rpcd 启动时加载的。）

## 根因模式（本类问题最常见的那个）
**菜单的父分类没有 `title`，整个分支被前端丢掉。**

`luci-base/ucode/dispatcher.uc::build_pagetree()` 会为缺失的中间路径**自动补节点**：
```ucode
node.children[s] ??= { satisfied: true };   // 只给 satisfied，不给 title
```
而 `luci-base/htdocs/luci-static/resources/ui.js::getChildren()`：
```js
if (!node.children[k].satisfied) continue;
if (!node.children[k].hasOwnProperty('title')) continue;   // ← 无 title ⇒ 跳过，子节点也一起丢
```
⇒ **父分类没有 title，子菜单永远不会出现**（无论刷新、重启 rpcd、重新登录）。
title 必须由某个 `menu.d/*.json` 定义。

**典型实例**：老版 `luci-app-samba4` 的菜单路径是 `admin/nas/samba4`；
新版 LuCI（2025 起）**删除了 `nas` 分类**，官方改到 `admin/services/samba4`。
于是这个"孤儿分类"没有 title ⇒ "Network Shares" 永远看不见。

## 根因之外的第二个雷：来源版本错配
**从 distfeeds（官方 / ImmortalWrt 快照镜像）装 `luci-app-*` 到自编固件上，版本与菜单结构都可能不匹配。**
```sh
apk list -I 2>/dev/null | grep -E '^luci'   # 比对版本串
# 例：luci-app-samba4-26.180.11865~972e2dc  vs  luci-base-26.264.63453~d245681
```
版本串里的 `<commit>` 段不同 ⇒ 来源不是编固件那棵树 ⇒ 要警惕菜单路径/前端 API 不匹配。

## 修法（按代价排序）
1. **装与固件同版本的 app**（首选）：用**编固件那棵树的 luci feed** 出一份 apk，
   版本串与 `luci-base` 一致；`apk add` 会按版本自动升级（新版 > 旧版）。
2. **给父分类补 title**（最小改动，1 个文件）：`/usr/share/luci/menu.d/zz-<name>.json`
   ```json
   { "admin/nas": { "title": "NAS", "order": 45,
       "action": { "type": "firstchild", "recurse": true } } }
   ```
   父节点有 title 后，子菜单立刻出现；`action` 让点击自动进第一个子页。
3. **改该 app 的菜单路径**到新版分类（如 `admin/services/<app>`）—— 直接编辑它装在
   `/usr/share/luci/menu.d/` 里的 json；注意该文件属于包，`apk` 升级时会覆盖。

## 设备侧小坑
- 这类设备的 busybox 常**没有 `stat`**，`ls --time-style=full-iso` 也可能不支持 → 用 `ls -l`。
- 新建/销毁 ubus 会话是只读诊断，不改任何配置；用完记得 `session destroy`。
- 菜单树缓存文件名带 hash（`luci-indexcache.<8hex>.json`），随 menu.d 内容变化而变。
