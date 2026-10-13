#!/bin/bash
# Build freeflow.app — a double-clickable menubar app. No Xcode project needed.
set -euo pipefail
cd "$(dirname "$0")"

APP="freeflow.app"
echo "▸ compiling (release)…"
swift build -c release

echo "▸ assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Freeflow "$APP/Contents/MacOS/Freeflow"
cp Resources/Info.plist    "$APP/Contents/Info.plist"
cp Resources/freeflow.icns "$APP/Contents/Resources/freeflow.icns"
cp Resources/hero-bg.png   "$APP/Contents/Resources/hero-bg.png"

# Bundle the whisper model so the app is self-contained, with the Core ML
# encoder next to it: whisper.cpp finds it by name and runs the encoder on the
# Neural Engine. fetch_model.sh downloads both and checks their sha256.
./fetch_model.sh
cp Resources/ggml-base.en.bin "$APP/Contents/Resources/ggml-base.en.bin"
cp -R Resources/ggml-base.en-encoder.mlmodelc "$APP/Contents/Resources/"
echo "▸ bundled model and Core ML encoder"

# Prefer the stable self-signed identity (from setup-signing.sh) so the
# Accessibility grant persists across rebuilds; fall back to ad-hoc.
if security find-identity -p codesigning 2>/dev/null | grep -q "freeflow-dev"; then
    echo "▸ signing with stable identity 'freeflow-dev'…"
    codesign --force --sign "freeflow-dev" "$APP" >/dev/null 2>&1
else
    echo "▸ signing (ad-hoc — run ./setup-signing.sh once to make grants permanent)…"
    codesign --force --sign - "$APP" >/dev/null 2>&1
fi

echo "✓ built $(pwd)/$APP"
echo "  → open it with:  open '$(pwd)/$APP'"
echo "  → or move it to /Applications and double-click."
