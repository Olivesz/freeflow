"""Config loading: a partial (or missing) config.toml must still yield a
fully-populated Config — the file is the product's only UI, so a typo'd or
deleted file degrading to defaults (not a crash) is a core behavior."""

from pathlib import Path

from freeflow.config import Config


def test_missing_file_yields_full_defaults(tmp_path: Path):
    cfg = Config.load(tmp_path / "nope.toml")
    assert cfg.model.engine == "faster-whisper"
    assert cfg.model.name == "base.en"
    assert cfg.trigger.mode == "toggle"
    assert cfg.vad.enabled is True
    assert cfg.stream.inject == "type"


def test_partial_file_merges_over_defaults(tmp_path: Path):
    p = tmp_path / "config.toml"
    p.write_text('[model]\nname = "small"\nlanguage = "zh"\n')
    cfg = Config.load(p)
    # overridden
    assert cfg.model.name == "small"
    assert cfg.model.language == "zh"
    # untouched sections and keys keep their defaults
    assert cfg.model.engine == "faster-whisper"
    assert cfg.vad.silence_ms == 900
    assert cfg.trigger.key == "cmd_r"


def test_full_file_round_trip(tmp_path: Path):
    p = tmp_path / "config.toml"
    p.write_text(
        "[model]\n"
        'engine = "whisper.cpp"\nname = "large-v3"\nlanguage = "auto"\n'
        'compute_type = "float16"\ndevice = "cpu"\n'
        "[trigger]\n"
        'mode = "hold"\nkey = "f13"\n'
        "[vad]\n"
        "enabled = false\nsilence_ms = 1200\nstart_grace_ms = 250\n"
        "[stream]\n"
        'tick_ms = 400\ninject = "paste"\n'
    )
    cfg = Config.load(p)
    assert cfg.model.engine == "whisper.cpp"
    assert cfg.model.language == "auto"
    assert cfg.trigger.mode == "hold"
    assert cfg.vad.enabled is False
    assert cfg.vad.silence_ms == 1200
    assert cfg.stream.tick_ms == 400
    assert cfg.stream.inject == "paste"


def test_repo_config_toml_is_loadable():
    """The checked-in config.toml must always parse — it's the first thing a
    new user touches."""
    repo_cfg = Path(__file__).resolve().parent.parent / "config.toml"
    cfg = Config.load(repo_cfg)
    assert cfg.model.engine in ("whisper.cpp", "faster-whisper")
    assert cfg.trigger.mode in ("toggle", "hold")
