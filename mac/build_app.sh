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

# Bundle the whisper model so the app is self-contained (no download step).
MODEL="$HOME/Library/Application Support/pywhispercpp/models/ggml-base.en.bin"
if [ -f "$MODEL" ]; then
    cp "$MODEL" "$APP/Contents/Resources/ggml-base.en.bin"
    echo "▸ bundled model ($(du -h "$MODEL" | cut -f1))"
else
    echo "⚠ model not found at $MODEL — app will fall back to that path at runtime."
fi
# Bundle the Core ML encoder next to it → whisper.cpp auto-runs the encoder on the
# Neural Engine (~⅓ the CPU). whisper.cpp finds it by name: ggml-base.en-encoder.mlmodelc
if [ -d "Resources/ggml-base.en-encoder.mlmodelc" ]; then
    cp -R "Resources/ggml-base.en-encoder.mlmodelc" "$APP/Contents/Resources/"
    echo "▸ bundled Core ML encoder (Neural Engine)"
fi

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
