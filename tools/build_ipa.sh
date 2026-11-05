#!/bin/bash
# 打一个**未签名** IPA，给 Sideloadly / AltStore / Feather 这类工具重签用。
# 自己用 Xcode 装真机不需要走这里，见 tools/install_device.sh。
# 用法: tools/build_ipa.sh
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

PROJ="YEMusicPlus.xcodeproj"
SCHEME="YEMusicPlus"
DD="build_release"
APP="$DD/Build/Products/Release-iphoneos/FlowMusic.app"
OUT_DIR="dist"
OUT="$OUT_DIR/FlowMusic-unsigned.ipa"

echo "=== 1/3 编译 Release（关闭签名）==="
xcodebuild -project "$PROJ" -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build 2>&1 | grep -E "error:|warning: .*sign|BUILD " | head -20

if [ ! -d "$APP" ]; then
  echo "!! 构建产物不存在：$APP"
  exit 2
fi

echo "=== 2/3 组装 Payload ==="
rm -rf "$OUT_DIR/Payload" "$OUT"
mkdir -p "$OUT_DIR/Payload"
# 用 ditto 而不是 cp -R：保留扩展属性与符号链接，重签工具才不会报 bundle 损坏。
ditto "$APP" "$OUT_DIR/Payload/FlowMusic.app"

echo "=== 3/3 压缩 ==="
(cd "$OUT_DIR" && zip -qry "$(basename "$OUT")" Payload)
rm -rf "$OUT_DIR/Payload"

echo "完成：${OUT}（$(du -h "$OUT" | cut -f1)）"
echo "注意：这是未签名包，iPhone 不能直接装，需用 Sideloadly / AltStore 用自己的 Apple ID 重签。"
