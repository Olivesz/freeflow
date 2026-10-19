"""Read the app's session log (Settings > Keep recordings for tuning).

    python sessions.py summary [<sessions_dir>]
    python sessions.py split   [<sessions_dir>] --test-from YYYY-MM-DD
    python sessions.py export  [<sessions_dir>] <out_dir> [--test]

<sessions_dir> defaults to ~/Library/Application Support/freeflow/sessions.

summary  what was logged and the live measures: first-word latency, how long
         auto-stop waited after the speech, re-triggers (a new dictation within
         RETRIGGER_S of an auto-stop: the commonest sign of a cut-off), and the
         correction trail.
split    freezes the held-out test split: sessions from that date on. Written
         once to split.json next to the log; it refuses to move afterwards, so
         nothing tuned can peek at the test sessions.
export   writes the dev sessions that have a reference as a manifest for
         `Freeflow --e2e` and the scorers. A reference is, in order of trust,
         your fix or confirmation in History, else what the text read as in the
         field later (the correction trail). --test exports the test split
         instead: once, at the end.

Your audio and text stay where they are; export copies them to <out_dir>,
which must not be inside the repo.
"""
import json
import pathlib
import shutil
import sqlite3
import sys
from datetime import datetime

import numpy as np
import pandas as pd
import soundfile as sf

DEFAULT = pathlib.Path.home() / "Library/Application Support/freeflow/sessions"
REPO = pathlib.Path(__file__).resolve().parents[2]
RETRIGGER_S = 8.0


def load(d: pathlib.Path) -> dict[str, pd.DataFrame]:
    con = sqlite3.connect(f"file:{d / 'sessions.sqlite'}?mode=ro", uri=True)
    t = {name: pd.read_sql(f"SELECT * FROM {name}", con) for name in ("sessions", "ticks", "ops", "edits")}
    con.close()
    return t


