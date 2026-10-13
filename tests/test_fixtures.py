"""The shared streaming fixtures, run against the Python reference.

The same files run under `swift test` against the mac app's streamer
(mac/Tests/FreeflowCoreTests/StreamFixtureTests.swift), so a behaviour change
on either side fails one of the two suites.
"""

import json
from pathlib import Path

import pytest

from freeflow.stt import StreamingTranscriber, Word, _is_nonspeech

FIXTURES = Path(__file__).parent / "fixtures"
STREAMS = sorted((FIXTURES / "streams").glob("*.json"))
NONSPEECH = json.loads((FIXTURES / "nonspeech.json").read_text())

# The mac app's window (WhisperStreamer.Config.shipped); fixtures without a
# "config" block run with it.
SHIPPED = {"trim_after_s": 3.0, "context_s": 1.5}


@pytest.mark.parametrize("path", STREAMS, ids=[p.stem for p in STREAMS])
def test_stream_fixture(path):
    fx = json.loads(path.read_text())
    cfg = fx.get("config", SHIPPED)
    st = StreamingTranscriber(engine=None, trim_after_s=cfg["trim_after_s"], context_s=cfg["context_s"])
    for n, p in enumerate(fx["passes"]):
        words = [Word(t, s, e) for t, s, e in p["words"]]
        out = st.finish_window(words) if p.get("final") else st.commit_window(words)
        assert [w.text for w in out] == p["commit"], f"pass {n}: commit"
        if "pending" in p:
            assert [w.text for w in st.buf.buffer] == p["pending"], f"pass {n}: pending"
        assert st.offset == pytest.approx(p["offset"]), f"pass {n}: offset"


@pytest.mark.parametrize("text", NONSPEECH["nonspeech"])
def test_nonspeech_is_dropped(text):
    assert _is_nonspeech(text)


@pytest.mark.parametrize("text", NONSPEECH["speech"])
def test_speech_passes(text):
    assert not _is_nonspeech(text)
