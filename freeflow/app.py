"""The orchestrator: hotkey -> capture -> stream -> stabilize -> inject.

Threading model (three players):
  1. main thread     — the pynput keyboard Listener (the trigger).
  2. audio thread    — sounddevice callback filling the mic buffer.
  3. worker thread   — the transcribe/inject/VAD loop for one utterance.

Only the worker ever tears an utterance down (`_finalize`), so a manual stop
(hotkey) and an automatic stop (VAD) can't race into a double-teardown or a
join-on-self deadlock — both just flip `self._recording = False`.
"""

from __future__ import annotations

import threading
import time

from pynput import keyboard

from .audio import Recorder
from .config import Config
from .inject import Injector
from .stt import build_transcriber
from .vad import EndpointDetector

IDLE, RECORDING = "idle", "recording"


class FreeFlowApp:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        print(f"loading '{cfg.model.name}' via {cfg.model.engine}…", flush=True)
        self.transcriber = build_transcriber(cfg)
        self.recorder = Recorder()
        self.injector = Injector(cfg.stream.inject)
        self.endpoint = EndpointDetector(cfg.vad.silence_ms, cfg.vad.start_grace_ms)

        self._state = IDLE
        self._recording = False
        self._finalized = True
        self._emitted_any = False
        self._lock = threading.Lock()
        self._worker: threading.Thread | None = None

        self._trigger = self._resolve_key(cfg.trigger.key)
        self._trigger_held = False
        self._vad_active = cfg.vad.enabled and cfg.trigger.mode == "toggle"

    # ----- lifecycle of one utterance ------------------------------------- #
    def start(self) -> None:
        with self._lock:
            if self._state == RECORDING:
                return
            self._state = RECORDING
            self._recording = True
            self._finalized = False
            self._emitted_any = False
        self.recorder.start()
        self.transcriber.reset()
        self.endpoint.reset()
        self._worker = threading.Thread(target=self._run_worker, daemon=True)
        self._worker.start()
        print("● recording…", flush=True)

    def request_stop(self) -> None:
        self._recording = False  # worker notices, then finalizes

    def toggle(self) -> None:
        if self._state == IDLE:
            self.start()
        else:
            self.request_stop()

    def _run_worker(self) -> None:
        tick = self.cfg.stream.tick_ms / 1000
        next_tick = time.monotonic()
        while self._recording:
            now = time.monotonic()
            if now >= next_tick:
                audio = self.recorder.snapshot()
                self._emit(self.transcriber.process(audio))
                if self._vad_active:
                    rms = self.recorder.tail_rms(self.cfg.stream.tick_ms)
                    if self.endpoint.update(rms, self.cfg.stream.tick_ms):
                        self._recording = False
                        break
                next_tick = now + tick
            time.sleep(0.02)
        self._finalize()

    def _finalize(self) -> None:
        with self._lock:
            if self._finalized:
                return
            self._finalized = True
        audio = self.recorder.snapshot()
        self.recorder.stop()
        self._emit(self.transcriber.flush(audio))
        self._state = IDLE
        print("■ inserted.\n", flush=True)

    def _emit(self, text: str) -> None:
        if not text:
            return
        if not self._emitted_any:
            text = text.lstrip()  # don't shove a leading space into an empty field
            if not text:
                return
            self._emitted_any = True
        self.injector.emit(text)

    # ----- hotkey plumbing ------------------------------------------------- #
    @staticmethod
    def _resolve_key(name: str):
        name = name.lower()
        if hasattr(keyboard.Key, name):
            return getattr(keyboard.Key, name)
        return keyboard.KeyCode.from_char(name)

    def _match(self, key) -> bool:
        if isinstance(self._trigger, keyboard.Key):
            return key == self._trigger
        return isinstance(key, keyboard.KeyCode) and key.char == self._trigger.char

    def _on_press(self, key) -> None:
        if not self._match(key) or self._trigger_held:
            return
        self._trigger_held = True  # ignore auto-repeat while physically held
        if self.cfg.trigger.mode == "hold":
            self.start()
        else:
            self.toggle()

    def _on_release(self, key) -> None:
        if not self._match(key):
            return
        self._trigger_held = False
        if self.cfg.trigger.mode == "hold":
            self.request_stop()

    def run(self) -> None:
        mode = self.cfg.trigger.mode
        how = "hold to talk, release to stop" if mode == "hold" else \
              "tap to start · tap again or go quiet to stop"
        print(f"\nfreeflow ready — trigger: [{self.cfg.trigger.key}]  ({how})")
        print("Ctrl+C to quit.\n", flush=True)
        with keyboard.Listener(on_press=self._on_press, on_release=self._on_release) as listener:
            listener.join()
