"""Offline WER + speed of local open-weights ASR models on a manifest.

    python eval_models.py <eval_dir> <model> [<model> ...]
    models: whisper:<mlx repo> | parakeet:<mlx repo>

Scores with Whisper's English normalizer (what the Open ASR leaderboard uses),
corpus WER per dataset and overall, split into substitutions (misheard words),
deletions and insertions. Also times one pass over a 3 s window, which is what
the app pays every 350 ms tick. Runs through MLX on the GPU, not the app's
Core ML path, so the times compare models with each other, not with the app.
Writes <eval_dir>/results/<model>.json, transcripts included: normalized in
"hyps", as the model wrote them in "raw" (for scoring with another
normalizer, as crosscheck.py does).
"""
import json, sys, time, pathlib, statistics
import numpy as np, soundfile as sf, jiwer
from whisper_normalizer.english import EnglishTextNormalizer

norm = EnglishTextNormalizer()
EVAL = pathlib.Path(sys.argv[1])
clips = json.loads((EVAL / "manifest.json").read_text())["clips"]


def loader(spec):
    kind, repo = spec.split(":", 1)
    if kind == "whisper":
        import mlx_whisper
        def run(x):
            return mlx_whisper.transcribe(x, path_or_hf_repo=repo, language="en",
                                          temperature=0.0, condition_on_previous_text=False)["text"]
        return run
    if kind == "parakeet":
        from parakeet_mlx import from_pretrained
        import tempfile
        m = from_pretrained(repo)
        tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
        def run(x):                       # the library's own path: load, features, decode
            sf.write(tmp, x, 16000, subtype="PCM_16")
            return m.transcribe(tmp).text
        return run
    raise SystemExit(f"unknown model kind {kind}")


results = {}
for spec in sys.argv[2:]:
    run = loader(spec)
    wav0 = sf.read(EVAL / clips[0]["path"], dtype="float32")[0]
    run(wav0)                                   # warm-up: load weights, compile
    refs, hyps, raws, per_set, audio_s, decode_s = [], [], [], {}, 0.0, 0.0
    for c in clips:
        x = sf.read(EVAL / c["path"], dtype="float32")[0]
        t = time.perf_counter(); h = run(x); decode_s += time.perf_counter() - t
        audio_s += len(x) / 16000
        raws.append(h)
        r, h = norm(c["text"]), norm(h)
        refs.append(r); hyps.append(h)
        per_set.setdefault(c["set"], ([], []))
        per_set[c["set"]][0].append(r); per_set[c["set"]][1].append(h)
    win = wav0[: 3 * 16000]
    passes = []
    for _ in range(7):
        t = time.perf_counter(); run(win); passes.append((time.perf_counter() - t) * 1000)

    def errors(r, h):
        o = jiwer.process_words([x or "∅" for x in r], [x or "∅" for x in h])
        n = max(1, sum(len(x.split()) for x in r))
        return {k: round(100 * getattr(o, k) / n, 2) for k in ("substitutions", "deletions", "insertions")}

    def wer(r, h):
        return round(sum(errors(r, h).values()), 2)
    results[spec] = {
        "wer_all": wer(refs, hyps),
        "errors_all": errors(refs, hyps),
        "wer_by_set": {k: wer(*v) for k, v in sorted(per_set.items())},
        "rtfx": round(audio_s / decode_s, 1),
        "pass_3s_ms_median": round(statistics.median(passes), 1),
        "hyps": {c["id"]: h for c, h in zip(clips, hyps)},
        "raw": {c["id"]: h for c, h in zip(clips, raws)},
    }
    r = results[spec]
    print(f"{spec}: WER {r['wer_all']}%  RTFx {r['rtfx']}  3s-pass {r['pass_3s_ms_median']} ms  {r['wer_by_set']}", flush=True)
    out = EVAL / "results"; out.mkdir(exist_ok=True)
    (out / (spec.replace("/", "_").replace(":", "__") + ".json")).write_text(json.dumps(r, indent=1))
