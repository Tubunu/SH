#!/usr/bin/env bash
# Cross-compiles the Rust core into android/app/src/main/jniLibs.
# Requires: rustup targets aarch64-linux-android / x86_64-linux-android,
#           cargo-ndk, Android NDK.
#
# Usage: bash tool/build_rust_android.sh
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/.." && pwd)"

export ANDROID_HOME="${ANDROID_HOME:-$LOCALAPPDATA/Android/Sdk}"
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  ANDROID_NDK_HOME="$(ls -d "$ANDROID_HOME"/ndk/* 2>/dev/null | tail -1 || true)"
fi
export ANDROID_NDK_HOME

cd "$REPO_ROOT/rust"
cargo ndk -t arm64-v8a -t x86_64 \
  -o "$APP_ROOT/android/app/src/main/jniLibs" \
  build --release

echo "jniLibs updated:"
ls -la "$APP_ROOT/android/app/src/main/jniLibs"/*/libshare_core.so
