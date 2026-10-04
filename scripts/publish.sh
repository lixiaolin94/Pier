#!/bin/zsh
# 在本机发布当前版本：release.sh（签名 + 公证）→ make_appcast.sh（Sparkle 签名）→ GitHub Release。
# 由 bump_version.sh --push 在推送 tag 之后调用，也可以单独运行（比如公证失败后重试）。
#
# 前提（一次性）：
#   - 登录钥匙串里有 Developer ID Application 证书（Xcode 已经装好）
#   - Sparkle EdDSA 私钥在登录钥匙串里（与 Inbox 共用）
#   - notarytool 钥匙串 profile，见 release.sh 头注释
#   - gh 已登录
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)
TAG="v$VERSION"

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "✗ 本地没有 tag $TAG（先跑 bump_version.sh）"; exit 1; }
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "$TAG^{commit}")" ]] || { echo "✗ 当前提交不是 $TAG，先 git checkout $TAG"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "✗ 工作区不干净"; exit 1; }
if gh release view "$TAG" >/dev/null 2>&1; then echo "✗ GitHub 上已经有 $TAG 的 Release"; exit 1; fi

# 公证过的包已经在了（比如上次在后面的步骤失败）就不重复构建；SKIP_BUILD=0 强制重来
if [[ "${SKIP_BUILD:-auto}" == auto && -f build/release/Pier-$VERSION.zip ]] \
   && spctl -a -t install build/release/export/Pier.app >/dev/null 2>&1; then
  echo "▸ 复用已公证的 build/release/Pier-$VERSION.zip"
else
  scripts/release.sh
fi

# 私钥从钥匙串导出到临时目录（generate_keys -x 拒绝覆盖已存在的文件，所以不能用 mktemp 建好的文件），用完就删
KEY_DIR=$(mktemp -d)
KEY_FILE="$KEY_DIR/sparkle_ed_key"
trap 'rm -rf "$KEY_DIR"' EXIT
SPARKLE_VERSION=$(sed -n 's/^SPARKLE_VERSION=\([0-9.]*\).*/\1/p' scripts/make_appcast.sh)
if [[ ! -x build/sparkle-tools/bin/generate_keys ]]; then
  mkdir -p build/sparkle-tools
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    | tar -xJ -C build/sparkle-tools
fi
build/sparkle-tools/bin/generate_keys -x "$KEY_FILE" >/dev/null
SPARKLE_ED_PRIVATE_KEY="$(cat "$KEY_FILE")" scripts/make_appcast.sh
rm -rf "$KEY_DIR"

NOTES=$(mktemp)
awk -v v="## $VERSION" 'index($0, v) == 1 {on=1; next} /^## / {on=0} on' CHANGELOG.md > "$NOTES"
gh release create "$TAG" build/release/Pier-"$VERSION".zip build/release/appcast.xml \
  --title "Pier $VERSION" --notes-file "$NOTES" --verify-tag
rm -f "$NOTES"
echo "✓ 已发布 https://github.com/lixiaolin94/Pier/releases/tag/$TAG"
