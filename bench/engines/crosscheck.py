"""Check this repo's scoring against an independent implementation and
against published numbers.

    python crosscheck.py <eval_dir> <leaderboard.csv> [--oal <dir>] <result-name>=<leaderboard model> [...]

For each eval_models.py result in <eval_dir>/results, scores the same
normalized transcripts twice, with jiwer (what bench/engines and bench/voice
use) and with NIST SCTK's sclite, and compares both with the Open ASR
leaderboard's published WER for that model and test set (its results CSV,
pinned by revision; see bench/README.md). Prints a table; exits 1 if jiwer
and sclite disagree by more than 0.05 points on any set.

--oal points at a checkout of huggingface/open_asr_leaderboard. The model's
raw transcripts are then also scored the leaderboard's way: its own English
normalizer (which, unlike Whisper's, drops fillers and spells out
abbreviations) and kaldialign with split compounds merged, so a gap to the
published number can be put down to scoring or to the model run.

Needs SCTK built at bench/tools/sctk-src (bench/tools/get_sctk.sh).
"""
import csv
import json
import pathlib
import re
import subprocess
import sys
import tempfile

import jiwer
from whisper_normalizer.english import EnglishTextNormalizer

SCLITE = pathlib.Path(__file__).resolve().parents[1] / "tools/sctk-src/bin/sclite"
COLUMN = {"librispeech-clean": "LS Clean WER", "librispeech-other": "LS Other WER",
          "ami-test": "AMI WER", "earnings22-test": "Earnings22 WER", "voxpopuli-test": "Voxpopuli WER"}
norm = EnglishTextNormalizer()


def sclite_wer(refs: list[str], hyps: list[str]) -> float:
    with tempfile.TemporaryDirectory() as t:
        t = pathlib.Path(t)
        # trn: one utterance per line, "<words> (<id>)"; an empty side is allowed.
        (t / "ref.trn").write_text("".join(f"{r} (u{i:05d})\n" for i, r in enumerate(refs)))
        (t / "hyp.trn").write_text("".join(f"{h} (u{i:05d})\n" for i, h in enumerate(hyps)))
        out = subprocess.run([str(SCLITE), "-r", str(t / "ref.trn"), "trn", "-h", str(t / "hyp.trn"), "trn",
                              "-i", "rm", "-o", "sum", "stdout"], capture_output=True, text=True, check=True).stdout
    # | Sum/Avg | #Snt #Wrd | Corr Sub Del Ins Err S.Err |
    row = next(l for l in out.splitlines() if "Sum/Avg" in l)
    nums = [float(x) for x in re.findall(r"[\d.]+", row)]
    return nums[6]                                    # Err, in percent


def leaderboard_scorer(oal: str):
    sys.path.insert(0, oal)
    from kaldialign import edit_distance
    from normalizer.normalizer import EnglishTextNormalizer as LBNormalizer
    n = LBNormalizer()

    def wer(refs: list[str], hyps: list[str]) -> float:
        err = ref_len = 0
        for r, h in zip(refs, hyps):
            r, h = n(r), n(h)
            if not r.strip():
                continue
            e = edit_distance(tuple(r.split()), tuple(h.split()), merge_compounds=True)
            err += e["total"]; ref_len += e["ref_len"]
        return 100 * err / ref_len
    return wer


def main() -> None:
    args = sys.argv[1:]
    oal = None
    if "--oal" in args:
        i = args.index("--oal"); oal = args[i + 1]; del args[i:i + 2]
    lb_wer = leaderboard_scorer(oal) if oal else None
    d = pathlib.Path(args[0])
    board = {r["model"]: r for r in csv.DictReader(open(args[1]))}
    pairs = [a.split("=", 1) for a in args[2:]]
    clips = json.loads((d / "manifest.json").read_text())["clips"]
    print("| model | set | utterances | jiwer WER | sclite WER | leaderboard's scoring | published |")
    print("|---|---|---|---|---|---|---|")
    worst = 0.0
    for name, published_model in pairs:
        f = next(p for p in (d / "results").glob("*.json") if p.stem.endswith(name))
        result = json.loads(f.read_text())
        hyps, raw = result["hyps"], result.get("raw", {})
        for s in sorted({c["set"] for c in clips}):
            cs = [c for c in clips if c["set"] == s and c["id"] in hyps]
            refs = [norm(c["text"]) for c in cs]
            hs = [hyps[c["id"]] for c in cs]
            keep = [i for i, r in enumerate(refs) if r.strip()]     # the leaderboard drops empty references
            refs, hs = [refs[i] for i in keep], [hs[i] for i in keep]
            o = jiwer.process_words(refs, [h or "" for h in hs])
            jw = 100 * (o.substitutions + o.deletions + o.insertions) / sum(len(r.split()) for r in refs)
            sc = sclite_wer(refs, hs)
            worst = max(worst, abs(jw - sc))
            lb = "n/a"
            if lb_wer and all(c["id"] in raw for c in cs):
                lb = f"{lb_wer([c['text'] for c in cs], [raw[c['id']] for c in cs]):.2f}%"
            pub = board.get(published_model, {}).get(COLUMN.get(s, ""), "")
            print(f"| {name} | {s} | {len(refs)} | {jw:.2f}% | {sc:.2f}% | {lb} | {pub}% |")
    print(f"\nlargest jiwer/sclite gap: {worst:.3f} points")
    sys.exit(1 if worst > 0.05 else 0)


if __name__ == "__main__":
    main()
