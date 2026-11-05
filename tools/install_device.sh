#!/bin/bash
# 编译 → 签名 → 安装到已连接的真机 → 启动
# 用法: tools/install_device.sh [设备名关键字]
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
PROJ="YEMusicPlus.xcodeproj"
BUNDLE_ID="com.zed.yemusicplus"
DD="build_device"
APP="$DD/Build/Products/Debug-iphoneos/FlowMusic.app"

echo "=== 1/4 查找真机 ==="
DEST=$(xcodebuild -project "$PROJ" -scheme YEMusicPlus -showdestinations 2>/dev/null \
  | grep "platform:iOS," | grep -v "Simulator" | grep -viE "placeholder|AnyiOSDevice" | head -1)
if [ -z "$DEST" ]; then
  echo "!! 没找到已连接的真机。请确认："
  echo "   1) 用数据线连上 Mac（要能传数据的线，不是纯充电线）"
  echo "   2) 手机已解锁，弹出「要信任此电脑吗」时点信任并输入锁屏密码"
  exit 2
fi
UDID=$(echo "$DEST" | sed -E 's/.*id:([^,]+),.*/\1/' | tr -d ' ')
NAME=$(echo "$DEST" | sed -E 's/.*name:([^}]*)\}?.*/\1/' | tr -d ' ')
echo "   设备: $NAME ($UDID)"

# 开发者模式没开的话，xcodebuild 会超时、devicectl 会报一串 cryptex 错误，很难看懂。
# 这里提前拦一道，给出可直接照做的提示。
xcrun devicectl list devices --json-output /tmp/_ye_devices.json >/dev/null 2>&1
DEVMODE=$(python3 - "$UDID" <<'PY'
import json, sys
want = sys.argv[1]
try:
    devs = json.load(open('/tmp/_ye_devices.json')).get('result', {}).get('devices', [])
except Exception:
    print("unknown"); raise SystemExit

physical = [d for d in devs
            if (d.get('connectionProperties') or {}).get('transportType') in ('wired', 'localNetwork')]

hit = None
for d in physical:
    ids = {d.get('identifier', '')} | {(d.get('hardwareProperties') or {}).get('udid', '')}
    if want in ids:
        hit = d
        break
if hit is None and physical:
    hit = physical[0]

print(((hit or {}).get('deviceProperties') or {}).get('developerModeStatus') or 'unknown')
PY
)
if [ "$DEVMODE" = "disabled" ]; then
  echo ""
  echo "!! 手机的「开发者模式」没开，iOS 会拒绝安装任何开发版 App。"
  echo "   在手机上操作（只需做一次）："
  echo "     设置 → 隐私与安全性 → 滑到最底部 → 开发者模式 → 打开"
  echo "     按提示重启手机；重启后锁屏上会弹「要打开开发者模式吗？」→ 点「打开」→ 输入锁屏密码"
  echo "   完成后重新运行本脚本。"
  exit 4
fi

echo "=== 2/4 编译并签名（需要连苹果服务器换描述文件）==="
xcodebuild -project "$PROJ" -scheme YEMusicPlus \
  -configuration Debug \
  -destination "platform=iOS,id=$UDID" \
  -derivedDataPath "$DD" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build 2>&1 | grep -E "error:|warning: .*(provision|sign|team)|BUILD |\*\* " | sort -u | head -30
if [ ! -d "$APP" ]; then echo "!! 编译产物不存在，构建失败"; exit 3; fi

echo "=== 3/4 安装 ==="
xcrun devicectl device install app --device "$UDID" "$APP" 2>&1 | tail -5

echo "=== 4/4 启动 ==="
xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" 2>&1 | tail -5
echo "完成。若手机上提示「不受信任的开发者」，去 设置 → 通用 → VPN与设备管理 里信任对应证书。"
