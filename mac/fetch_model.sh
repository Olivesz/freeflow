#!/bin/bash
# Download whisper.cpp's base.en model and its Core ML encoder into
# mac/Resources/, pinned to one revision of the whisper.cpp model repo and
# checked by sha256. Skips anything already present and verified.
#   mac/fetch_model.sh                 model + Core ML encoder (what the app bundles)
#   mac/fetch_model.sh --no-encoder    model only (CI)
set -euo pipefail
cd "$(dirname "$0")/Resources"

REV=5359861c739e955e79d9a303bcbc70fb988958b1
BASE="https://huggingface.co/ggerganov/whisper.cpp/resolve/$REV"
MODEL_SHA=a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002
ENCODER_ZIP_SHA=8cf860309e2449e2bdc8be834cf838ab2565747ecc8c0ef914ef5975115e192b

check() { [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$2" ]; }

if [ -f ggml-base.en.bin ] && check ggml-base.en.bin "$MODEL_SHA"; then
    echo "▸ model present"
else
    echo "▸ downloading ggml-base.en.bin (148 MB)…"
    curl -fL --progress-bar -o ggml-base.en.bin.part "$BASE/ggml-base.en.bin"
    check ggml-base.en.bin.part "$MODEL_SHA" || { echo "✗ model sha256 mismatch" >&2; rm -f ggml-base.en.bin.part; exit 1; }
    mv ggml-base.en.bin.part ggml-base.en.bin
fi

# The encoder is optional: without it whisper.cpp runs the encoder on the CPU.
[ "${1:-}" = "--no-encoder" ] && { echo "✓ $(pwd) (no Core ML encoder)"; exit 0; }

# The encoder is a directory, so its stamp file records the zip it came from.
if [ -d ggml-base.en-encoder.mlmodelc ] && [ "$(cat ggml-base.en-encoder.sha256 2>/dev/null)" = "$ENCODER_ZIP_SHA" ]; then
    echo "▸ Core ML encoder present"
else
    echo "▸ downloading the Core ML encoder (38 MB)…"
    curl -fL --progress-bar -o encoder.zip "$BASE/ggml-base.en-encoder.mlmodelc.zip"
    check encoder.zip "$ENCODER_ZIP_SHA" || { echo "✗ encoder sha256 mismatch" >&2; rm -f encoder.zip; exit 1; }
    rm -rf ggml-base.en-encoder.mlmodelc
    unzip -q encoder.zip && rm encoder.zip
    echo "$ENCODER_ZIP_SHA" > ggml-base.en-encoder.sha256
fi
echo "✓ $(pwd)"
