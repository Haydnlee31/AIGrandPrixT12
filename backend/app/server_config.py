"""Explicit, inert loading of server-side inference settings.

Importing this module never reads a file. No shell expansion or command execution
is performed, and callers receive names only from load_server_env, never values.
"""
from __future__ import annotations

import os
from pathlib import Path
import shlex


INFERENCE_NAMES = frozenset({"ASTRA_API_KEY", "OPENAI_API_KEY", "ASTRA_MODEL", "MULTIMODAL_TRANSCRIPTION_MODEL"})


class ServerConfigError(ValueError):
    def __init__(self):
        # Deliberately excludes source lines, paths, and credential values.
        super().__init__("The explicit inference configuration file could not be read safely.")


def read_server_env(path: str | Path) -> dict[str, str]:
    """Read at most 64 KiB from the explicit path, accepting only inference keys."""
    try:
        with Path(path).open("rb") as source:
            raw = source.read(65537)
        if len(raw) > 65536:
            raise ServerConfigError()
        text = raw.decode("utf-8")
        result = {}
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[7:].lstrip()
            name, separator, value = line.partition("=")
            name = name.strip()
            if not separator or name not in INFERENCE_NAMES:
                continue
            fields = shlex.split(value, comments=True, posix=True)
            if len(fields) > 1:
                raise ServerConfigError()
            parsed = fields[0] if fields else ""
            if any(ord(character) < 32 or ord(character) == 127 for character in parsed):
                raise ServerConfigError()
            result[name] = parsed
        return result
    except (OSError, UnicodeError, ValueError):
        raise ServerConfigError() from None


def load_server_env(path: str | Path, *, environ=None, overwrite: bool = False) -> tuple[str, ...]:
    """Load an explicit file. Existing nonempty process settings take precedence."""
    target = os.environ if environ is None else environ
    settings = read_server_env(path)
    loaded = []
    for name, value in settings.items():
        if overwrite or not target.get(name):
            target[name] = value
            loaded.append(name)
    return tuple(sorted(loaded))
