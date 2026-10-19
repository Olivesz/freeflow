"""Cut long recordings of your voice into dictation-sized clips.

    python segment.py <out_dir> <recording.wav> [...]

Splits at pauses (50 ms frames well below the recording's speech level for at
least MIN_PAUSE s), into clips of MIN_S to MAX_S seconds, each trimmed to its
speech plus PAD on both sides. A pause of FORCE_PAUSE or more always splits,
however short the clips: the app ends a dictation after 2.5 s of quiet, so a
clip holding a longer pause would be scored as a cut-off that no dictation
could have had. Energy only: no model decides where a clip ends,
so no model under test shapes the clips it is scored on. Writes
<out_dir>/clips/<recording>-NNN.wav and a manifest.json without references;
silver.py adds those.

Your recordings are personal data: keep <out_dir> outside the repo
(~/Library/Application Support/freeflow/pilot is the default place).
"""
import json
import pathlib
import sys

import numpy as np
import soundfile as sf

FRAME = 800                     # 50 ms at 16 kHz
MIN_PAUSE, FORCE_PAUSE, MIN_S, MAX_S, PAD = 0.45, 1.2, 6.0, 25.0, 0.2


def segments(x: np.ndarray) -> list[tuple[int, int]]:
    n = len(x) // FRAME
    rms = np.sqrt((x[: n * FRAME].reshape(n, FRAME) ** 2).mean(1))
    speech = np.percentile(rms, 90)
    quiet = rms < max(0.1 * speech, 2 * np.percentile(rms, 5))
    # Pause runs long enough to cut in: (start_frame, end_frame).
    runs, i = [], 0
    while i < n:
        if quiet[i]:
            j = i
            while j < n and quiet[j]:
                j += 1
            if (j - i) * FRAME / 16000 >= MIN_PAUSE:
                runs.append((i, j))
            i = j
        else:
            i += 1
    cuts = [(a + b) // 2 for a, b in runs]           # cut in the middle of each pause
    forced = {(a + b) // 2 for a, b in runs if (b - a) * FRAME / 16000 >= FORCE_PAUSE}
    out, start = [], 0
    for c in cuts + [n]:
        if (c - start) * FRAME / 16000 < MIN_S and c != n and c not in forced:
            continue
        # Over-long stretch with no usable pause: split it evenly.
        k = int(np.ceil((c - start) * FRAME / 16000 / MAX_S))
        bounds = np.linspace(start, c, k + 1).astype(int)
        out += [(int(a), int(b)) for a, b in zip(bounds[:-1], bounds[1:])]
        start = c
    pad = int(PAD * 16000 / FRAME)
    kept = []
    for a, b in out:
        voiced = np.flatnonzero(~quiet[a:b])
        if len(voiced) == 0 or rms[a:b].max() <= 0.3 * speech:
            continue
        a, b = a + voiced[0], a + voiced[-1] + 1             # trim to the speech
        if (b - a) * FRAME / 16000 >= 1.0:
            kept.append((max(0, a - pad) * FRAME, min(n, b + pad) * FRAME))
    return kept


def main() -> None:
    out = pathlib.Path(sys.argv[1])
    (out / "clips").mkdir(parents=True, exist_ok=True)
    clips = []
    for path in map(pathlib.Path, sys.argv[2:]):
        x, sr = sf.read(path, dtype="float32")
        assert sr == 16000 and x.ndim == 1, f"{path}: need 16 kHz mono"
        for k, (a, b) in enumerate(segments(x)):
            cid = f"{path.stem}-{k:03d}"
            sf.write(out / "clips" / f"{cid}.wav", x[a:b], 16000, subtype="PCM_16")
            clips.append({"id": cid, "recording": path.stem, "path": f"clips/{cid}.wav",
                          "start_s": round(a / 16000, 2), "seconds": round((b - a) / 16000, 2)})
        print(f"{path.stem}: {sum(c['recording'] == path.stem for c in clips)} clips")
    (out / "manifest.json").write_text(json.dumps({"clips": clips}, indent=1))
    print(f"{len(clips)} clips, {sum(c['seconds'] for c in clips):.0f} s")


if __name__ == "__main__":
    main()
