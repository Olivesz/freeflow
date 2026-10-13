"""Streaming speech-to-text: engines + word stabilization + buffer trimming.

Three layers, cleanly separated:

  1. Engine        — turns an audio window into timestamped Words. Two backends:
                     FasterWhisperEngine (CPU) and WhisperCppEngine (Metal/ANE).
  2. HypothesisBuffer — LocalAgreement: only commit a word once two passes agree,
                     so text we already typed is never revised (append-only).
  3. StreamingTranscriber — feeds a *trimmed* window to the engine each tick so
                     long dictations don't re-transcribe from scratch forever,
                     and turns committed Words into text to inject.

Swapping the whole model is a one-liner in config (`model.engine`); everything
downstream speaks in `Word`s, not in any particular library's types.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

import numpy as np

from . import SAMPLE_RATE

SR = SAMPLE_RATE
CJK = {"zh", "yue", "ja", "ko"}  # languages without spaces between words

# Whisper was trained on subtitles, so on NON-speech it emits sound-event
# annotations like "[BLANK_AUDIO]", "(water splashing)", "♪ music ♪", or bare
# punctuation. Those are never real dictation — drop any token carrying these.
_NONSPEECH_RE = re.compile(r"[\[\]()♪*]")


@dataclass
class Word:
    text: str      # raw, WITH a leading space for spaced languages (join-ready)
    start: float   # seconds, absolute within the utterance
    end: float


def _norm(word: str) -> str:
    return word.strip().lower()


def _is_nonspeech(text: str) -> bool:
    t = text.strip()
    if not t:
        return True
    if _NONSPEECH_RE.search(t):     # bracketed / musical annotation
        return True
    return not re.search(r"\w", t)  # pure punctuation, e.g. a lone "."


# ─────────────────────────── engines ─────────────────────────── #
class FasterWhisperEngine:
    """CTranslate2 backend. Runs on CPU on macOS; word timestamps are native."""

    def __init__(self, name: str, language: str, compute_type: str, device: str):
        from faster_whisper import WhisperModel

        self.model = WhisperModel(name, device=device, compute_type=compute_type)
        self.language = None if language == "auto" else language

    def words(self, audio: np.ndarray) -> list[Word]:
        # faster-whisper's mel filterbank warns (log 0) on silent frames — benign.
        with np.errstate(divide="ignore", over="ignore", invalid="ignore"):
            segments, _ = self.model.transcribe(
                audio,
                language=self.language,
                word_timestamps=True,
                beam_size=1,                   # greedy = lowest latency for live use
                condition_on_previous_text=False,
                vad_filter=True,               # Silero VAD drops non-speech → no silence hallucinations
            )
            out: list[Word] = []
            for seg in segments:
                cand = seg.words or [Word(seg.text, seg.start, seg.end)]
                for w in cand:
                    text = getattr(w, "word", None) or w.text
                    if not _is_nonspeech(text):
                        out.append(Word(text, w.start, w.end))
            return out


class WhisperCppEngine:
    """whisper.cpp backend via pywhispercpp — uses Metal / the Neural Engine on
    Apple Silicon, so it's faster and cooler than the CPU path. We ask it to
    split output to one word per segment to get word-level timestamps."""

    def __init__(self, name: str, language: str):
        import os

        from pywhispercpp.model import Model

        self.language = None if language == "auto" else language
        self._space = "" if self.language in CJK else " "
        self.model = Model(
            name, redirect_whispercpp_logs_to=os.devnull,  # hush whisper.cpp's C logs
            print_realtime=False, print_progress=False,
        )
        self._params = {"language": self.language} if self.language else {}
        self._params["no_speech_thold"] = 0.6   # skip segments the model deems non-speech

    def words(self, audio: np.ndarray) -> list[Word]:
        segs = self.model.transcribe(
            audio, token_timestamps=True, max_len=1, split_on_word=True, **self._params
        )
        out: list[Word] = []
        for s in segs:
            if _is_nonspeech(s.text):
                continue
            # whisper.cpp times are centiseconds; tokens carry no leading space.
            out.append(Word(self._space + s.text, s.t0 / 100.0, s.t1 / 100.0))
        return out


# ─────────────────── LocalAgreement stabilization ─────────────────── #
class HypothesisBuffer:
    """Confirms a word only when consecutive passes agree on it (LocalAgreement-2).

    `buffer` holds the previous pass's still-unconfirmed tail. Each new pass, we
    commit the longest prefix where the new tail matches the previous tail —
    those words are stable, so it's safe to type them and never take them back.
    """

    def __init__(self) -> None:
        self.committed: list[Word] = []
        self.buffer: list[Word] = []
        self.new: list[Word] = []
        self.last_time = 0.0   # end time of the last committed word

    def insert(self, words: list[Word]) -> None:
        # 1) ignore anything at/behind what we already committed by TIME (works
        #    for engines with precise word timestamps, e.g. faster-whisper).
        words = [w for w in words if w.start > self.last_time - 0.1]
        # 2) also dedup by TEXT: if the first new words repeat the committed
        #    tail, drop them. Catches boundary repeats from engines with coarse
        #    timestamps (e.g. whisper.cpp). Check up to a 6-word overlap.
        if self.committed and words:
            tail = [_norm(w.text) for w in self.committed[-6:]]
            head = [_norm(w.text) for w in words[:6]]
            for k in range(min(len(tail), len(head)), 0, -1):
                if tail[-k:] == head[:k]:
                    words = words[k:]
                    break
        self.new = words

    def flush(self) -> list[Word]:
        out: list[Word] = []
        i = 0
        while (i < len(self.new) and i < len(self.buffer)
               and _norm(self.new[i].text) == _norm(self.buffer[i].text)):
            out.append(self.new[i])
            self.last_time = self.new[i].end
            i += 1
        self.committed.extend(out)
        self.buffer = self.new[i:]   # leftover new tail becomes next pass's baseline
        return out


# ─────────────────────── the streaming driver ─────────────────────── #
class StreamingTranscriber:
    def __init__(self, engine, trim_after_s: float = 8.0, context_s: float = 2.0,
                 silence_floor: float = 0.005):
        self.engine = engine
        self.trim_after_s = trim_after_s   # trim once this much committed audio piles up
        self.context_s = context_s         # keep this much committed audio for context
        self.silence_floor = silence_floor  # RMS below this = dead silence; never transcribe it
        self.reset()

    @staticmethod
    def _rms(a: np.ndarray) -> float:
        return float(np.sqrt(np.mean(a**2))) if a.size else 0.0

    def reset(self) -> None:
        self.buf = HypothesisBuffer()
        self.offset = 0.0   # seconds trimmed off the front of the utterance

    def _window(self, audio: np.ndarray) -> np.ndarray:
        return audio[int(self.offset * SR):]

    def _to_absolute(self, words: list[Word]) -> list[Word]:
        return [Word(w.text, w.start + self.offset, w.end + self.offset) for w in words]

    def process(self, audio: np.ndarray) -> str:
        """One live pass. Returns only newly-stable text to inject."""
        window = self._window(audio)
        if window.size < SR // 2:          # < 0.5 s: too little to commit anything
            return ""
        if self._rms(window) < self.silence_floor:   # dead silence — skip the model entirely
            return ""
        return "".join(w.text for w in self.commit_window(self.engine.words(window)))

    def flush(self, audio: np.ndarray) -> str:
        """Final pass on stop: trust the whole tail and commit whatever's left."""
        window = self._window(audio)
        if window.size == 0 or self._rms(window) < self.silence_floor:
            return ""
        return "".join(w.text for w in self.finish_window(self.engine.words(window)))

    # The two methods below are the whole streaming rule, with no audio and no
    # engine: `words` are one pass's output, times relative to the window start.
    # The Swift app's WhisperStreamer implements the same rule, and both run the
    # shared fixtures in tests/fixtures/streams.

    def commit_window(self, words: list[Word]) -> list[Word]:
        """One live pass: returns the words that just became stable."""
        self.buf.insert(self._to_absolute([w for w in words if not _is_nonspeech(w.text)]))
        committed = self.buf.flush()
        self._maybe_trim()
        return committed

    def finish_window(self, words: list[Word]) -> list[Word]:
        """Stop: commit the unconfirmed tail, minus anything already typed."""
        self.buf.insert(self._to_absolute([w for w in words if not _is_nonspeech(w.text)]))
        remaining = self.buf.new
        if remaining:
            self.buf.last_time = remaining[-1].end
            self.buf.committed.extend(remaining)
        return remaining

    def _maybe_trim(self) -> None:
        # Once a lot of already-committed audio sits in the window, drop it —
        # keep only `context_s` of it so the engine has boundary context. This
        # bounds per-tick cost no matter how long you talk.
        if self.buf.last_time - self.offset > self.trim_after_s:
            self.offset = max(self.offset, self.buf.last_time - self.context_s)


def build_transcriber(cfg) -> StreamingTranscriber:
    """Construct the streaming transcriber for the configured engine."""
    m = cfg.model
    if m.engine == "whisper.cpp":
        engine = WhisperCppEngine(m.name, m.language)
    else:
        engine = FasterWhisperEngine(m.name, m.language, m.compute_type, m.device)
    return StreamingTranscriber(engine)
