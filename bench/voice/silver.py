"""Reference transcripts for your clips that no single model wrote.

    python silver.py <dir> <name>=<kind>:<model> [...]
        kind: whisper | parakeet; model: an MLX repo or a local directory

Every model transcribes every clip offline (cached in <dir>/hyps/<name>.json).
Then, per clip, NIST SCTK's `rover` votes the transcripts into one:

  * `<name>` gets a reference voted from every model *except* itself, so a
    system is never scored against its own output (leave-one-out);
  * `consensus` is voted from all of them.

Words are normalized first (Whisper's English normalizer, as in scoring), and
ties go to the model listed first, so put the strongest first. Clips whose
models disagree land in <dir>/disagreements.tsv, one row per contested word
slot, for a human to settle: that file plus your own corrections, not this
vote, are what make a reference gold. Writes <dir>/refs.json.

Needs SCTK built at bench/tools/sctk-src (bench/tools/get_sctk.sh).
"""
import json
import pathlib
import subprocess
import sys
import tempfile

import soundfile as sf
from whisper_normalizer.english import EnglishTextNormalizer

ROVER = pathlib.Path(__file__).resolve().parents[1] / "tools/sctk-src/bin/rover"
norm = EnglishTextNormalizer()


def transcriber(kind: str, model: str):
    if kind == "whisper":
        import mlx_whisper
        return lambda path: mlx_whisper.transcribe(str(path), path_or_hf_repo=model, language="en",
                                                   temperature=0.0, condition_on_previous_text=False)["text"]
    if kind == "parakeet":
        from parakeet_mlx import from_pretrained
        m = from_pretrained(model)
        return lambda path: m.transcribe(str(path)).text
    raise SystemExit(f"unknown kind {kind}")


def hyps(d: pathlib.Path, clips: list, name: str, spec: str) -> dict:
    cache = d / "hyps" / f"{name}.json"
    if cache.exists():
        return json.loads(cache.read_text())
    kind, model = spec.split(":", 1)
    run = transcriber(kind, model)
    out = {c["id"]: run(d / c["path"]) for c in clips}
    cache.parent.mkdir(exist_ok=True)
    cache.write_text(json.dumps(out, indent=1))
    return out


def rover(texts: list[str], weights: list[float]) -> tuple[str, list[list[str]]]:
    """Vote normalized transcripts; returns the voted text and, for every
    aligned slot where the inputs differ, the words each input put there."""
    with tempfile.TemporaryDirectory() as t:
        t = pathlib.Path(t)
        args = [str(ROVER)]
        for i, (txt, w) in enumerate(zip(texts, weights)):
            words = txt.split() or ["@"]          # "@": rover's null word, for an empty transcript
            # CTM: <file> <channel> <start> <dur> <word> <conf>; times are only
            # a placeholder ordering, alignment is on words.
            lines = [f"clip 1 {k * 0.1:.2f} 0.10 {wd} {w:.3f}" for k, wd in enumerate(words)]
            (t / f"h{i}.ctm").write_text("\n".join(lines) + "\n")
            args += ["-h", str(t / f"h{i}.ctm"), "ctm"]
        subprocess.run(args + ["-o", str(t / "vote.ctm"), "-m", "avgconf", "-a", "0.9", "-c", "0.5"],
                       check=True, capture_output=True)
        voted = " ".join(l.split()[4] for l in (t / "vote.ctm").read_text().splitlines()
                         if l.strip() and not l.startswith(";;") and l.split()[4] != "@")
        subprocess.run(args + ["-o", str(t / "align.ctm"), "-m", "putat"], check=True, capture_output=True)
        # putat: one <putative_tag> block per aligned slot, an <attrib> per
        # input naming its file in tag1; inputs with nothing there show as "@"
        # with an empty tag1, so they are filled in by elimination.
        slots, cur = [], None
        for line in (t / "align.ctm").read_text().splitlines():
            if line.lstrip().startswith("<putative_tag"):
                cur = {}
            elif line.lstrip().startswith("<attrib") and cur is not None:
                tag = line.split('tag="', 1)[1].split('"', 1)[0]
                src = line.split('tag1="', 1)[1].split('"', 1)[0]
                if src:
                    cur[pathlib.Path(src).name] = tag            # rover reports the full path
            elif line.lstrip().startswith("</putative_tag") and cur is not None:
                assert set(cur) <= {f"h{i}.ctm" for i in range(len(texts))}, f"unmapped rover input: {cur}"
                words = [cur.get(f"h{i}.ctm", "@") for i in range(len(texts))]
                if len(set(words)) > 1:
                    slots.append(words)
                cur = None
    return voted, slots


def main() -> None:
    d = pathlib.Path(sys.argv[1])
    clips = json.loads((d / "manifest.json").read_text())["clips"]
    specs = [a.split("=", 1) for a in sys.argv[2:]]
    names = [n for n, _ in specs]
    raw = {n: hyps(d, clips, n, s) for n, s in specs}
    weights = [1.0 - 0.01 * i for i in range(len(names))]          # earlier listed wins ties
    refs, rows = {}, ["clip\tslot\t" + "\t".join(names)]
    for c in clips:
        cid = c["id"]
        normed = [norm(raw[n][cid]) for n in names]
        r = {}
        for i, n in enumerate(names):
            others = [j for j in range(len(names)) if j != i]
            r[n], _ = rover([normed[j] for j in others], [weights[j] for j in others])
        r["consensus"], slots = rover(normed, weights)
        refs[cid] = r
        rows += [f"{cid}\t{k}\t" + "\t".join(s) for k, s in enumerate(slots)]
    (d / "refs.json").write_text(json.dumps(refs, indent=1))
    (d / "disagreements.tsv").write_text("\n".join(rows) + "\n")
    print(f"{len(clips)} clips; {len(rows) - 1} contested word slots -> {d / 'disagreements.tsv'}")


if __name__ == "__main__":
    main()
