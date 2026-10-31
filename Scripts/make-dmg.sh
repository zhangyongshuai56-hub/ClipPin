#!/bin/bash
# 构建 Release 版并打 DMG 安装包（拖拽到 Applications）。
# 用法：Scripts/make-dmg.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRCROOT="${SRCROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export SRCROOT

export PATH="$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# 签名：优先使用本机已安装的 "AidoPaste Dev" 证书（Scripts/create-signing-cert.sh 安装）。
# 固定证书让 TCC（辅助功能等权限）按证书匹配授权，重新构建不再掉权限；
# 未安装证书时回退 ad-hoc（权限需每次重建后重授）。
# 显式指定：SIGN_IDENTITY="AidoPaste Dev" Scripts/make-dmg.sh
if [ -z "${SIGN_IDENTITY:-}" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q '"AidoPaste Dev"'; then
    SIGN_IDENTITY="AidoPaste Dev"
  else
    SIGN_IDENTITY="-"
  fi
fi

# 从工程读取版本号
VERSION=$(grep -m1 'MARKETING_VERSION' "$SRCROOT/ClipPin.xcodeproj/project.pbxproj" | sed 's/.*= \(.*\);.*/\1/')

xcodebuild -project "$SRCROOT/ClipPin.xcodeproj" \
  -scheme ClipPin -configuration Release \
  -derivedDataPath "$SRCROOT/.build/DerivedData" \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="" \
  build

APP="$SRCROOT/.build/DerivedData/Build/Products/Release/ClipPin.app"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$SRCROOT/dist"
DMG="$SRCROOT/dist/ClipPin-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "ClipPin $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" | tail -1
echo "DMG ready: $DMG (version $VERSION)"
