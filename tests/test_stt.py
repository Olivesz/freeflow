"""The streaming driver, tested without any model, mic, or permissions.

The property that makes freeflow feel right is APPEND-ONLY output: once a word
has been injected into the focused app it must never be revised. The commit
rule itself is pinned by the shared fixtures (test_fixtures.py); these tests
cover the audio side: which windows reach the engine, and how big they are.
"""

import numpy as np

from freeflow import SAMPLE_RATE as SR
from freeflow.stt import StreamingTranscriber, Word


# ─────────────────────── streaming driver ─────────────────────── #
class ScriptedEngine:
    """Returns the next scripted word list per call; records received windows."""

    def __init__(self, script):
        self.script = list(script)
        self.received: list[int] = []

    def words(self, audio):
        self.received.append(len(audio))
        return [Word(t, s, e) for (t, s, e) in self.script.pop(0)] if self.script else []


def speechlike(seconds: float) -> np.ndarray:
    return np.full(int(seconds * SR), 0.1, dtype=np.float32)


def test_dead_silence_and_tiny_windows_never_reach_the_engine():
    eng = ScriptedEngine([])
    st = StreamingTranscriber(eng)
    assert st.process(np.zeros(SR * 3, dtype=np.float32)) == ""   # silent
    assert st.process(speechlike(0.25)) == ""                     # < 0.5 s
    assert eng.received == []


def test_streaming_output_is_append_only_and_trims_the_window():
    five = [(f" w{i}", i * 2.0, i * 2.0 + 2.0) for i in range(5)]  # 10 s of speech
    eng = ScriptedEngine([five, five, [(" w4", 0.0, 2.0)]])
    st = StreamingTranscriber(eng, trim_after_s=8.0, context_s=2.0)
    audio = speechlike(12.0)

    out1 = st.process(audio)     # first hearing: nothing stable yet
    out2 = st.process(audio)     # second hearing agrees: all five commit
    out3 = st.process(audio)     # post-trim re-hearing of w4 must not re-emit

    assert out1 == ""
    assert out2 == " w0 w1 w2 w3 w4"
    assert out3 == ""
    # After committing through t=10 s the window is trimmed to context_s of
    # committed audio: engine 3 saw only the last 4 s, not all 12.
    assert eng.received[2] == 4 * SR


def test_final_flush_commits_the_unconfirmed_tail_once():
    eng = ScriptedEngine(
        [
            [(" hello", 0.0, 0.5)],
            [(" hello", 0.0, 0.5)],
            [(" hello", 0.0, 0.5), (" bye", 0.5, 1.0)],
        ]
    )
    st = StreamingTranscriber(eng)
    audio = speechlike(2.0)
    st.process(audio)
    assert st.process(audio) == " hello"
    # Stop pressed: flush trusts the tail but must not re-type " hello".
    assert st.flush(audio) == " bye"
