#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$DIR/bin"
APP_DIR="$DIR/PauseCrossfader.app"

echo "==> Building PauseCrossfader..."
mkdir -p "$BIN_DIR"
swiftc -O "$DIR/Sources/main.swift" -o "$BIN_DIR/pause-crossfader"

echo "==> Creating macOS App Bundle..."
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/pause-crossfader" "$APP_DIR/Contents/MacOS/PauseCrossfader"
cp "$DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$APP_DIR/Contents/MacOS/PauseCrossfader"

codesign --force --deep --sign - "$APP_DIR"

echo "==> Build successful! App bundle ready at: $APP_DIR"
