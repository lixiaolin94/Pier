#!/bin/zsh
# 为一个版本生成 Sparkle feed：用 EdDSA 私钥（环境变量 SPARKLE_ED_PRIVATE_KEY，
# 即 `generate_keys -x` 导出的那把；publish.sh 会从钥匙串导出后传进来）签 build/release/Pier-<版本>.zip，
# 写出只含这一版的 build/release/appcast.xml。SUFeedURL 指向
# releases/latest/download/appcast.xml，最新的 release 自带自己的 appcast，不用维护历史条目。
set -euo pipefail
cd "$(dirname "$0")/.."
SPARKLE_VERSION=2.9.6   # 与 project.yml 里 Sparkle 包的版本保持一致
OUT=build/release
VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)
MIN_OS=$(sed -n 's/^ *macOS: "\(.*\)"/\1/p' project.yml | head -1)
ZIP="$OUT/Pier-$VERSION.zip"
[[ -f "$ZIP" ]] || { echo "缺少 $ZIP（先跑 scripts/release.sh）"; exit 1; }
[[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]] || { echo "没有设置 SPARKLE_ED_PRIVATE_KEY"; exit 1; }

TOOLS=build/sparkle-tools
if [[ ! -x "$TOOLS/bin/sign_update" ]]; then
  mkdir -p "$TOOLS"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    | tar -xJ -C "$TOOLS"
fi

# 输出就是现成的 enclosure 属性：sparkle:edSignature="…" length="…"（私钥走 stdin，不落盘）
SIGNATURE=$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$TOOLS/bin/sign_update" --ed-key-file - "$ZIP")

# 更新说明取 CHANGELOG.md 里这个版本的那一节
NOTES=$(awk -v v="## $VERSION" 'index($0, v) == 1 {on=1; next} /^## / {on=0} on' CHANGELOG.md \
  | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

cat > $OUT/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Pier</title>
    <item>
      <title>$VERSION</title>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <link>https://github.com/lixiaolin94/Pier/releases/tag/v$VERSION</link>
      <description><![CDATA[<pre>$NOTES</pre>]]></description>
      <enclosure
        url="https://github.com/lixiaolin94/Pier/releases/download/v$VERSION/Pier-$VERSION.zip"
        $SIGNATURE
        type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
echo "✓ $OUT/appcast.xml ($SIGNATURE)"
