"""Pass/fail check on a bench summary.csv, used by CI's real-model gate.

    python3 bench/gate.py bench/results/<sha>/<label>/summary.csv

Fails (exit 1) unless, over all clips in the run:
  * streaming WER is at most offline WER + 2 points (same model, same clips);
  * the JFK clip, if present, loses no words.
"""

import csv
import sys

MARGIN = 0.02


def main(path: str) -> int:
    rows = {r["clip"]: r for r in csv.DictReader(open(path))}
    total = rows["ALL"]
    stream, offline = float(total["stream_wer"]), float(total["offline_wer"])
    problems = []
    if stream > offline + MARGIN:
        problems.append(f"streaming WER {stream:.3f} > offline {offline:.3f} + {MARGIN}")
    if "jfk" in rows and int(rows["jfk"]["dropped_words"]) > 0:
        problems.append(f"jfk dropped {rows['jfk']['dropped_words']} words")
    clips = len(rows) - 1
    if problems:
        print(f"FAIL ({clips} clips): " + "; ".join(problems))
        return 1
    print(f"PASS ({clips} clips): streaming WER {stream:.3f}, offline {offline:.3f}, margin {MARGIN}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1]))
