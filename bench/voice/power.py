"""How much dictation it takes to tell two candidates apart.

    python power.py <pilot_dir>

Reads the pilot made by segment.py, silver.py and `Freeflow --e2e` (clips,
per-model transcripts, the live replay) and answers, for the comparisons the
tuning program will make: how many minutes of your dictation give 80% power
to detect a given WER difference at alpha 0.05 (two-sided), with the
paired, clip-level analysis the program will use.

Method. Two systems run on the same clips, so the comparison is paired. The
WER difference is a ratio estimator, sum(d_i) / sum(N_i), with d_i the
difference in errors on clip i and N_i its reference words. Its variance is
estimated by linearization from the residuals r_i = d_i - D*N_i, which gives
the clips needed for a difference delta:

    n = ((z_0.975 + z_0.8) * sd(r) / (delta * mean(N)))**2

then minutes from the pilot's mean clip length. Dictations from one day
share a mic, a room and a topic, so the analysis resamples days, not clips;
the design effect 1 + (m - 1) * rho inflates n for m dictations a day at a
within-day correlation rho, shown for a range since the pilot can't measure
it. The formula is checked by simulation: resample the pilot's residuals at
that n, add the effect, run the paired bootstrap the program will use, and
count how often its 95% interval excludes zero.

Each pair is scored against a ROVER reference voted by the models outside
the pair, so neither side is graded against itself.

The pilot is small; treat the numbers as an order of magnitude and rerun
this on the first week of real sessions.
"""
import csv
import json
import math
import pathlib
import sys

import numpy as np
from jiwer import process_words
from scipy.stats import norm as gauss

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from silver import norm, rover  # noqa: E402

Z = gauss.ppf(0.975) + gauss.ppf(0.8)
RNG = np.random.default_rng(7)


def errors(ref: str, hyp: str) -> int:
    o = process_words(ref or "∅", hyp or "∅")
    return o.substitutions + o.deletions + o.insertions


def pair_data(d, clips, hyps, names, a, b):
    """Per clip: reference words, errors of a, errors of b, against a vote of the others."""
    # The live replay is Parakeet v2 again, so it never votes on a reference.
    others = [n for n in names if n not in (a, b, "pk2_live") and n in hyps]
    rows = []
    for c in clips:
        cid = c["id"]
        ref, _ = rover([norm(hyps[n][cid]) for n in others], [1.0 - 0.01 * i for i in range(len(others))])
        if not ref:
            continue
        rows.append((len(ref.split()), errors(ref, norm(hyps[a][cid])), errors(ref, norm(hyps[b][cid])), c["seconds"]))
    return np.array(rows, dtype=float)


def clips_needed(x: np.ndarray, delta: float) -> float:
    n_w, ea, eb = x[:, 0], x[:, 1], x[:, 2]
    D = (ea - eb).sum() / n_w.sum()
    r = (ea - eb) - D * n_w
    return (Z * r.std(ddof=1) / (delta * n_w.mean())) ** 2


def simulated_power(x: np.ndarray, n: int, delta: float, sims: int = 300, boots: int = 400) -> float:
    n_w, ea, eb = x[:, 0], x[:, 1], x[:, 2]
    D = (ea - eb).sum() / n_w.sum()
    r = (ea - eb) - D * n_w
    hits = 0
    for _ in range(sims):
        i = RNG.integers(0, len(x), n)
        d = r[i] + delta * n_w[i]                      # true difference: delta
        w = n_w[i]
        j = RNG.integers(0, n, (boots, n))
        est = d[j].sum(1) / w[j].sum(1)
        lo, hi = np.percentile(est, [2.5, 97.5])
        hits += lo > 0 or hi < 0
    return hits / sims


def two_proportions(p1: float, p2: float) -> float:
    pb = (p1 + p2) / 2
    za, zb = gauss.ppf(0.975), gauss.ppf(0.8)
    return (za * math.sqrt(2 * pb * (1 - pb)) + zb * math.sqrt(p1 * (1 - p1) + p2 * (1 - p2))) ** 2 / (p1 - p2) ** 2


