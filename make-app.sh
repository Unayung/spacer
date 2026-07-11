#!/bin/zsh
# 打包成簽名過的 Spacer.app 裝進 /Applications。
# 用 Developer ID 簽 → 重 build 不會再讓 TCC（行事曆、Automation）授權失效。
set -e
cd "$(dirname "$0")"
swift build -c release
APP=/Applications/Spacer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Spacer "$APP/Contents/MacOS/Spacer"
cp Sources/Spacer/Info.plist "$APP/Contents/Info.plist"
cp Sources/Spacer/Spacer.icns "$APP/Contents/Resources/Spacer.icns"
codesign --force --sign "Developer ID Application: Chia Yang Chen (WZFJ4E5LPD)" "$APP"
echo "installed: $APP"