def speech_span(x: np.ndarray) -> tuple[float, float] | None:
    """First and last 50 ms frame clearly above the recording's quiet frames,
    in seconds of audio: the same rule as the --e2e harness (E2E.speechSpan)."""
    n = len(x) // 800
    if n == 0:
        return None
    rms = np.sqrt((x[: n * 800].reshape(n, 800) ** 2).mean(1))
    thr = max(0.01, 4 * np.sort(rms)[n // 10])
    on = np.flatnonzero(rms > thr)
    return (on[0] * 0.05, (on[-1] + 1) * 0.05) if len(on) else None


def measures(t: dict[str, pd.DataFrame], d: pathlib.Path | None = None) -> pd.DataFrame:
    s = t["sessions"].sort_values("started").reset_index(drop=True)
    ticks = t["ticks"].sort_values(["session", "idx"])
    stop = ticks[ticks.stop == 1].groupby("session").t.min().rename("stop_t")
    ins = t["ops"][t["ops"].kind == "insert"].groupby("session").t.min().rename("first_insert")
    s = s.join(stop, on="id").join(ins, on="id")
    # Speech onset and end from the session's audio, put on the wall clock via
    # the ticks' (wall time, audio captured) pairs.
    start, end = [], []
    for r in s.itertuples():
        span, k = None, ticks[ticks.session == r.id]
        if d is not None and isinstance(r.audio, str) and (d / r.audio).exists() and len(k) > 1:
            span = speech_span(sf.read(d / r.audio, dtype="float32")[0])
        if span:
            start.append(float(np.interp(span[0], k.audio_end, k.t)))
            end.append(float(np.interp(span[1], k.audio_end, k.t)))
        else:
            start.append(np.nan); end.append(np.nan)
    s["speech_start"], s["speech_end"] = start, end
    s["first_word_s"] = s.first_insert - s.speech_start
    s["stop_after_s"] = (s.stop_t - s.speech_end).where(s.stop_reason == "auto")
    gap = s.started.shift(-1) - s.ended
    # The harness plays clips back to back, which is no sign of anything.
    s["retriggered"] = (s.stop_reason == "auto") & (gap < RETRIGGER_S) & (s.trigger != "e2e")
    e = t["edits"].sort_values("checked_at").groupby("session").last()
    s = s.join(e[["status", "now", "distance"]].add_prefix("edit_"), on="id")
    s["day"] = pd.to_datetime(s.started, unit="s").dt.date
    return s


def summary(d: pathlib.Path) -> None:
    s = measures(load(d), d)
    if s.empty:
        print("no sessions yet"); return
    typed = s.typed.fillna("").str.split().str.len().sum()
    print(f"{len(s)} sessions over {s.day.nunique()} days, {s.audio_s.sum() / 60:.1f} min of audio, "
          f"{typed} words typed")
    print("engines:", s.engine.value_counts().to_dict())
    print("apps:", s.app.value_counts().head(8).to_dict())
    print(f"stops: {s.stop_reason.value_counts().to_dict()}; re-triggered within {RETRIGGER_S:.0f} s "
          f"of an auto-stop: {int(s.retriggered.sum())} ({s.retriggered.mean():.1%})")
    q = lambda c: s[c].quantile([0.5, 0.9]).round(2).tolist()
    print(f"first word after speech starts, p50/p90: {q('first_word_s')} s; "
          f"auto-stop after speech ends, p50/p90: {q('stop_after_s')} s")
    print("correction trail:", s.edit_status.value_counts(dropna=False).to_dict(),
          f"edited: {int((s.edit_distance > 0).sum())}")
    print("references from History:", s.reference_kind.value_counts().to_dict())
    split = d / "split.json"
    if split.exists():
        cut = json.loads(split.read_text())["test_from"]
        print(f"split: test from {cut}: {int((s.day >= datetime.fromisoformat(cut).date()).sum())} test sessions")


def freeze_split(d: pathlib.Path, test_from: str) -> None:
    f = d / "split.json"
    if f.exists():
        raise SystemExit(f"split already frozen: {f.read_text().strip()} (delete it only to start over)")
    datetime.fromisoformat(test_from)
    f.write_text(json.dumps({"test_from": test_from, "frozen_at": datetime.now().isoformat()}) + "\n")
    print(f"frozen: sessions from {test_from} on are the test split")


def export(d: pathlib.Path, out: pathlib.Path, test: bool) -> None:
    if REPO in out.resolve().parents or out.resolve() == REPO:
        raise SystemExit("refusing to export personal recordings into the repo")
    f = d / "split.json"
    if not f.exists():
        raise SystemExit("freeze a split first: sessions.py split --test-from YYYY-MM-DD")
    cut = datetime.fromisoformat(json.loads(f.read_text())["test_from"]).date()
    s = measures(load(d), d)
    s = s[(s.day >= cut) if test else (s.day < cut)]
    clips = []
    (out / "clips").mkdir(parents=True, exist_ok=True)
    for r in s.itertuples():
        if r.reference_kind in ("fixed", "confirmed"):
            ref, kind = r.reference, r.reference_kind
        elif r.edit_status == "ok":
            ref, kind = r.edit_now, "trail"
        else:
            continue
        if not isinstance(r.audio, str) or not (d / r.audio).exists():
            continue
        shutil.copy(d / r.audio, out / "clips" / r.audio)
        clips.append({"id": r.id, "path": f"clips/{r.audio}", "text": ref, "reference_kind": kind,
                      "day": str(r.day), "app": r.app, "device": r.device, "typed": r.typed})
    (out / "manifest.json").write_text(json.dumps({"split": "test" if test else "dev", "clips": clips}, indent=1))
    print(f"{len(clips)} {'test' if test else 'dev'} sessions with a reference -> {out}")


def main() -> None:
    a = sys.argv[1:]
    if not a:
        raise SystemExit(__doc__)
    cmd, rest = a[0], a[1:]
    flags = {k: rest[rest.index(k) + 1] for k in ("--test-from",) if k in rest}
    pos = [x for i, x in enumerate(rest) if not x.startswith("--") and (i == 0 or rest[i - 1] != "--test-from")]
    if cmd == "summary":
        summary(pathlib.Path(pos[0]) if pos else DEFAULT)
    elif cmd == "split":
        freeze_split(pathlib.Path(pos[0]) if pos else DEFAULT, flags["--test-from"])
    elif cmd == "export":
        d, out = (pathlib.Path(pos[0]), pathlib.Path(pos[1])) if len(pos) > 1 else (DEFAULT, pathlib.Path(pos[0]))
        export(d, out, "--test" in rest)
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
