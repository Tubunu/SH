#!/usr/bin/env bash
# Compiles the Rust `share_core` crate for iOS (arm64) and wraps the resulting
# dynamic library into `ios/Frameworks/share_core.framework` so CocoaPods embeds
# it inside `Runner.app/Frameworks/share_core.framework`, matching
# flutter_rust_bridge's default `ExternalLibrary.open('share_core.framework/share_core')`.
#
# Usage: bash tool/build_rust_ios.sh [version-name] [build-number]
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/.." && pwd)"

PUBSPEC_VER="$(grep -E '^version:' "$APP_ROOT/pubspec.yaml" | head -1 | awk '{print $2}' || true)"
DEFAULT_NAME="${PUBSPEC_VER%%+*}"
DEFAULT_NUM="${PUBSPEC_VER#*+}"
if [ -z "$DEFAULT_NAME" ] || [ "$DEFAULT_NAME" = "$PUBSPEC_VER" ]; then DEFAULT_NAME="1.5.0"; fi
if [ -z "$DEFAULT_NUM" ] || [ "$DEFAULT_NUM" = "$PUBSPEC_VER" ]; then DEFAULT_NUM="15"; fi

BUILD_NAME="${1:-$DEFAULT_NAME}"
BUILD_NUMBER="${2:-$DEFAULT_NUM}"

export IPHONEOS_DEPLOYMENT_TARGET="15.0"

echo "==> Building Rust share_core for aarch64-apple-ios (v$BUILD_NAME+$BUILD_NUMBER)..."
cd "$REPO_ROOT/rust"
cargo build --release --target aarch64-apple-ios

DYLIB="$REPO_ROOT/rust/target/aarch64-apple-ios/release/libshare_core.dylib"
if [ ! -f "$DYLIB" ]; then
  echo "ERROR: Expected dylib not found at $DYLIB" >&2
  exit 1
fi

FW_DIR="$APP_ROOT/ios/Frameworks/share_core.framework"
rm -rf "$FW_DIR"
mkdir -p "$FW_DIR"

cp "$DYLIB" "$FW_DIR/share_core"
chmod +x "$FW_DIR/share_core"
install_name_tool -id "@rpath/share_core.framework/share_core" "$FW_DIR/share_core"

cat > "$FW_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>share_core</string>
  <key>CFBundleIdentifier</key>
  <string>com.hengye.share.shareCore</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>share_core</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>${BUILD_NAME}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>MinimumOSVersion</key>
  <string>15.0</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>iPhoneOS</string>
  </array>
</dict>
</plist>
EOF

plutil -lint "$FW_DIR/Info.plist"
file "$FW_DIR/share_core"
otool -L "$FW_DIR/share_core"

SYM_COUNT="$(nm -gU "$FW_DIR/share_core" | grep -c 'frb' || true)"
echo "Exported FRB symbols: $SYM_COUNT"
if [ "$SYM_COUNT" -eq 0 ]; then
  echo "ERROR: No FRB symbols exported in $FW_DIR/share_core" >&2
  exit 1
fi
