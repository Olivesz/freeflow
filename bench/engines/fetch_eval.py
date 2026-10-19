"""Build the engine-comparison set from the Open ASR leaderboard's test sets.

    python fetch_eval.py <out_dir> [clips_per_set]     # 25 per set by default
    python fetch_eval.py <out_dir> --full librispeech:test.clean ...

For each dataset: stream the test split in its stored order, keep clips 4-20 s
long, take every STRIDE-th one until N are kept. Deterministic, so the same
command rebuilds the same set. Writes 16 kHz mono wavs + manifest.json.

--full takes whole test splits instead (every utterance with a non-empty
reference, any length), the way the leaderboard scores them, to check that
this scorer reproduces its published numbers.
TED-LIUM is left out: it is gated on the Hub, so not everyone could rebuild it.
"""
import json, sys, pathlib
import numpy as np, soundfile as sf, librosa
from datasets import load_dataset

OUT = pathlib.Path(sys.argv[1])
FULL = "--full" in sys.argv
if FULL:
    N, STRIDE = 10**9, 1
    SETS = [tuple(a.split(":")) for a in sys.argv[sys.argv.index("--full") + 1:]]
else:
    N, STRIDE = int(sys.argv[2]) if len(sys.argv) > 2 else 25, 7
    SETS = [  # (config, split) in hf-audio/esb-datasets-test-only-sorted
        ("ami", "test"), ("earnings22", "test"), ("voxpopuli", "test"),
        ("librispeech", "test.other"), ("librispeech", "test.clean"),
    ]

clips = []
for cfg, split in SETS:
    name = f"{cfg}-{split.replace('test.', '')}"
    try:
        ds = load_dataset("hf-audio/esb-datasets-test-only-sorted", cfg, split=split, streaming=True)
    except Exception as e:
        print(f"skip {name}: {e.__class__.__name__}: {str(e)[:120]}"); continue
    kept = seen = 0
    (OUT / name).mkdir(parents=True, exist_ok=True)
    for ex in ds:
        a = ex["audio"]; sr = a["sampling_rate"]; x = np.asarray(a["array"], dtype=np.float32)
        dur = len(x) / sr
        if not ex["text"].strip() or (not FULL and not 4 <= dur <= 20):
            continue
        seen += 1
        if seen % STRIDE:
            continue
        if sr != 16000:
            x = librosa.resample(x, orig_sr=sr, target_sr=16000)
        cid = f"{name}-{kept:04d}" if FULL else f"{name}-{kept:03d}"
        sf.write(OUT / name / f"{cid}.wav", x, 16000, subtype="PCM_16")
        clips.append({"id": cid, "set": name, "path": f"{name}/{cid}.wav",
                      "text": ex["text"].strip(), "seconds": round(len(x) / 16000, 2)})
        kept += 1
        if kept >= N:
            break
    print(f"{name}: {kept} clips")

(OUT / "manifest.json").write_text(json.dumps({"clips": clips}, indent=1))
print(f"total {len(clips)} clips, {sum(c['seconds'] for c in clips):.0f} s")
