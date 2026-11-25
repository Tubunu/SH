#!/usr/bin/env bash
# One-shot release build: Rust -> jniLibs -> split APKs -> renamed artifacts.
#
# The Rust core is only cross-compiled for arm64-v8a and x86_64 (the
# armeabi-v7a rust target is not available from the configured toolchain), so
# the APK that Gradle emits for armeabi-v7a would be missing libshare_core.so
# and crash on launch. It is deleted here instead of shipped.
#
# Usage: bash tool/build_apk.sh [version-suffix]
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/.." && pwd)"
VERSION="${1:-v0.2}"

cd "$APP_ROOT"
bash tool/build_rust_android.sh

export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost,::1}"
flutter build apk --release --split-per-abi

OUT="$APP_ROOT/build/app/outputs/flutter-apk"
rm -f "$OUT/app-armeabi-v7a-release.apk"

cp "$OUT/app-arm64-v8a-release.apk" "$REPO_ROOT/Share-rebuild-arm64-$VERSION.apk"
cp "$OUT/app-x86_64-release.apk" "$REPO_ROOT/Share-rebuild-x86_64-$VERSION.apk"

echo
echo "artifacts:"
ls -la "$REPO_ROOT"/Share-rebuild-*-"$VERSION".apk
for f in "$REPO_ROOT"/Share-rebuild-*-"$VERSION".apk; do
  echo "-- $(basename "$f")"
  unzip -l "$f" | grep "libshare_core.so" || echo "   !! native core missing"
done
