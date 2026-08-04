"""End-of-utterance detection timing. These tests pin the *contract* of
EndpointDetector.update() — grace period, silence accumulation, reset on
speech — independent of how is_speech() decides what counts as speech, so a
smarter is_speech (adaptive floor, hysteresis) must still pass them.

LOUD is far above any sane speech threshold; SILENT is digital zero.
"""

from freeflow.vad import EndpointDetector

LOUD = 0.5
SILENT = 0.0
TICK = 100  # ms


def make(silence_ms=900, start_grace_ms=500):
    return EndpointDetector(silence_ms=silence_ms, start_grace_ms=start_grace_ms)


def test_silence_during_grace_period_never_ends():
    d = make(silence_ms=300, start_grace_ms=500)
    for _ in range(5):  # 500 ms of dead silence, all inside the grace window
        assert d.update(SILENT, TICK) is False


def test_continuous_silence_ends_after_threshold():
    d = make(silence_ms=300, start_grace_ms=0)
    assert d.update(SILENT, TICK) is False   # 100 ms
    assert d.update(SILENT, TICK) is False   # 200 ms
    assert d.update(SILENT, TICK) is True    # 300 ms — utterance over


def test_speech_resets_the_silence_clock():
    d = make(silence_ms=300, start_grace_ms=0)
    d.update(SILENT, TICK)
    d.update(SILENT, TICK)          # 200 ms silent, about to trip...
    assert d.update(LOUD, TICK) is False     # ...speech resets the counter
    assert d.update(SILENT, TICK) is False   # 100 ms
    assert d.update(SILENT, TICK) is False   # 200 ms
    assert d.update(SILENT, TICK) is True    # 300 ms


def test_mid_sentence_pause_shorter_than_threshold_survives():
    d = make(silence_ms=1500, start_grace_ms=0)
    for _ in range(14):                      # 1400 ms pause — natural breath
        assert d.update(SILENT, TICK) is False
    assert d.update(LOUD, TICK) is False     # resumed talking, still live


def test_reset_restores_grace_period():
    d = make(silence_ms=200, start_grace_ms=300)
    for _ in range(10):
        d.update(SILENT, TICK)
    d.reset()
    # Fresh utterance: grace period applies again.
    assert d.update(SILENT, TICK) is False
    assert d.update(SILENT, TICK) is False
    assert d.update(SILENT, TICK) is False   # 300 ms — grace just ending
