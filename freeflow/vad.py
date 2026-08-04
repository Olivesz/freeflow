"""Voice-activity / end-of-utterance detection.

Every tick we hand this the loudness (RMS) of the most recent audio. It decides
whether you're still talking, and reports when you've been silent long enough to
end the utterance and auto-insert the text.

This module is intentionally the one place where the *feel* of freeflow lives:
cut off too eagerly and it clips your last word; wait too long and dictation
feels laggy. See `is_speech()` below — that's yours to design.
"""

from __future__ import annotations


class EndpointDetector:
    def __init__(self, silence_ms: int, start_grace_ms: int, threshold: float = 0.010):
        self.silence_ms = silence_ms
        self.start_grace_ms = start_grace_ms
        self.threshold = threshold
        self.reset()

    def reset(self) -> None:
        self._silent_ms = 0
        self._elapsed_ms = 0
        self._noise_floor = self.threshold  # running estimate of "quiet room"

    def update(self, rms: float, dt_ms: int) -> bool:
        """Feed one tick. Returns True when the utterance should end."""
        self._elapsed_ms += dt_ms
        if self._elapsed_ms < self.start_grace_ms:
            return False  # ignore the awkward silence right after you start

        if self.is_speech(rms):
            self._silent_ms = 0
        else:
            self._silent_ms += dt_ms
        return self._silent_ms >= self.silence_ms

    # ------------------------------------------------------------------ #
    # TODO(you): decide what counts as "still speaking".
    #
    # Baseline below just compares loudness to a fixed threshold. It works,
    # but a fixed number is brittle: a loud cafe or a quiet room shifts the
    # right cutoff. This ~5-10 line method is the single biggest lever on how
    # freeflow *feels*, so it's a good one to own.
    #
    # Ideas to consider (pick one, or your own):
    #   - Adaptive noise floor: track the quietest recent RMS in
    #     `self._noise_floor` (e.g. slowly decay it toward low readings) and
    #     call it speech when `rms > noise_floor * K` (K ~ 3-4). This
    #     auto-calibrates to the room instead of a magic constant.
    #   - Hysteresis: require a higher level to *start* counting speech than to
    #     *keep* counting it, so a brief dip mid-sentence doesn't end you early.
    #
    # Trade-off to weigh: sensitivity (never clip my last word) vs. latency
    # (don't make me wait after I clearly stopped).
    # ------------------------------------------------------------------ #
    def is_speech(self, rms: float) -> bool:
        return rms > self.threshold
