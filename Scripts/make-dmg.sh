#!/bin/bash
# 构建 Release 版并打 DMG 安装包（拖拽到 Applications）。
# 用法：Scripts/make-dmg.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRCROOT="${SRCROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export SRCROOT

export PATH="$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# 从工程读取版本号
VERSION=$(grep -m1 'MARKETING_VERSION' "$SRCROOT/AidoPaste.xcodeproj/project.pbxproj" | sed 's/.*= \(.*\);.*/\1/')

xcodebuild -project "$SRCROOT/AidoPaste.xcodeproj" \
  -scheme AidoPaste -configuration Release \
  -derivedDataPath "$SRCROOT/.build/DerivedData" build

APP="$SRCROOT/.build/DerivedData/Build/Products/Release/AidoPaste.app"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$SRCROOT/dist"
DMG="$SRCROOT/dist/AidoPaste-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "AidoPaste $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" | tail -1
echo "DMG ready: $DMG (version $VERSION)"
