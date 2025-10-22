"""Helpers for loading synthetic MCP manifests used by MCP-Check."""

from __future__ import annotations

import json
import tomllib
from hashlib import sha256
from pathlib import Path
from dataclasses import asdict
from typing import Iterable, List, Sequence

from .models import ServerConfig

SUPPORTED_SUFFIXES = {".json", ".toml"}


def discover_manifests(root: Path | str) -> List[Path]:
    """Return a list of manifest files under *root*."""

    root_path = Path(root)
    if not root_path.exists():
        return []
    candidates: List[Path] = []
    for suffix in SUPPORTED_SUFFIXES:
        candidates.extend(root_path.rglob(f"*{suffix}"))
    return sorted({path for path in candidates if path.is_file()})


def load_manifest(path: Path) -> List[ServerConfig]:
    """Load a manifest file into :class:`ServerConfig` objects."""

    if path.suffix.lower() == ".json":
        data = json.loads(path.read_text(encoding="utf-8"))
    elif path.suffix.lower() == ".toml":
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    else:
        raise ValueError(f"Unsupported manifest format: {path}")

    servers: List[ServerConfig] = []
    if isinstance(data, dict):
        if "servers" in data and isinstance(data["servers"], Sequence):
            for entry in data["servers"]:
                servers.append(ServerConfig.from_dict(entry))
        elif "name" in data:
            servers.append(ServerConfig.from_dict(data))
    elif isinstance(data, list):
        for entry in data:
            servers.append(ServerConfig.from_dict(entry))
    else:
        raise ValueError(f"Unexpected manifest structure in {path}")
    return servers


def calculate_fingerprint(paths: Iterable[Path], inline_servers: Iterable[ServerConfig] | None = None) -> str:
    """Compute a deterministic fingerprint for manifest files and inline servers."""

    digest = sha256()
    for path in sorted(paths):
        digest.update(str(path).encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
    if inline_servers:
        for server in sorted(inline_servers, key=lambda item: item.name):
            digest.update(server.name.encode("utf-8"))
            digest.update(b"\0")
            digest.update(json.dumps(asdict(server), sort_keys=True).encode("utf-8"))
    return digest.hexdigest()
