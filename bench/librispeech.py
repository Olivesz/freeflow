"""Select the LibriSpeech clips for the benchmark and write bench/manifest.json.

    python3 bench/librispeech.py <path to LibriSpeech/test-clean>

The rule was fixed before any results were looked at: for each of the 40
test-clean speakers, in speaker-ID order, take the first utterance (by ID) that
lasts between 4 and 20 seconds. The first 20 speakers are the dev split, used
while fixing the streamer and choosing its window; the last 20 are held out
and were first scored after the fix was committed.

CI's real-model gate replays a fixed subset: JFK plus every fifth speaker
(the first, sixth, eleventh, ...), marked "gate" in the manifest.

The FLAC files are copied byte for byte, so each sha256 in the manifest can be
checked against the LibriSpeech distribution (openslr.org/12, test-clean.tar.gz,
md5 32fa31d27d2e1cad72775fee3f4849a9). LibriSpeech is CC BY 4.0.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
MIN_S, MAX_S = 4.0, 20.0
DEV_SPEAKERS = 20
GATE_EVERY = 5

JFK = {
    "id": "jfk",
    "path": "clips/jfk.wav",
    "split": "dev",
    "gate": True,
    "text": "And so my fellow Americans, ask not what your country can do for you, "
            "ask what you can do for your country.",
    "source": "whisper.cpp samples/jfk.wav: John F. Kennedy, inaugural address, 1961",
    "license": "public domain (US government work); file distributed with whisper.cpp (MIT)",
}


def flac_seconds(path: Path) -> float:
    """Duration from the FLAC STREAMINFO block (always the first metadata block)."""
    with path.open("rb") as f:
        head = f.read(42)
    assert head[:4] == b"fLaC", path
    info = head[8:]                          # skip "fLaC" + 4-byte block header
    rate = int.from_bytes(info[10:13], "big") >> 4
    total = int.from_bytes(info[13:18], "big") & ((1 << 36) - 1)
    return total / rate


def transcripts(chapter: Path) -> dict[str, str]:
    out = {}
    for line in next(chapter.glob("*.trans.txt")).read_text().splitlines():
        uid, text = line.split(" ", 1)
        out[uid] = text
    return out


def main(root: Path) -> None:
    clips_dir = HERE / "clips" / "librispeech"
    clips_dir.mkdir(parents=True, exist_ok=True)
    clips = [JFK]
    speakers = sorted((p for p in root.iterdir() if p.is_dir()), key=lambda p: int(p.name))
    assert len(speakers) == 40, f"expected 40 test-clean speakers, found {len(speakers)}"
    for n, spk in enumerate(speakers):
        chosen = None
        for chapter in sorted(spk.iterdir(), key=lambda p: int(p.name)):
            text = transcripts(chapter)
            for flac in sorted(chapter.glob("*.flac"), key=lambda p: int(p.stem.split("-")[2])):
                if MIN_S <= flac_seconds(flac) <= MAX_S:
                    chosen = (flac, text[flac.stem])
                    break
            if chosen:
                break
        assert chosen, f"no {MIN_S}-{MAX_S} s utterance for speaker {spk.name}"
        flac, text = chosen
        dest = clips_dir / flac.name
        shutil.copyfile(flac, dest)
        clips.append({
            "id": flac.stem,
            "path": f"clips/librispeech/{flac.name}",
            "split": "dev" if n < DEV_SPEAKERS else "heldout",
            "gate": n % GATE_EVERY == 0,
            "text": text,
            "seconds": round(flac_seconds(flac), 2),
            "sha256": hashlib.sha256(dest.read_bytes()).hexdigest(),
            "source": f"LibriSpeech test-clean {flac.stem}",
            "license": "CC BY 4.0",
        })
    (HERE / "manifest.json").write_text(json.dumps({"clips": clips}, indent=2) + "\n")
    total = sum(c.get("seconds", 11.0) for c in clips)
    print(f"{len(clips)} clips, {total:.0f} s of audio")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(Path(sys.argv[1]))
