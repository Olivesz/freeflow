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
        self._speaking = False

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

    def is_speech(self, rms: float) -> bool:
        # Adaptive noise floor: snap down to quieter readings immediately,
        # drift up only very slowly — the estimate tracks the ROOM, not the
        # speech, so a cafe and a silent office both get the right cutoff.
        if rms < self._noise_floor:
            self._noise_floor = max(rms, 1e-4)
        else:
            self._noise_floor += (rms - self._noise_floor) * 0.005
        # Hysteresis: opening the gate takes 4x the floor, holding it open
        # only 2x, so a brief mid-sentence dip doesn't read as silence. The
        # absolute minimum keeps a near-silent room from becoming hair-trigger.
        k = 2.0 if self._speaking else 4.0
        self._speaking = rms > max(self._noise_floor * k, self.threshold * 0.4)
        return self._speaking
