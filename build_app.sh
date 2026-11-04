#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$SCRIPT_DIR}"
VERSION="${VERSION:-1.1.1}"

if [ -z "${APP_BUNDLE:-}" ]; then
    if [ "${CI:-false}" != "true" ] && [ -d "/Users/micage/Documents/Gemini" ] && [ -w "/Users/micage/Documents/Gemini" ]; then
        APP_BUNDLE="/Users/micage/Documents/Gemini/ColorDrop.app"
    else
        mkdir -p "$PROJECT_DIR/dist"
        APP_BUNDLE="$PROJECT_DIR/dist/ColorDrop.app"
    fi
fi

killall OppoLiteConnect 2>/dev/null || true

echo "==> [1/5] 编译 Swift 原生 Release 二进制 (arm64, v${VERSION})..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/Vendor"

xcrun swiftc -O -parse-as-library -target arm64-apple-macosx13.0 \
  "$PROJECT_DIR/Sources/OppoLiteConnect/Models/OppoModels.swift" \
  "$PROJECT_DIR/Sources/OppoLiteConnect/Protocol/DspIPCClient.swift" \
  "$PROJECT_DIR/Sources/OppoLiteConnect/Protocol/LanSdpDiscovery.swift" \
  "$PROJECT_DIR/Sources/OppoLiteConnect/Protocol/OShareEngine.swift" \
  "$PROJECT_DIR/Sources/OppoLiteConnect/Services/DiagnosticLogService.swift" \
  "$PROJECT_DIR/Sources/OppoLiteConnect/Services/ScreenMirrorService.swift" \
  "$PROJECT_DIR/Sources/OppoLiteConnect/Services/SMSNotificationService.swift" \
  "$PROJECT_DIR/Sources/OppoLiteConnect/Services/ConnectCoordinator.swift" \
  "$PROJECT_DIR/Sources/OppoLiteConnect/Views/MainConnectView.swift" \
  "$PROJECT_DIR/Sources/OppoLiteConnect/Views/MenuBarConnectView.swift" \
  "$PROJECT_DIR/Sources/OppoLiteConnect/Views/StatusBarDropController.swift" \
  "$PROJECT_DIR/Sources/OppoLiteConnect/OppoLiteConnectApp.swift" \
  -lz \
  -o "$APP_BUNDLE/Contents/MacOS/OppoLiteConnect"

strip -x "$APP_BUNDLE/Contents/MacOS/OppoLiteConnect" || true

echo "==> [2/5] 写入 Info.plist (v${VERSION})..."
cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>ColorDrop</string>
    <key>CFBundleExecutable</key>
    <string>OppoLiteConnect</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.colordrop.mac</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>ColorDrop</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>ColorDrop 需要访问本地局域网以自动发现并连接同一 Wi-Fi 下的手机设备。</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_oppo-ln-auth._tcp</string>
    </array>
</dict>
</plist>
EOF

echo "==> [3/5] 适配生成 AppIcon.icns..."
cp -f "$PROJECT_DIR/Vendor/iconbase_192.png" "$APP_BUNDLE/Contents/Resources/Vendor/iconbase_192.png"
(cd "$PROJECT_DIR" && "$APP_BUNDLE/Contents/MacOS/OppoLiteConnect" --sync-icon-only) || true
test -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "==> [4/5] 解压并嵌入核心互联服务、手机镜像与互传动态库..."
if [ ! -f "$PROJECT_DIR/Vendor/O+Connect Service" ] || [ ! -f "$PROJECT_DIR/Vendor/libOshareLib.dylib" ] || [ ! -d "$PROJECT_DIR/Vendor/OshareLibBundle.bundle" ]; then
    if [ -f "$PROJECT_DIR/Vendor/runtime.tar.xz" ]; then
        echo "    正在从 Vendor/runtime.tar.xz 解压运行时组件..."
        tar -xJf "$PROJECT_DIR/Vendor/runtime.tar.xz" -C "$PROJECT_DIR/Vendor"
    fi
fi

if [ ! -d "$PROJECT_DIR/Vendor/手机投屏.app" ]; then
    if [ -f "$PROJECT_DIR/Vendor/mirror.tar.xz" ]; then
        echo "    正在从 Vendor/mirror.tar.xz 解压手机镜像组件..."
        tar -xJf "$PROJECT_DIR/Vendor/mirror.tar.xz" -C "$PROJECT_DIR/Vendor"
    fi
fi

cp -f "$PROJECT_DIR/Vendor/libOshareLib.dylib" "$APP_BUNDLE/Contents/Resources/Vendor/libOshareLib.dylib"
cp -f "$PROJECT_DIR/Vendor/O+Connect Service" "$APP_BUNDLE/Contents/Resources/Vendor/O+Connect Service"
chmod +x "$APP_BUNDLE/Contents/Resources/Vendor/O+Connect Service"
rm -rf "$APP_BUNDLE/Contents/Resources/OshareLibBundle.bundle"
cp -R "$PROJECT_DIR/Vendor/OshareLibBundle.bundle" "$APP_BUNDLE/Contents/Resources/OshareLibBundle.bundle"
rm -rf "$APP_BUNDLE/Contents/Resources/Vendor/手机投屏.app"
cp -R "$PROJECT_DIR/Vendor/手机投屏.app" "$APP_BUNDLE/Contents/Resources/Vendor/手机投屏.app"
chmod +x "$APP_BUNDLE/Contents/Resources/Vendor/手机投屏.app/Contents/MacOS/手机投屏"

# 严格校验所有内置运行时组件，杜绝空 Vendor 目录打包
test -x "$APP_BUNDLE/Contents/Resources/Vendor/O+Connect Service"
test -f "$APP_BUNDLE/Contents/Resources/Vendor/libOshareLib.dylib"
test -f "$APP_BUNDLE/Contents/Resources/OshareLibBundle.bundle/server-cert.pem"
test -x "$APP_BUNDLE/Contents/Resources/Vendor/手机投屏.app/Contents/MacOS/手机投屏"

echo "==> [5/5] 签名并校验应用包..."
rm -f "$APP_BUNDLE/Icon"* 2>/dev/null || true
xattr -cr "$APP_BUNDLE" 2>/dev/null || true
codesign --force --sign - "$APP_BUNDLE/Contents/Resources/Vendor/libOshareLib.dylib"
codesign --force --sign - "$APP_BUNDLE/Contents/Resources/Vendor/O+Connect Service"
codesign --force --deep --sign - "$APP_BUNDLE/Contents/Resources/Vendor/手机投屏.app"
codesign --force --deep --sign - "$APP_BUNDLE"
touch "$APP_BUNDLE"

echo "==> 构建完成 (v${VERSION}): $APP_BUNDLE"

if [ "${1:-}" = "--dmg" ] || [ "${BUILD_DMG:-false}" = "true" ]; then
    DMG_OUT="${DMG_PATH:-$PROJECT_DIR/dist/ColorDrop-v${VERSION}-macOS-arm64.dmg}"
    STAGING_DIR="$(mktemp -d)"
    echo "==> 正在打包 DMG 安装镜像: $DMG_OUT ..."
    mkdir -p "$(dirname "$DMG_OUT")"
    cp -R "$APP_BUNDLE" "$STAGING_DIR/ColorDrop.app"
    ln -s /Applications "$STAGING_DIR/Applications"
    rm -f "$DMG_OUT"
    hdiutil create -volname "ColorDrop" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_OUT"
    rm -rf "$STAGING_DIR"
    shasum -a 256 "$DMG_OUT" > "${DMG_OUT}.sha256"
    echo "==> DMG 打包完成: $DMG_OUT"
fi
