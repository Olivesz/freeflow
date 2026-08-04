"""Load config.toml into simple, typed dataclasses with sane defaults.

Kept deliberately boring: read the TOML, fall back to defaults, done. The
config file is the *only* UI freeflow has — like a keybind file for a game.
"""

from __future__ import annotations

import tomllib
from dataclasses import dataclass
from pathlib import Path


@dataclass
class ModelCfg:
    engine: str = "faster-whisper"  # "faster-whisper" | "whisper.cpp"
    name: str = "base.en"
    language: str = "en"            # "auto" lets Whisper detect; "en"/"zh" locks it
    compute_type: str = "int8"
    device: str = "cpu"


@dataclass
class TriggerCfg:
    mode: str = "toggle"            # "toggle" | "hold"
    key: str = "cmd_r"


@dataclass
class VadCfg:
    enabled: bool = True
    silence_ms: int = 900
    start_grace_ms: int = 500


@dataclass
class StreamCfg:
    tick_ms: int = 600
    inject: str = "type"            # "type" | "paste"


@dataclass
class Config:
    model: ModelCfg
    trigger: TriggerCfg
    vad: VadCfg
    stream: StreamCfg

    @staticmethod
    def load(path: str | Path = "config.toml") -> "Config":
        path = Path(path)
        raw: dict = {}
        if path.exists():
            with path.open("rb") as f:
                raw = tomllib.load(f)
        # Each section merges file values over dataclass defaults, so a partial
        # config.toml (or a missing one) still yields a fully-populated Config.
        return Config(
            model=ModelCfg(**raw.get("model", {})),
            trigger=TriggerCfg(**raw.get("trigger", {})),
            vad=VadCfg(**raw.get("vad", {})),
            stream=StreamCfg(**raw.get("stream", {})),
        )
