"""Summarise eval_models.py runs as the table in bench/README.md, and write the
numbers without transcripts to results.json beside this script.

    python table.py <eval_dir>
"""
import json, sys, pathlib

EVAL = pathlib.Path(sys.argv[1])
rows = {}
for f in sorted((EVAL / "results").glob("*.json")):
    r = json.loads(f.read_text())
    rows[f.stem.split("__")[-1].split("_")[-1]] = {k: v for k, v in r.items() if k != "hyps"}

sets = sorted({s for r in rows.values() for s in r["wer_by_set"]})
print("| model | WER | misheard | dropped | inserted | " + " | ".join(sets) + " | 3 s pass |")
print("|---" * (6 + len(sets)) + "|")
for name, r in sorted(rows.items(), key=lambda kv: kv[1]["wer_all"]):
    e = r["errors_all"]
    print(f"| {name} | {r['wer_all']:.2f}% | {e['substitutions']:.2f}% | {e['deletions']:.2f}% | "
          f"{e['insertions']:.2f}% | " + " | ".join(f"{r['wer_by_set'].get(s, 0):.2f}%" for s in sets)
          + f" | {r['pass_3s_ms_median']:.0f} ms |")
(pathlib.Path(__file__).parent / "results.json").write_text(json.dumps(rows, indent=1) + "\n")
