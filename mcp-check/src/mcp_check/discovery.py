"""Client configuration discovery helpers for MCP-Check."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Sequence, Tuple

import tomllib

from .loader import SUPPORTED_SUFFIXES, discover_manifests
from .models import ServerConfig

# Common relative locations where MCP-capable clients persist server registries.
_KNOWN_RELATIVE_PATHS = [
    Path(".config") / "claude" / "mcp.json",
    Path(".config") / "anthropic" / "mcp" / "servers.json",
    Path("Library") / "Application Support" / "Cursor" / "mcp" / "servers.json",
    Path("AppData") / "Roaming" / "Anthropic" / "mcp" / "servers.json",
]


@dataclass(slots=True)
class DiscoveryResult:
    """Aggregated discovery output."""

    manifest_paths: List[Path]
    inline_servers: List[ServerConfig]
    source_paths: List[Path]


def _load_structured_file(path: Path) -> object:
    text = path.read_text(encoding="utf-8")
    try:
        if path.suffix.lower() == ".toml":
            return tomllib.loads(text)
        return json.loads(text)
    except Exception as exc:  # pragma: no cover - defensive; surfaced in tests
        raise ValueError(f"Failed to parse client config {path}: {exc}") from exc


def _resolve_relative(base: Path, entry: str) -> Path:
    candidate = Path(entry)
    if not candidate.is_absolute():
        candidate = (base / candidate).resolve()
    return candidate


def _parse_server_entry(base: Path, entry: object) -> Tuple[List[Path], List[ServerConfig]]:
    manifests: List[Path] = []
    inline: List[ServerConfig] = []
    if isinstance(entry, str):
        manifests.append(_resolve_relative(base, entry))
        return manifests, inline
    if isinstance(entry, dict):
        manifest_ref = entry.get("manifest") or entry.get("path")
        if isinstance(manifest_ref, str):
            manifests.append(_resolve_relative(base, manifest_ref))
        definition = entry.get("definition")
        if isinstance(definition, dict):
            inline.append(ServerConfig.from_dict(definition))
            return manifests, inline
        # Treat the dictionary itself as a definition if it contains a name.
        if "name" in entry:
            cleaned = {key: value for key, value in entry.items() if key not in {"manifest", "path"}}
            inline.append(ServerConfig.from_dict(cleaned))
        return manifests, inline
    return manifests, inline


def _parse_client_payload(base: Path, data: object) -> Tuple[List[Path], List[ServerConfig]]:
    manifests: List[Path] = []
    inline: List[ServerConfig] = []
    if isinstance(data, dict):
        for key in ("manifests", "manifest_paths", "paths"):
            value = data.get(key)
            if isinstance(value, Sequence) and not isinstance(value, (str, bytes)):
                for item in value:
                    if isinstance(item, str):
                        manifests.append(_resolve_relative(base, item))
        for key in ("servers", "installed", "installs"):
            value = data.get(key)
            if isinstance(value, Sequence) and not isinstance(value, (str, bytes)):
                for item in value:
                    m, s = _parse_server_entry(base, item)
                    manifests.extend(m)
                    inline.extend(s)
        return manifests, inline
    if isinstance(data, Sequence) and not isinstance(data, (str, bytes)):
        for item in data:
            m, s = _parse_server_entry(base, item)
            manifests.extend(m)
            inline.extend(s)
    return manifests, inline


def load_client_config(path: Path) -> DiscoveryResult:
    """Parse a client registry file or directory and return discovered servers."""

    manifest_paths: List[Path] = []
    inline_servers: List[ServerConfig] = []
    source_paths: List[Path] = []

    path = path.expanduser().resolve()
    if not path.exists():
        return DiscoveryResult(manifest_paths=[], inline_servers=[], source_paths=[])

    if path.is_dir():
        for suffix in SUPPORTED_SUFFIXES:
            for candidate in path.glob(f"**/*{suffix}"):
                nested = load_client_config(candidate)
                manifest_paths.extend(nested.manifest_paths)
                inline_servers.extend(nested.inline_servers)
                source_paths.extend(nested.source_paths)
        return DiscoveryResult(
            manifest_paths=_dedupe_paths(manifest_paths),
            inline_servers=inline_servers,
            source_paths=_dedupe_paths(source_paths),
        )

    data = _load_structured_file(path)
    manifests, inline = _parse_client_payload(path.parent, data)
    manifest_paths.extend(manifests)
    inline_servers.extend(inline)
    source_paths.append(path)
    return DiscoveryResult(
        manifest_paths=_dedupe_paths(manifest_paths),
        inline_servers=inline_servers,
        source_paths=_dedupe_paths(source_paths),
    )


def _dedupe_paths(paths: Iterable[Path]) -> List[Path]:
    seen: set[Path] = set()
    ordered: List[Path] = []
    for path in paths:
        resolved = path.expanduser().resolve()
        if resolved not in seen and resolved.exists():
            seen.add(resolved)
            ordered.append(resolved)
    return ordered


def default_client_configs() -> List[Path]:
    """Return existing registry candidates from environment and common paths."""

    env_override = os.environ.get("MCP_CHECK_CLIENT_PATHS")
    candidates: List[Path] = []
    if env_override:
        for raw in env_override.split(os.pathsep):
            if raw:
                candidates.append(Path(raw).expanduser())
    else:
        env_home = os.environ.get("MCP_CHECK_CLIENT_HOME")
        home = Path(env_home).expanduser() if env_home else Path.home()
        for relative in _KNOWN_RELATIVE_PATHS:
            candidate = (home / relative).expanduser().resolve()
            if candidate.exists():
                candidates.append(candidate)
    return _dedupe_paths(candidates)


def discover_environment(
    *,
    root: Path | str | None,
    client_config: Path | str | None,
    include_defaults: bool,
) -> DiscoveryResult:
    """Combine manifest discovery from explicit roots and client registries."""

    manifest_paths: List[Path] = []
    inline_servers: List[ServerConfig] = []
    source_paths: List[Path] = []

    if root is not None:
        manifests = discover_manifests(root)
        manifest_paths.extend(manifests)
        source_paths.extend(manifests)

    if client_config is not None:
        registry = load_client_config(Path(client_config))
        manifest_paths.extend(registry.manifest_paths)
        inline_servers.extend(registry.inline_servers)
        source_paths.extend(registry.source_paths)

    if include_defaults:
        for candidate in default_client_configs():
            registry = load_client_config(candidate)
            manifest_paths.extend(registry.manifest_paths)
            inline_servers.extend(registry.inline_servers)
            source_paths.extend(registry.source_paths)

    return DiscoveryResult(
        manifest_paths=_dedupe_paths(manifest_paths),
        inline_servers=inline_servers,
        source_paths=_dedupe_paths(source_paths),
    )
