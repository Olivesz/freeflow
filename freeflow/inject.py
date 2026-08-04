"""Type transcribed text into whatever app currently has focus.

Two strategies:
  - "type":  simulate keystrokes via pynput. Great for English, feels natural
             for incremental streaming (we just type the newly-committed words).
  - "paste": stuff text on the clipboard and press Cmd+V. Robust for Chinese,
             emoji, and long bursts, at the cost of touching the clipboard
             (we save & restore it).

Both need macOS Accessibility permission for the controlling process.
"""

from __future__ import annotations

import subprocess
import time

from pynput import keyboard


class Injector:
    def __init__(self, mode: str = "type") -> None:
        self.mode = mode
        self._kb = keyboard.Controller()

    def emit(self, text: str) -> None:
        if not text:
            return
        if self.mode == "paste":
            self._paste(text)
        else:
            self._kb.type(text)

    def _paste(self, text: str) -> None:
        prev = subprocess.run(["pbpaste"], capture_output=True).stdout
        subprocess.run(["pbcopy"], input=text.encode("utf-8"), check=True)
        with self._kb.pressed(keyboard.Key.cmd):
            self._kb.tap("v")
        time.sleep(0.05)  # let the paste land before we restore the clipboard
        subprocess.run(["pbcopy"], input=prev, check=True)
