"""Build a benchmark manifest from your own corrected dictations.

The mac app keeps recordings only when "Keep recordings for tuning" is on, in
~/Library/Application Support/freeflow/recordings/: <id>.wav plus <id>.json
with what was typed and, once you review it in History, what you said. Every
recording you reviewed becomes a clip whose reference is what you said: the
pencil sets a fix, the check confirms the transcript was already right.

Review a spread, not just the misses: a set made only of the dictations the
current model got wrong is selected on its errors, and any other model looks
better on it by construction.

    python3 bench/personal.py            # writes recordings/manifest.json
    FREEFLOW_MODEL_DIR=$PWD/mac/Resources mac/.build/release/Freeflow \
        --bench ~/Library/Application\ Support/freeflow/recordings/manifest.json --out <dir>

The manifest lives next to the recordings, outside the repo: your voice and
what you said are personal data and never belong in git.
"""
import json
import pathlib
import sys

DIR = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else
                   pathlib.Path.home() / "Library/Application Support/freeflow/recordings")

clips, uncorrected = [], 0
for meta_path in sorted(DIR.glob("*.json")):
    if meta_path.name == "manifest.json":
        continue
    meta = json.loads(meta_path.read_text())
    if not meta.get("corrected"):
        uncorrected += 1
        continue
    wav = meta_path.with_suffix(".wav")
    if not wav.exists():
        continue
    clips.append({"id": meta["id"], "set": "personal", "path": wav.name,
                  "text": meta["corrected"], "typed": meta["typed"],
                  "seconds": meta["seconds"], "model": meta["model"]})

(DIR / "manifest.json").write_text(json.dumps({"clips": clips}, indent=1))
print(f"{len(clips)} corrected recordings ({sum(c['seconds'] for c in clips):.0f} s) → {DIR / 'manifest.json'}"
      f"; {uncorrected} recorded but not yet corrected")
