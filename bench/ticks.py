"""Print a pass log as the user would see it: what was typed at each tick.

    python3 bench/ticks.py bench/results/<sha>/<label>/logs/<clip>.jsonl [--passes]

With --passes, also prints each pass's full hypothesis, so revisions that were
never typed are visible next to the words that were.
"""

import json
import sys


def main(path: str, passes: bool) -> None:
    lines = [json.loads(line) for line in open(path)]
    head, steps, tail = lines[0], [d for d in lines if "audio_end" in d], lines[-1]
    print(f"{head['clip']}: {head['seconds']} s, tick {head['tick_ms']} ms, "
          f"window {head['trim_after_s']}/{head['context_s']} s, {head['decoding']}")
    for d in steps:
        typed = " ".join(w[0] for w in d["committed"])
        heard = " ".join(w[0] for w in d["hypothesis"] if w[0])
        label = "stop" if d["final"] else f"{d['audio_end']:5.2f}s"
        if passes:
            print(f"  {label}  heard: {heard}")
            if typed:
                print(f"  {'':6} typed: + {typed}")
        elif typed:
            print(f"  {label}  + {typed}")
    print(f"streamed: {tail['streamed']}")
    print(f"offline:  {tail['offline']}")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--passes"]
    if len(args) != 1:
        sys.exit(__doc__)
    main(args[0], "--passes" in sys.argv)
