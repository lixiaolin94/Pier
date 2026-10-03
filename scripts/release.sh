#!/bin/zsh
# 正式包：archive → Developer ID 导出 → 公证 → staple → zip，产物在 build/release/。
# CI（.github/workflows/release.yml）和本地备用路径共用这个脚本，流程见 docs/RELEASE.md。
#
# 公证凭据二选一：
#   - CI：ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID（App Store Connect API key）
#   - 只检查构建、不公证：SKIP_NOTARIZE=1
#   - 本地：notarytool 钥匙串 profile（NOTARY_PROFILE，默认 inbox-notary，账号级凭据，与 Inbox 共用）
#       xcrun notarytool store-credentials inbox-notary \
#         --apple-id <Apple ID> --team-id YWQ4TY4VR5 --password <App 专用密码>
set -euo pipefail
setopt null_glob   # 全新 checkout 时 build/release/*.zip 没有匹配，zsh 默认会直接报错中止
cd "$(dirname "$0")/.."
OUT=build/release
ARCHIVE=$OUT/Pier.xcarchive
EXPORT=$OUT/export
VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)

if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  NOTARY=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
else
  NOTARY=(--keychain-profile "${NOTARY_PROFILE:-inbox-notary}")
fi

rm -rf "$ARCHIVE" "$EXPORT" $OUT/Pier-*.zip
mkdir -p $OUT

echo "▸ 生成工程"
xcodegen generate --quiet

echo "▸ archive（Release，hardened runtime，Developer ID）"
xcodebuild -project Pier.xcodeproj -scheme Pier -configuration Release \
  -archivePath "$ARCHIVE" archive \
  | grep -E "error:|warning: .*sign|ARCHIVE (SUCCEEDED|FAILED)"

echo "▸ 导出"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$EXPORT" \
  | grep -E "error:|EXPORT (SUCCEEDED|FAILED)"
APP="$EXPORT/Pier.app"

echo "▸ 自检：签名、版本"
# 先存下来再 grep：pipefail 下 grep -q 提前退出会让 codesign 收到 SIGPIPE，整条管道判为失败
SIGNATURE_INFO=$(codesign -dvv "$APP" 2>&1)
[[ "$SIGNATURE_INFO" == *"Authority=Developer ID Application"* ]] || { echo "✗ 不是 Developer ID 签名"; exit 1; }
[[ "$SIGNATURE_INFO" == *"(runtime)"* ]] || { echo "✗ 没有 hardened runtime"; exit 1; }
codesign --verify --deep --strict "$APP"
BUILT=$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)
[[ "$BUILT" == "$VERSION" ]] || { echo "✗ 包内版本 $BUILT ≠ project.yml $VERSION"; exit 1; }
[[ -n "$(defaults read "$PWD/$APP/Contents/Info" SUPublicEDKey 2>/dev/null)" ]] || { echo "✗ 缺 SUPublicEDKey"; exit 1; }

if [[ "${SKIP_NOTARIZE:-0}" == 1 ]]; then
  # 只用于本地检查前面几步；这样的包不能发布
  echo "▸ 跳过公证（SKIP_NOTARIZE=1）"
else
  echo "▸ 公证"
  ditto -c -k --keepParent "$APP" $OUT/Pier-notarize.zip
  xcrun notarytool submit $OUT/Pier-notarize.zip "${NOTARY[@]}" --wait
  rm $OUT/Pier-notarize.zip

  echo "▸ staple + Gatekeeper 校验"
  xcrun stapler staple "$APP"
  spctl -a -vv -t install "$APP"
fi

ZIP="$OUT/Pier-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✓ $ZIP"
