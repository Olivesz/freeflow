"""Markdown results table from one or more bench runs.

    python3 bench/table.py bench/results/<sha>/<label> [...]
    python3 bench/table.py --brief ...     held-out split only (the README's table)

For each run: corpus WER (all errors over all reference words) for the
streamed and the offline transcript, on the held-out split, the dev split and
all clips; words dropped by streaming; and, from the run's ALL row, median and
p95 commit lag and CPU seconds per second of audio. The README's table is the --brief output.
"""

import csv
import json
import sys
from pathlib import Path

MANIFEST = Path(__file__).resolve().parent / "manifest.json"


def load(run: Path):
    split = {c["id"]: c["split"] for c in json.loads(MANIFEST.read_text())["clips"]}
    every = list(csv.DictReader(open(run / "summary.csv")))
    rows = [r for r in every if r["clip"] != "ALL"]
    total = next(r for r in every if r["clip"] == "ALL")
    info = json.loads((run / "run.json").read_text())
    return rows, total, split, info


def corpus(rows):
    n = sum(int(r["ref_words"]) for r in rows)
    s_err = sum(int(r["dropped_words"]) + int(r["inserted_words"]) + int(r["substituted_words"]) for r in rows)
    o_err = sum(round(float(r["offline_wer"]) * int(r["ref_words"])) for r in rows)
    drops = sum(int(r["dropped_words"]) for r in rows)
    return {"n": n, "stream": s_err / n, "offline": o_err / n, "drops": drops, "clips": len(rows)}


def main(runs, brief):
    if brief:
        print("| streamer | streamed WER | offline WER | words dropped |")
        print("|---|---|---|---|")
    else:
        print("| run | window | tick | decoder | held-out: streamed / offline WER | dropped | "
              "dev: streamed / offline WER | dropped | all 41 clips: streamed / offline | "
              "commit lag p50 / p95 | CPU s per audio s |")
        print("|---|---|---|---|---|---|---|---|---|---|---|")
    for arg in runs:
        run = Path(arg)
        rows, total, split, info = load(run)
        dev = corpus([r for r in rows if split[r["clip"]] == "dev"])
        held = corpus([r for r in rows if split[r["clip"]] == "heldout"])
        allc = corpus(rows)
        window = "none" if info["trim_after_s"] < 0 else f"{info['trim_after_s']:g} / {info['context_s']:g} s"
        if brief:
            print(f"| [`{run.parent.name}`]({run}/summary.csv) | {held['stream']:.1%} | {held['offline']:.1%} | "
                  f"{held['drops']} of {held['n']} |")
            continue
        print(f"| `{run.parent.name}/{run.name}` | {window} | {info['tick_ms']} ms | {info['decoding']} | "
              f"{held['stream']:.1%} / {held['offline']:.1%} | {held['drops']} of {held['n']} | "
              f"{dev['stream']:.1%} / {dev['offline']:.1%} | {dev['drops']} of {dev['n']} | "
              f"{allc['stream']:.1%} / {allc['offline']:.1%} | "
              f"{total['lag_p50_ms']} / {total['lag_p95_ms']} ms | {float(total['cpu_per_audio_s']):.2f} |")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--brief"]
    if not args:
        sys.exit(__doc__)
    main(args, "--brief" in sys.argv)
