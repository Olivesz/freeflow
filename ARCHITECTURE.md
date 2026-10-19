# How freeflow works

Two implementations of one idea. The **mac app** (`mac/`, Swift) is the
product. The **Python app** (`freeflow/`) came first and is kept as the
reference for the streaming rule; both run the same fixtures.

## The mac app, one dictation

```
hotkey ─▶ AudioCapture ─▶ Dictation loop (every 350 ms)
          16 kHz mono       │
                            ├─ StreamingSession   skip < 0.5 s or silent windows, cut trailing silence
                            ├─ WordDecoder        Parakeet TDT 0.6B v2 (Core ML), or whisper.cpp base.en
                            ├─ WhisperStreamer    decide which words are stable
                            ├─ TextProcessor      fillers, voice commands, vocabulary, capitals
                            └─ TextInjector       synthetic key events into the focused app
          SilenceEndpointer ends the utterance after the configured quiet,
                            longer while a sentence is still open
```

Everything between the decoder and the keyboard lives in `FreeflowCore`, a
library with no model or UI dependency, so `swift test` covers it with no
model and no microphone. The app target (`mac/Sources/Freeflow`) adds the
decoders, the audio, the menubar, the HUD, onboarding and settings.

### The decoder (`WordDecoder`)

Anything that turns a window of audio into timed words. Two ship:

- **Parakeet TDT 0.6B v2** (NVIDIA, CC-BY-4.0), on the Neural Engine through
  FluidAudio. The default. It is downloaded on first launch (about 450 MB);
  until it is ready, and if it ever fails to load, Whisper serves instead, and
  the swap waits for the current dictation to end.
- **whisper.cpp `base.en`**, bundled with the app, so dictation always works
  offline from the first launch.

Parakeet decodes some input lengths as blank or as a low-confidence loop (an
upstream bug in the Core ML port). `DecodeCheck` spots both, and the window
is decoded again padded with silence to the model's full 15 s input, which
decodes it correctly. Only failed windows are padded: padding every window
costs accuracy.

### Stable words (`WhisperStreamer`)

Every tick re-decodes the current window, and the decoder may revise any word
in it. Typed text can't be revised, so a word is only typed once two
consecutive passes agree on it (LocalAgreement-2).

The hard part is knowing which words of a new pass are already typed. Word
times from whisper.cpp drift by up to a second between passes, and the last
word of a pass is stretched toward the end of the window, so the cut is found
by text: the longest run of the last committed words that the new pass repeats,
taking the occurrence nearest in time if it appears twice. A time cutoff is the
fallback when the pass repeats none of them. Times are clamped to the window,
because whisper.cpp occasionally reports a word ending tens of seconds past the
audio.

To keep each pass fast, the window is trimmed once enough committed audio piles
up: it restarts a little before the last committed word. Whisper uses
`Config.shipped` (3 / 1.5 s); Parakeet, which is faster per pass and more
accurate with context, uses a longer one (`Config.parakeet`).

### Ending an utterance (`SilenceEndpointer`)

Speech is anything well above the room's noise floor, estimated from the
quietest 50 ms frames of the last few seconds, so a quiet voice in a quiet room
still counts and a noisy room never makes it stricter than a fixed threshold.
When the transcript so far ends mid-sentence (no final punctuation, or a word
like "and", "because", "the"), the silence allowed is tripled, so pausing to
think doesn't cut the sentence off.

### Edits (`TextProcessor`)

Turns committed words into `insert` and `delete` operations. It drops fillers,
handles "new line", "new paragraph" and "scratch that", applies the custom
vocabulary (including multi-word keys, by backspace and retype) and capitalises
sentence starts. With filler cleanup on, a repeated word or short phrase ("the
the", "we can we can") is typed once: the possible repeat is held back
until the next word shows whether it was one, so nothing is backspaced. Deletes are bounded to what the current utterance typed, so it
can never erase text that was in the field before.

A command only fires when it is said on its own: the decoder ends it with a
period or capitalises the next word. "Delete that file" stays literal.

### Around the loop

- **Whisper decoding is greedy.** Beam search makes whisper.cpp SIGTRAP on
  some audio; `Decoding.shipped` is pinned and a test fails if it changes.
- **RecordingStore** (opt-in, off by default) keeps each dictation's audio on
  the Mac. Confirming or fixing a transcript in History makes it a reference,
  and `bench/personal.py` turns the reviewed ones into a private benchmark of
  your own voice and vocabulary.
- **CrashRelaunch** re-execs the app on a fatal signal so the hotkey never goes
  dead.
- **HistoryStore** keeps the last 50 transcripts in Application Support.
- **Diag** writes per-utterance timing to `/tmp/freeflow-diag.log`, only when
  `FREEFLOW_DIAG` is set, since it includes the transcript.
- **Permissions:** microphone and Accessibility. The hotkey uses Carbon's
  `RegisterEventHotKey`, which needs no Input Monitoring grant.

### Offline modes of the same binary

| Flag | What it does |
|---|---|
| `--selftest <wav>` | replays a clip through the live loop's rules and prints each tick's new words |
| `--selftest-proc <wav>` | the same, through TextProcessor, printing the text that would be typed |
| `--bench <manifest> --out <dir>` | the benchmark in `bench/` |
| `--pause-bench <manifest> --out <csv>` | splices pauses into clips and counts where the endpointer would cut |
| `--vocab-bench <manifest> <glossaries> --out <json>` | acoustic vocabulary boosting, scored against plain decoding |
| `--render-ui <dir>` | snapshots the dashboard to PNG |

The replay modes take `--engine parakeet|whisper` (default: the shipped
engine) and `--trim <after>/<context>|none` (default: that engine's window).

## The Python app

`python -m freeflow` runs the same pipeline in a terminal: `audio.py`
(sounddevice), `stt.py` (faster-whisper or whisper.cpp, the same streaming
rule), `vad.py` (adaptive-floor endpointing) and `inject.py` (pynput). Its
`StreamingTranscriber.commit_window` is the streaming rule with no audio, which
is what the shared fixtures in `tests/fixtures/streams` drive.

## Tests

- `pytest` runs the Python suite, including every shared fixture.
- `cd mac && swift test` runs `FreeflowCoreTests`: the same fixtures, the
  TextProcessor cases, the session and endpointer rules, and WER scoring.
- CI also replays the gate clips through the release build with the real
  model and fails if streaming loses accuracy against offline decoding
  (`bench/gate.py`). A second run with a deliberately broken window must fail,
  or CI fails.
