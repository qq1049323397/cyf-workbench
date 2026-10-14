#!/usr/bin/env bash
# sync-site.sh —— 把工作台的最新版同步成本仓库的 index.html，然后提交推送。
#
#   用法（在本仓库根目录执行）:
#     tools/sync-site.sh                    # 用默认源码路径
#     tools/sync-site.sh /path/to/CYF综合工作台.html
#     SOURCE=/path/to/x.html tools/sync-site.sh
#
#   环境变量:
#     SOURCE      工作台源码路径（也可以用第一个参数给）
#     NO_PUSH=1   只提交不推送
#     NO_VERIFY=1 跳过发布前检查
#     MSG         自定义提交信息
#
# 它做的事：
#   1. 从源码里读出 WORKBENCH_VERSION，和当前 index.html 的版本比对
#   2. 复制成 index.html
#   3. 发布前检查：文件能打开、版本角标对得上、几个关键断言过
#   4. git add / commit / push
#
# 版本没变也会照常同步（可能只是改了别的东西），但会提示你版本号没动。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SOURCE="${1:-${SOURCE:-/home/ubuntu/RP-Hub/CYF综合工作台/CYF综合工作台.html}}"
[ -f "$SOURCE" ] || { echo "✗ 找不到工作台源码: $SOURCE" >&2; echo "  用法: tools/sync-site.sh <路径>" >&2; exit 2; }

read_version() {
  grep -oE "const WORKBENCH_VERSION='[^']+'" "$1" 2>/dev/null | head -1 | sed "s/.*'\(.*\)'/\1/"
}

NEW_VER="$(read_version "$SOURCE")"
OLD_VER="$(read_version index.html 2>/dev/null || true)"
[ -n "$NEW_VER" ] || { echo "✗ 源码里读不到 WORKBENCH_VERSION，先确认文件对不对" >&2; exit 2; }

echo "源码   : $SOURCE"
echo "新版本 : v$NEW_VER"
echo "当前   : v${OLD_VER:-（无）}"
if [ "$NEW_VER" = "$OLD_VER" ]; then
  echo "提示   : 版本号和线上一样，如果这次改了功能，记得把源码里的 WORKBENCH_VERSION 往上提一档。"
else
  echo "版本   : v${OLD_VER:-?} → v$NEW_VER"
fi
echo

# —— 复制 ——
cp "$SOURCE" index.html
chmod 644 index.html
echo "✓ 已更新 index.html（$(du -h index.html | cut -f1)）"

# —— 发布前检查 ——
if [ "${NO_VERIFY:-0}" != "1" ]; then
  WB_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  if [ -x "$WB_DIR/tools/probe-http.sh" ] && [ -f "$WB_DIR/tools/asserts/version.js" ]; then
    echo "→ 检查：HTTP 下能否正常启动、版本角标对不对"
    if "$WB_DIR/tools/probe-http.sh" "$REPO_ROOT" "$WB_DIR/tools/asserts/version.js" 30000 >/tmp/sync-verify.log 2>&1; then
      grep -E '^(declared_version|badge_text|version_ok)=' /tmp/sync-verify.log | sed 's/^/    /'
      echo "✓ 启动检查通过"
    else
      echo "✗ 启动检查没过，没有提交。详情：" >&2
      sed 's/^/    /' /tmp/sync-verify.log >&2
      echo "  确认没问题就加 NO_VERIFY=1 跳过。" >&2
      exit 1
    fi
  else
    echo "提示：找不到 probe-http.sh，跳过启动检查"
  fi
fi

# —— 提交推送 ——
if git diff --quiet -- index.html && git diff --cached --quiet -- index.html; then
  echo "index.html 内容和已提交的一模一样，没什么要提交的。"
  exit 0
fi

git add index.html
MSG="${MSG:-site: 更新到 v$NEW_VER}"
git commit -q -m "$MSG"
echo "✓ 已提交: $MSG"

if [ "${NO_PUSH:-0}" = "1" ]; then
  echo "NO_PUSH=1，跳过推送。要推送就自己跑: git push"
  exit 0
fi

git push
echo "✓ 已推送。服务器那边 git pull 一次就生效了。"
