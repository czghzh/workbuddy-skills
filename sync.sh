#!/usr/bin/env bash
# 同步 ~/.workbuddy/skills/ → 本仓库 → 推送。
#   ./sync.sh           # 同步 + 扫描 + 提交 + 推送
#   ./sync.sh --check   # 只同步 + 扫描，不提交不推送
#
# 扫描门禁：扫出凭据就 exit 1，不硬推。

set -euo pipefail

SRC="${HOME}/.workbuddy/skills/"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# ── 不同步的东西 ────────────────────────────────────────────────
# pcdn-niulink-box : 正文里写死了真实密码和内网 IP，整体排除
# ponytail*        : 第三方 MIT 技能，有上游仓库，从上游装
# /*.json          : WorkBuddy 本地迁移标记，顶层的才排
# 下面五个是本仓库自己的文件，必须排除，否则 --delete 会删掉它们
# .git 必须排除：漏了它 rsync --delete 会把仓库的版本库本体删掉（2026-10-01 踩过的雷）
EXCLUDES=(
  --exclude='.git'
  --exclude='pcdn-niulink-box'
  --exclude='ponytail*'
  --exclude='/*.json'
  --exclude='README.md'
  --exclude='LICENSE'
  --exclude='.gitignore'
  --exclude='sync.sh'
)

# ── 1. 同步 ─────────────────────────────────────────────────────
echo "==> rsync  $SRC  ->  \$REPO/"
rsync -a --delete "${EXCLUDES[@]}" "$SRC" "$REPO/"

# ── 2. 扫描门禁 ─────────────────────────────────────────────────
fail=0

scan_block() {
  local label="$1" pat="$2"
  # 用 -e 明确指定正则为 pattern，避免 pattern 被当成 grep 选项。
  # \x60 / \x27 / \x22 表示反引号 / 单引号 / 双引号 —— 免得在 shell 引号里
  # 转义反引号（双引号内的反引号会被当成命令替换执行）。
  local hits
  hits=$(grep -rnIP --exclude='sync.sh' --exclude-dir='.git' -e "$pat" . 2>/dev/null || true)
  if [ -n "$hits" ]; then
    echo "✗  阻断：$label"
    echo "$hits" | sed 's/^/     /'
    fail=1
  else
    echo "✓  $label"
  fi
}

scan_warn() {
  local label="$1" pat="$2"
  local hits
  hits=$(grep -rnIP --exclude='sync.sh' --exclude-dir='.git' -e "$pat" . 2>/dev/null || true)
  if [ -n "$hits" ]; then
    echo "!  提示：$label（不阻断，请确认是示例数据）"
    echo "$hits" | head -8 | sed 's/^/     /'
  fi
}

echo
echo "==> 扫描门禁"

# 阻断项：凭据与钥匙
scan_block "私钥块"              'BEGIN (RSA|OPENSSH|EC|DSA|PGP|ENCRYPTED) PRIVATE KEY'
# 中文密码：必须用反引号包值（Markdown 写法），或写成「密码：值」。
# 不加这个约束会命中正文里的叙述性文字，如「一旦刷成"有密码"的镜像」。
scan_block "密码写死在正文"       '密码[均为]*[[:space:]]*\x60|密码[均为]*[[:space:]]*[:：][[:space:]]*[\x60\x27\x22]'
scan_block "password 赋值"        'password[[:space:]]*[:=][[:space:]]*[\x60\x27\x22]'
scan_block "API token / secret"   '(api[_-]?token|secret[_-]?key|access[_-]?token|apikey)[[:space:]]*[:=][[:space:]]*[\x60\x27\x22]'
scan_block "Bearer 令牌"          'Bearer[[:space:]]+[A-Za-z0-9._~-]{16,}'

# 提示项：网络拓扑（示例数据里允许出现，人工确认）
scan_warn "IPv4 地址"  '(?<![0-9.])(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9]{1,2})\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9]{1,2})(?![0-9.])'
scan_warn "MAC 地址"   '(?i)(?:[0-9a-f]{2}:){5}[0-9a-f]{2}'

if [ "$fail" -ne 0 ]; then
  echo
  echo "✗  扫描未通过，已停止。处理上面的问题再跑。"
  exit 1
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo
  echo "==> --check：扫描通过，未提交未推送。"
  exit 0
fi

# ── 3. 提交 + 推送 ──────────────────────────────────────────────
cd "$REPO"
git add -A
if git diff --cached --quiet; then
  echo
  echo "==> 没有变更，无需提交。"
  exit 0
fi

echo
echo "==> 本次变更"
git diff --cached --stat | sed 's/^/     /'
git commit -q -m "sync skills: $(date +%Y-%m-%d)"
git push origin main

echo
echo "✓  已推送。"
