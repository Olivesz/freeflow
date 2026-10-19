# Tuning freeflow to your voice

The benchmark next door measures freeflow on audiobooks. This measures it on
you: your voice, your mic, your room, your words, in the apps you dictate
into. Everything it reads stays on your Mac; nothing here ever commits your
audio or text.

## Phase 1: collect

Turn on **Setup › Keep recordings for tuning**. From then on every dictation
is logged to `~/Library/Application Support/freeflow/sessions/`: one SQLite
file (`sessions.sqlite`) and a WAV per dictation.

| table | one row per | what it holds |
|---|---|---|
| `sessions` | dictation | engine, window, auto-stop setting, mic, app typed into, hotkey mode, how it stopped (auto or manual), what was typed, your reference from History |
| `passes` | decoder pass | its window, decode time, whether the blank-decode retry ran, the words with confidence, the words it committed, every token with its confidence and time |
| `ticks` | 350 ms tick | loudness, the room's noise floor, whether it counted as speech, silence so far, the silence it would take to stop then (3× mid-sentence), whether it stopped |
| `ops` | edit typed | when, and what: an insert or a bounded backspace |
| `edits` | dictation | what the dictated text read as in the field later |

The last table is the **correction trail**. After a dictation, freeflow reads
the focused field through Accessibility, then again 90 s later or when the
next dictation starts. It keeps only the dictated span and what it became, and
never reads password fields. Apps that don't expose their text are logged as
`no_ax`, so you know how much of your use the trail covers.

In **History**, the check marks a transcript right and the pencil fixes it.
Either becomes that session's reference, and it outranks the trail.

```bash
python3.12 -m venv bench/voice/.venv && bench/voice/.venv/bin/pip install -r bench/voice/requirements.txt
bench/voice/.venv/bin/python bench/voice/sessions.py summary
```

## How much to collect

`power.py` answers it from a pilot (below): the minutes of dictation that give
80% power to detect a WER difference at alpha 0.05 with the paired analysis
Phase 3 will use. Its answer for this pilot is in "Pilot" below.

## The tools

| | |
|---|---|
| `sessions.py summary` | what was logged; first-word latency, auto-stop delay, re-triggers (a new dictation within 8 s of an auto-stop: the usual sign of a cut-off), the correction trail |
| `sessions.py split --test-from DATE` | freezes the held-out test split, by date, once |
| `sessions.py export OUT` | dev sessions with a reference, as a manifest for the harness and scorers |
| `segment.py` | cuts long recordings into dictation-sized clips by energy alone, so no model under test shapes them; a pause longer than 1.2 s always splits |
| `silver.py` | references no single model wrote: five local models, voted per clip with NIST SCTK's `rover`, each system scored against a vote that leaves it out; contested words go to `disagreements.tsv` for a human |
| `power.py` | the power analysis |
| `Freeflow --e2e` | the app's whole dictation loop on a clip, on the wall clock: tick loop, endpointer, text processor, session log; everything but the mic and the keyboard |

SCTK comes from `bench/tools/get_sctk.sh` (pinned commit). `bench/engines/crosscheck.py`
checks this repo's scorer against `sclite` and the published leaderboard.

## References, in order of trust

1. Your fix or confirmation in History.
2. The correction trail: what the text read as later. It misses errors you
   didn't bother to fix, and counts rewrites that weren't errors.
3. A `rover` vote of models other than the one being scored, with its contested
   words settled by you (`disagreements.tsv`).
4. The same vote unsettled: a silver reference. It measures disagreement with
   the consensus, which includes the consensus's own mistakes.

## Pilot

Before any collecting, a pilot from the recordings already on the Mac: three
talking-head takes, 3.7 minutes and 847 words once cut into 30 clips by
`segment.py` (mean clip 7.4 s; you speak at about 227 words a minute). Too
little to rank anything; enough to size the collection and to test every tool
on real audio of your voice. Run on 2026-10-19.

**How much to collect** (`power.py`, 80% power, alpha 0.05, paired by clip):

| comparison | minutes for a 0.5 / 1 / 2 point WER difference |
|---|---|
| two close systems (Parakeet v2 vs v3: what Phase 3's candidates look like) | 55 / 14 / 3 |
| two different families (Parakeet v2 vs Whisper turbo) | 132 / 33 / 8 |
| the cost of streaming (the live app vs the same model offline) | 111 / 28 / 7 |

The formula was checked by simulation: at the clip counts it gives, the
bootstrap the program will use detects the effect 80-92% of the time.
Dictations from one day share a mic, a room and a topic, so multiply by 1.4
(within-day correlation 0.02) to 2.9 (0.1) at 20 dictations a day. Comparing
two auto-stop rules by A/B needs hundreds of dictations per arm (434 to halve
a 10% cut-off rate); replaying logged audio through both rules pairs them by
pause and needs far fewer. A blind A/B on corrections per 100 words needs about
50 minutes per arm to see a 25% drop if you fix every error, twice that if you
fix half.

So: about **30 minutes of dictation for the dev split and 30 more for the test
split**, over at least two weeks, separates 1-point differences between close
candidates even with clustering. The blind A/B is a further two weeks.

**What the pilot already shows**, against references that leave the scored
model out:

- Live, the app's error rate on your clips is 0.9 points above the same
  model run offline (not significant at 30 clips; it takes about 220). On the
  41 benchmark clips the live replay (`--e2e`, 3.1%) is also worse than the
  fixed-tick benchmark (`--bench`, 2.4%): live pass timing lands window
  edges inside words. In one replay a window ended partway through a word,
  two passes agreed on a shorter word in its place, the next pass couldn't
  anchor on it, and five words were typed twice.
- Auto-stop counts silence in ticks, not seconds. With another model running
  on the Mac, passes averaged 240 ms and ticks stretched to 0.7 s, so a
  2.5 s setting stopped up to 6.2 s after the speech. Every one of the 41
  stops was at the plain 2.5 s limit, none at the mid-sentence hold.
- The first word lands about 0.8 s after speech starts (median, 41 clips and
  30 of yours alike), and auto-stop fires 3.0 s after it ends.
- The silver reference can't yet rank the models on your voice. Parakeet v2
  scores 3.3 points worse than Whisper turbo against a vote of the other three
  models, two of them Whisper; the 116 contested words in
  `disagreements.tsv` decide whether that is Parakeet or the vote.
