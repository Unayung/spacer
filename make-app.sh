#!/bin/zsh
# 打包成 Spacer.app 裝進 /Applications。
# 有 Developer ID 憑證就用它簽（重 build 不會讓 TCC 授權失效）；
# 沒有就 ad-hoc 簽（-s -），任何人 clone 都能自己 build 來跑。
# 想指定憑證：SPACER_SIGN_ID="Developer ID Application: ..." ./make-app.sh
set -e
cd "$(dirname "$0")"
swift build -c release
APP=/Applications/Spacer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Spacer "$APP/Contents/MacOS/Spacer"
cp Sources/Spacer/Info.plist "$APP/Contents/Info.plist"
cp Sources/Spacer/Spacer.icns "$APP/Contents/Resources/Spacer.icns"

CERT="${SPACER_SIGN_ID:-$(security find-identity -v -p codesigning \
  | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}"
if [ -n "$CERT" ]; then
  codesign --force --sign "$CERT" "$APP"
  echo "signed with: $CERT"
else
  codesign --force --sign - "$APP"   # ad-hoc：無憑證也能本機跑
  echo "signed ad-hoc (no Developer ID found — fine for local use)"
fi
echo "installed: $APP"
