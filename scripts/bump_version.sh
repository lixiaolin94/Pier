#!/bin/zsh
# 切一个新版本：跑发版门禁 → 版本号 +1（只动最后一位）→ CHANGELOG「未发布」改成版本号 → 提交 → 打 tag。
# 加 --push 会推送 main 和 tag，然后在本机签名、公证并发布 GitHub Release（scripts/publish.sh，docs/RELEASE.md）。
#
#   scripts/bump_version.sh            # 0.1.1 → 0.1.2
#   scripts/bump_version.sh 0.2.0      # 指定版本：只在用户认可"这个版本 OK 了"时用
#   scripts/bump_version.sh --push
set -euo pipefail
cd "$(dirname "$0")/.."

PUSH=0
TARGET=""
for arg in "$@"; do
  case "$arg" in
    --push) PUSH=1 ;;
    *) TARGET="$arg" ;;
  esac
done

[[ -z "$(git status --porcelain)" ]] || { echo "✗ 工作区不干净，先提交或清理"; exit 1; }
[[ "$(git branch --show-current)" == "main" ]] || { echo "✗ 只在 main 上发版"; exit 1; }

CURRENT=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)
if [[ -z "$TARGET" ]]; then
  TARGET="${CURRENT%.*}.$(( ${CURRENT##*.} + 1 ))"
fi
[[ "$TARGET" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "✗ 版本号格式不对：$TARGET"; exit 1; }
# 新版本必须更大（Sparkle 靠它判断有没有更新）
[[ "$(printf '%s\n%s\n' "$CURRENT" "$TARGET" | sort -V | tail -1)" == "$TARGET" && "$CURRENT" != "$TARGET" ]] \
  || { echo "✗ $TARGET 不比当前 $CURRENT 新"; exit 1; }
git rev-parse -q --verify "refs/tags/v$TARGET" >/dev/null && { echo "✗ tag v$TARGET 已存在"; exit 1; }

# CHANGELOG 的「未发布」一节不能是空的：每个版本都要说清改了什么
UNRELEASED=$(awk '/^## 未发布/ {on=1; next} /^## / {on=0} on && NF' CHANGELOG.md)
[[ -n "$UNRELEASED" ]] || { echo "✗ CHANGELOG.md 的「## 未发布」是空的"; exit 1; }

echo "▸ 门禁 1/2：PierKit 单元测试"
(cd Packages/PierKit && swift test 2>&1 | tail -1)
(cd Packages/PierKit && swift test >/dev/null 2>&1) || { echo "✗ 单元测试失败"; exit 1; }

echo "▸ 门禁 2/2：Release 构建（零警告）"
xcodegen generate --quiet
LOG=$(xcodebuild -project Pier.xcodeproj -scheme Pier -configuration Release -derivedDataPath build/DerivedData build 2>&1)
echo "$LOG" | grep -q "BUILD SUCCEEDED" || { echo "$LOG" | grep -E "error:" | head; echo "✗ 构建失败"; exit 1; }
WARNINGS=$(echo "$LOG" | grep -E "^/.*warning:" | sort -u || true)
[[ -z "$WARNINGS" ]] || { echo "$WARNINGS"; echo "✗ 有编译警告"; exit 1; }

echo "▸ $CURRENT → $TARGET"
sed -i '' "s/MARKETING_VERSION: \"$CURRENT\"/MARKETING_VERSION: \"$TARGET\"/" project.yml
xcodegen generate --quiet
DATE=$(date +%Y-%m-%d)
sed -i '' "s/^## 未发布$/## 未发布\\
\\
## $TARGET — $DATE/" CHANGELOG.md

git add project.yml Pier.xcodeproj CHANGELOG.md
git commit -q -m "release: $TARGET"
git tag -a "v$TARGET" -m "Pier $TARGET"
echo "✓ 已提交并打 tag v$TARGET"

if (( PUSH )); then
  git push origin main
  git push origin "v$TARGET"
  scripts/publish.sh
else
  echo "确认无误后：git push origin main && git push origin v$TARGET && scripts/publish.sh"
fi