def main() -> None:
    d = pathlib.Path(sys.argv[1])
    clips = json.loads((d / "manifest.json").read_text())["clips"]
    names = sorted(p.stem for p in (d / "hyps").glob("*.json"))
    hyps = {n: json.loads((d / "hyps" / f"{n}.json").read_text()) for n in names}
    e2e = d / "e2e" / "e2e.csv"
    if e2e.exists():
        hyps["pk2_live"] = {r["clip"]: r["typed"] for r in csv.DictReader(open(e2e))}
        names_live = names + ["pk2_live"]
    else:
        names_live = names
    secs = np.mean([c["seconds"] for c in clips])
    refs = json.loads((d / "refs.json").read_text())
    words = sum(len(refs[c["id"]]["consensus"].split()) for c in clips)
    minutes = sum(c["seconds"] for c in clips) / 60
    wpm = words / minutes

    out = [f"# Power analysis from the pilot\n",
           f"{len(clips)} clips, {minutes:.1f} min, {words} words ({wpm:.0f} words/min), "
           f"mean clip {secs:.1f} s. Models: {', '.join(names)}.\n",
           "## WER differences (paired, clip level)\n",
           "| comparison | observed ΔWER | clips for Δ=0.5 / 1 / 2 pts | minutes for Δ=0.5 / 1 / 2 | simulated power at the Δ=1 n |",
           "|---|---|---|---|---|"]
    pairs = [("pk2", "pk3", "two close systems (Parakeet v2 vs v3)"),
             ("pk2", "turbo", "different families (Parakeet v2 vs Whisper turbo)")]
    if "pk2_live" in hyps:
        pairs.append(("pk2_live", "pk2", "streaming cost (live app vs offline, same model)"))
    for a, b, label in pairs:
        if a not in hyps or b not in hyps:
            continue
        x = pair_data(d, clips, hyps, names_live, a, b)
        obs = 100 * (x[:, 1].sum() - x[:, 2].sum()) / x[:, 0].sum()
        ns = [clips_needed(x, dl / 100) for dl in (0.5, 1, 2)]
        n1 = int(math.ceil(ns[1]))
        pw = simulated_power(x, max(n1, 5), 0.01)
        out.append(f"| {label} | {obs:+.2f} pts | {' / '.join(f'{n:.0f}' for n in ns)} | "
                   f"{' / '.join(f'{n * secs / 60:.0f}' for n in ns)} | {pw:.2f} (n={n1}) |")
    out += ["",
            "Minutes assume clips like the pilot's. Clustering by day multiplies them by",
            "1 + (m - 1) * rho: at 20 dictations a day, x1.4 for rho = 0.02, x2.9 for rho = 0.1.",
            "",
            "## Cut-offs (per dictation, two arms)\n",
            "| baseline rate | halved to | dictations per arm |", "|---|---|---|"]
    for p in (0.05, 0.10, 0.18):
        out.append(f"| {p:.0%} | {p / 2:.1%} | {two_proportions(p, p / 2):.0f} |")
    out += ["", "## Corrections per 100 words (blind A/B, Poisson with overdispersion)\n"]
    if "pk2_live" in hyps:
        x = pair_data(d, clips, hyps, names_live, "pk2_live", "pk2")
        lam = x[:, 1].sum() / x[:, 0].sum()
        per = x[:, 1] / x[:, 0] * x[:, 0].mean()
        phi = max(1.0, per.var(ddof=1) / per.mean()) if per.mean() > 0 else 1.0
        out += [f"Live errors per word in the pilot: {lam:.3f}; dispersion of errors per clip: {phi:.1f}.",
                "Words per arm to detect a rate ratio, if every error gets corrected (lambda = WER) "
                "or half of them:", "", "| rate ratio | lambda = WER | lambda = WER/2 | minutes per arm (WER) |",
                "|---|---|---|---|"]
        for rr in (0.75, 0.5):
            def need(l):
                return phi * Z ** 2 * (1 / l + 1 / (rr * l)) / math.log(rr) ** 2
            out.append(f"| {rr} | {need(lam):.0f} | {need(lam / 2):.0f} | {need(lam) / wpm:.0f} |")
    (d / "power.md").write_text("\n".join(out) + "\n")
    print("\n".join(out))


if __name__ == "__main__":
    main()
