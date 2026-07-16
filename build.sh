#!/bin/zsh
set -euo pipefail

APP_NAME="${APP_NAME:-CommandDash}"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
TMP_APP_DIR="$BUILD_DIR/$APP_NAME.app.tmp"
CONTENTS_DIR="$TMP_APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_PNG="$ROOT_DIR/icon.png"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
ICON_ICNS="$RESOURCES_DIR/AppIcon.icns"
MODULE_CACHE_DIR="$BUILD_DIR/modulecache"
MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-13.0}"
ARCHS_STRING="${ARCHS:-arm64 x86_64}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.leozhaorx.commanddash}"
APP_VERSION="${APP_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

rm -rf "$TMP_APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
mkdir -p "$MODULE_CACHE_DIR"

arch_binaries=()
for arch in ${(z)ARCHS_STRING}; do
  arch_binary="$BUILD_DIR/$APP_NAME-$arch"
  xcrun swiftc \
    "$ROOT_DIR/Sources/"*.swift \
    -o "$arch_binary" \
    -O \
    -target "$arch-apple-macos$MACOS_DEPLOYMENT_TARGET" \
    -module-cache-path "$MODULE_CACHE_DIR/$arch" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Foundation \
    -framework Combine \
    -framework UniformTypeIdentifiers
  arch_binaries+=("$arch_binary")
done

if (( ${#arch_binaries[@]} == 1 )); then
  mv "${arch_binaries[1]}" "$MACOS_DIR/$APP_NAME"
else
  xcrun lipo -create "${arch_binaries[@]}" -output "$MACOS_DIR/$APP_NAME"
  rm -f "${arch_binaries[@]}"
fi

if [[ -f "$ICON_PNG" ]]; then
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"

  sips -z 16 16 "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

  if ! iconutil -c icns "$ICONSET_DIR" -o "$ICON_ICNS"; then
    echo "Warning: iconutil 生成 icns 失败，回退为 PNG 图标。"
    cp "$ICON_PNG" "$RESOURCES_DIR/AppIcon.png"
  fi
  rm -rf "$ICONSET_DIR"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MACOS_DEPLOYMENT_TARGET</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

rm -rf "$APP_DIR"
mv "$TMP_APP_DIR" "$APP_DIR"
xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "Built: $APP_DIR"
file "$APP_DIR/Contents/MacOS/$APP_NAME"
