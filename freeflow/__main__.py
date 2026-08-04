"""Entry point.  Usage:

    python -m freeflow            # run the dictation daemon (needs permissions)
    python -m freeflow check      # record 4s, transcribe, print — validates
                                  #   the mic+model path with NO accessibility needed
    python -m freeflow devices    # list audio input devices
"""

from __future__ import annotations

import sys
import time

from . import SAMPLE_RATE
from .audio import Recorder, list_devices
from .config import Config


def _check(cfg: Config) -> None:
    from .stt import build_transcriber

    print(f"loading '{cfg.model.name}' via {cfg.model.engine}…", flush=True)
    stt = build_transcriber(cfg)
    rec = Recorder()
    print("Speak now — recording 4 seconds…", flush=True)
    rec.start()
    time.sleep(4.0)
    rec.stop()
    audio = rec.snapshot()
    print(f"captured {audio.size / SAMPLE_RATE:.1f}s, transcribing…", flush=True)
    text = stt.flush(audio)
    print(f"\n>>> {text.strip() or '(nothing heard)'}\n")


def main() -> None:
    cfg = Config.load()
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"
    if cmd == "devices":
        print(list_devices())
    elif cmd == "check":
        _check(cfg)
    else:
        from .app import FreeFlowApp

        try:
            FreeFlowApp(cfg).run()
        except KeyboardInterrupt:
            print("\nbye.")


if __name__ == "__main__":
    main()
