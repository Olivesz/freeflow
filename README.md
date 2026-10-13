# freeflow

[![CI](https://github.com/Olivesz/freeflow/actions/workflows/ci.yml/badge.svg)](https://github.com/Olivesz/freeflow/actions/workflows/ci.yml)

Local dictation for macOS. Press a shortcut, talk, and the words are typed into
whatever app has focus as you speak. Whisper runs on-device through
whisper.cpp: no account, no cloud, nothing to pay.

Words are typed while you're still talking, and a typed word is never taken
back. Here is the shipped streamer replaying the JFK sample at the app's
350 ms tick ([`bench/ticks.py`](bench/ticks.py) on
[its pass log](bench/results/9832030/timing/logs/jfk.jsonl)):

```
jfk: 11 s, tick 350 ms, window 3/1.5 s, greedy
   1.75s  + And
   2.10s  + so my fellow
   2.45s  + Americans.
   4.20s  + ask
   4.55s  + not
   7.35s  + what your country can do for you.
   9.45s  + ask what
   9.80s  + you can
  10.15s  + do for
  10.50s  + your country.
streamed: And so my fellow Americans. ask not what your country can do for you. ask what you can do for your country.
offline:  And so my fellow Americans, ask not what your country can do for you, ask what you can do for your country.
```

## Install

Needs macOS 14 and Xcode's command-line tools.

```bash
git clone https://github.com/Olivesz/freeflow.git
cd freeflow/mac
./build_app.sh        # builds, downloads the model (sha256-checked), bundles it
open freeflow.app
```

The first launch walks through the two permissions: Microphone, and
Accessibility so it can type into other apps. The default shortcut is ⌥Space;
tap to start, and it stops after 1.5 s of silence (both changeable). Run
`./setup-signing.sh` once if you rebuild often: a stable signing identity keeps
the Accessibility grant across rebuilds.

## Does streaming cost accuracy?

Streaming re-decodes a short window every 350 ms, so it hears less context than
decoding the whole recording at once. The benchmark in [`bench/`](bench/)
replays 41 public clips (JFK plus 40 LibriSpeech test-clean speakers) through
the app's own streamer and scores both against the reference, on the same
model:

Held-out split, 20 LibriSpeech speakers, 523 words:

| streamer | streamed WER | offline WER | words dropped |
|---|---|---|---|
| [`0f70dcd`](bench/results/0f70dcd/shipped/summary.csv) | 19.7% | 5.4% | 78 of 523 |
| [`9832030`](bench/results/9832030/timing/summary.csv) | 6.7% | 5.4% | 3 of 523 |

The first row is the streamer before
[`262c910`](https://github.com/Olivesz/freeflow/commit/262c910): it dropped about
one word in seven that offline decoding of the same audio got right, because it
trusted whisper.cpp's word timestamps, which drift by up to a second between
passes. The fix finds the boundary between typed and new words by matching
text. It was built, and the window chosen, on the other 20 speakers and JFK;
the held-out speakers were first scored after the fix was committed. Per-clip
numbers, every pass of every clip, and the commands to reproduce them are in
[`bench/`](bench/).

## How it works

```
shortcut → mic (16 kHz) → every 350 ms: whisper.cpp over a trimmed window
         → keep words two passes agree on → fillers, commands, vocabulary → keystrokes
```

- **Append-only.** A word is typed once two consecutive passes agree on it.
- **Bounded window.** Once enough audio is committed, the window restarts just
  before the last committed word, so each pass costs the same however long you
  talk.
- **Voice commands.** "New line", "new paragraph" and "scratch that" fire only
  when said on their own; "scratch that" can only erase what the current
  dictation typed.
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
replays the benchmark's gate clips through it with the real model: it fails if
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
