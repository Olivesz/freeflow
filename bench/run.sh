#!/bin/bash
# Replay the benchmark clips through the mac app's streamer and score them.
#
#   bench/run.sh                     the shipped settings, every clip
#   bench/run.sh trim-8.0-2.0 --trim 8.0/2.0
#   bench/run.sh beam --beam
#   CLIPS=jfk,61-70968-0000 bench/run.sh smoke
#   GATE=1 bench/run.sh gate           only the clips marked "gate" (what CI runs)
#
# Results land in bench/results/<commit>/<label>/. The script refuses to run
# with uncommitted changes to the code being measured, so every results
# directory names the exact code that produced it.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "$(git status --porcelain -- mac/Package.swift mac/Sources)" ]; then
    echo "mac/ has uncommitted changes; commit them first so the results name real code" >&2
    exit 1
fi

label="${1:-shipped}"
[ $# -gt 0 ] && shift
sha=$(git rev-parse --short HEAD)
out="bench/results/$sha/$label"

(cd mac && swift build -c release >/dev/null)
mac/fetch_model.sh ${FREEFLOW_NO_ENCODER:+--no-encoder} >/dev/null

if [ -n "${GATE:-}" ]; then
    CLIPS=$(python3 -c 'import json; print(",".join(c["id"] for c in json.load(open("bench/manifest.json"))["clips"] if c.get("gate")))')
fi
clips=()
[ -n "${CLIPS:-}" ] && clips=(--clips "$CLIPS")
mkdir -p "$out"
FREEFLOW_MODEL_DIR="$PWD/mac/Resources" \
    mac/.build/release/Freeflow --bench bench/manifest.json --out "$out" "${clips[@]+"${clips[@]}"}" "$@" \
    2>/dev/null | grep -v -e '^whisper_' -e '^ggml_' -e '^$'
echo "→ $out"
