#!/bin/zsh
# 打包 + Developer ID 簽名 + 上 GitHub Release。用法：./release.sh v1.0.0
# 沒公證（notarize），所以下載後第一次要右鍵 → 打開（或 xattr -dr com.apple.quarantine Spacer.app）。
# 想公證要另外設 hardened runtime + apple-events entitlement + app-specific password，之後再說。
set -e
cd "$(dirname "$0")"
VERSION="${1:?usage: ./release.sh vX.Y.Z}"

swift build -c release
APP="dist/Spacer.app"
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Spacer "$APP/Contents/MacOS/Spacer"
cp Sources/Spacer/Info.plist "$APP/Contents/Info.plist"
cp Sources/Spacer/Spacer.icns "$APP/Contents/Resources/Spacer.icns"

CERT="${SPACER_SIGN_ID:-$(security find-identity -v -p codesigning \
  | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}"
[ -n "$CERT" ] || { echo "need a Developer ID cert to release"; exit 1; }
codesign --force --sign "$CERT" "$APP"
echo "signed with: $CERT"

ZIP="dist/Spacer-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"     # 保留 bundle + 簽名
gh release create "$VERSION" "$ZIP" --title "Spacer $VERSION" --generate-notes
echo "released $VERSION"
