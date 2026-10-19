# freeflow

[![CI](https://github.com/Olivesz/freeflow/actions/workflows/ci.yml/badge.svg)](https://github.com/Olivesz/freeflow/actions/workflows/ci.yml)

Local dictation for macOS. Press a shortcut, talk, and the words are typed into
whatever app has focus as you speak. Speech is decoded on-device by NVIDIA's
open-weights Parakeet TDT 0.6B on the Neural Engine, with whisper.cpp as a
bundled fallback: no account, no cloud, nothing to pay.

Words are typed while you're still talking, and a typed word is never taken
back. Here is the shipped streamer replaying a LibriSpeech clip at the app's
350 ms tick ([`bench/ticks.py`](bench/ticks.py) on
[its pass log](bench/results/f589ce9/shipped/logs/1580-141083-0000.jsonl)):

```
1580-141083-0000: 8.94 s, tick 350 ms, window 8/2 s, greedy
   1.05s  + I will
   1.40s  + endeavour
   1.75s  + in my
   2.10s  + statement to
   2.45s  + avoid
   3.15s  + such
   3.50s  + terms as
   3.85s  + would
   4.20s  + serve to limit the
   5.25s  + events to any
   5.95s  + particular
   6.30s  + place
   7.00s  + or give
   7.35s  + a clue
   7.70s  + as
   8.05s  + to the
   8.40s  + people concerned.
streamed: I will endeavour in my statement to avoid such terms as would serve to limit the events to any particular place or give a clue as to the people concerned.
offline:  I will endeavour in my statement to avoid such terms as would serve to limit the events to any particular place or give a clue as to the people concerned.
```

## Install

Needs macOS 14 and Xcode's command-line tools.

```bash
git clone https://github.com/Olivesz/freeflow.git
cd freeflow/mac
./build_app.sh        # builds, downloads the Whisper fallback (sha256-checked), bundles it
open freeflow.app
```

The first launch walks through the two permissions: Microphone, and
Accessibility so it can type into other apps. It also downloads Parakeet
(about 450 MB, once); Whisper takes dictation until it's ready. The default
shortcut is ⌥Space; tap to start, and it stops after 2.5 s of silence, three
times that when you pause mid-sentence (all changeable). Run
`./setup-signing.sh` once if you rebuild often: a stable signing identity keeps
the Accessibility grant across rebuilds.

## Which model?

Five open-weights models that run on a Mac, each decoding 125 clips from the
[Open ASR leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard)'s
test sets: meetings (AMI), earnings calls, European Parliament (VoxPopuli) and
audiobooks (LibriSpeech clean and other), 25 each, 4,760 words, offline:

| model | WER | misheard | dropped | inserted | one 3 s pass |
|---|---|---|---|---|---|
| Parakeet TDT 0.6B v2 (shipped) | 4.6% | 2.3% | 1.2% | 1.1% | 141 ms |
| Parakeet TDT 0.6B v3 | 4.8% | 2.4% | 1.2% | 1.3% | 139 ms |
| Whisper large-v3-turbo | 5.9% | 2.3% | 2.8% | 0.8% | 488 ms |
| Whisper small.en | 7.6% | 3.5% | 2.8% | 1.3% | 140 ms |
| Whisper base.en (before) | 8.6% | 4.2% | 2.7% | 1.7% | 67 ms |

"Misheard" is a wrong word where a word was said, the error people notice most.
Parakeet v2 mishears about half as many words as base.en, ties Whisper
large-v3-turbo, and runs a 3 s window in under a third of turbo's time. On
meetings, turbo dropped 9.7% of the words against Parakeet's 1.9% (AMI WER
14.7% against 8.1%), many of them the repeats and false starts that meeting
transcripts keep.
v3 is Parakeet's multilingual release; v2 is English-only and slightly better
at it. Pass times are on the GPU through MLX, so they compare models with each
other; on the Neural Engine the app decodes a pass in 46 ms at the median.
Scripts and numbers are in
[`bench/engines/`](bench/engines/).

## Does streaming cost accuracy?

Streaming re-decodes a window every 350 ms, so it hears less context than
decoding the whole recording at once. The benchmark in [`bench/`](bench/)
replays 41 public clips (40 LibriSpeech test-clean speakers and whisper.cpp's
sample clip) through the app's own streamer and scores both against the
reference, on the same model:

Held-out split, 20 LibriSpeech speakers, 523 words:

| engine, streamer | streamed WER | offline WER | words dropped |
|---|---|---|---|
| base.en, [`0f70dcd`](bench/results/0f70dcd/shipped/summary.csv) | 19.7% | 5.4% | 78 of 523 |
| base.en, [`9832030`](bench/results/9832030/timing/summary.csv) | 6.7% | 5.4% | 3 of 523 |
| Parakeet, [`f589ce9`](bench/results/f589ce9/shipped/summary.csv) | 2.1% | 1.9% | 2 of 523 |

The first row is the streamer before
[`262c910`](https://github.com/Olivesz/freeflow/commit/262c910): it dropped about
one word in seven that offline decoding of the same audio got right, because it
trusted whisper.cpp's word timestamps, which drift by up to a second between
passes. The fix finds the boundary between typed and new words by matching
text. Each streaming window was chosen on the other 20 speakers; the held-out
speakers play no part in any choice. With Parakeet a word is typed a median
669 ms after it ends, and decoding takes 0.06 CPU-seconds per second of audio
against whisper.cpp's 1.75 (the Neural Engine's own work isn't counted).
Per-clip numbers, every pass of every clip, and the commands to reproduce them
are in [`bench/`](bench/).

## Tuning it to your voice

- **Words tab.** "heard → types" corrections, applied to every dictation:
  names, jargon, anything it keeps getting wrong.
- **Your own benchmark.** Turn on "Keep recordings for tuning" and recordings
  stay on the Mac. In History, the check marks a transcript right and the
  pencil fixes it; [`bench/personal.py`](bench/personal.py) turns the reviewed
  ones into a benchmark of your voice, so any engine or setting can be scored
  on how you actually talk. Nothing leaves the machine or goes into git.
- **Engine.** Setup switches between Parakeet and Whisper.

Feeding the vocabulary to the model itself (CTC keyword boosting) was tried:
it raised recall of the listed words but also overall WER, and typed listed
words that were never said, so corrections stay text-level.

## How it works

```
shortcut → mic (16 kHz) → every 350 ms: Parakeet (or whisper.cpp) over a trimmed window
         → keep words two passes agree on → fillers, stutters, commands, vocabulary → keystrokes
```

- **Append-only.** A word is typed once two consecutive passes agree on it.
- **Bounded window.** Once enough audio is committed, the window restarts just
  before the last committed word, so each pass costs the same however long you
  talk.
- **Voice commands.** "New line", "new paragraph" and "scratch that" fire only
  when said on their own; "scratch that" can only erase what the current
  dictation typed.
- **Ends when you're done, not when you pause.** Silence is judged against
  the room's own noise floor, and the timeout triples while the sentence is
  unfinished ("…and", "…because", "…the").
- **Stutters collapse.** "the the" or "with a with a" is typed once, without
  backspacing.
- **Greedy decoding.** Beam search crashed whisper.cpp mid-dictation (SIGTRAP),
  so it is off, and a test fails if it comes back.

[`ARCHITECTURE.md`](ARCHITECTURE.md) has the details.

## Tests

```bash
cd mac && swift test                   # FreeflowCore: streaming, text processing, scoring
.venv/bin/python -m pytest -q          # the Python reference
```

Both suites run the same fixtures in `tests/fixtures/streams`, each one a
sequence of decoder passes and the words that must be typed after each; two
are taken from real pass logs. CI runs both, builds the release app, and
replays the benchmark's gate clips through it with each engine: it fails if
streaming WER exceeds offline WER by more than 2 points, and a control run with
a broken window has to fail too.

## Python reference implementation

`freeflow/` is the first version: the same pipeline as a terminal app, with a
choice of whisper.cpp or faster-whisper and Simplified Chinese support through
a multilingual model.

```bash
python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python -m freeflow check     # record 4 s and print the text, no permissions needed
.venv/bin/python -m freeflow           # run it; Right ⌘ toggles dictation
```

The terminal app you launch it from needs Microphone, Input Monitoring and
Accessibility. Settings are in `config.toml`: engine, model, language, trigger
key and mode, silence timeout, and typing versus pasting (paste for Chinese).

## License

MIT
