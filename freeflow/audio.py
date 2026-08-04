"""Microphone capture.

sounddevice hands us small float32 frames on its own audio thread. We just
append them to a growing buffer under a lock. The transcription worker takes
`snapshot()`s of that buffer; `tail_rms()` powers voice-activity detection.
"""

from __future__ import annotations

import threading

import numpy as np
import sounddevice as sd

from . import SAMPLE_RATE

BLOCK = 1600  # 100 ms of audio per callback at 16 kHz


class Recorder:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._chunks: list[np.ndarray] = []
        self._stream: sd.InputStream | None = None

    def _callback(self, indata, frames, time_info, status):  # noqa: ARG002
        # Runs on sounddevice's audio thread — keep it cheap: copy & stash.
        with self._lock:
            self._chunks.append(indata[:, 0].copy())

    def start(self) -> None:
        with self._lock:
            self._chunks = []
        self._stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=1,
            dtype="float32",
            blocksize=BLOCK,
            callback=self._callback,
        )
        self._stream.start()

    def stop(self) -> None:
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()
            self._stream = None

    def snapshot(self) -> np.ndarray:
        """Everything captured so far this utterance, as one contiguous array."""
        with self._lock:
            if not self._chunks:
                return np.zeros(0, dtype=np.float32)
            return np.concatenate(self._chunks)

    def tail_rms(self, ms: int) -> float:
        """Loudness (RMS) of the last `ms` milliseconds — the VAD's raw signal."""
        n = int(SAMPLE_RATE * ms / 1000)
        with self._lock:
            if not self._chunks:
                return 0.0
            recent = np.concatenate(self._chunks[-max(1, n // BLOCK + 1):])
        recent = recent[-n:]
        if recent.size == 0:
            return 0.0
        return float(np.sqrt(np.mean(recent**2)))


def list_devices() -> str:
    return str(sd.query_devices())
