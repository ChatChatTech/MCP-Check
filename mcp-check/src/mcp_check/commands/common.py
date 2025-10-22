"""Shared helpers for command implementations."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, List, Optional

from ..loader import calculate_fingerprint, discover_manifests, load_manifest
from ..models import ServerConfig, SurveyResult
from ..state import StateStore


@dataclass(slots=True)
class CommandContext:
    """Execution context shared by all commands."""

    manifests: List[Path]
    servers: List[ServerConfig]
    state: StateStore


def build_state(state_dir: Optional[str | Path]) -> StateStore:
    return StateStore(state_dir)


def resolve_manifests(root: Path | str) -> List[Path]:
    manifests = discover_manifests(root)
    if not manifests:
        raise FileNotFoundError(f"No manifests found under {root}")
    return manifests


def load_servers(paths: Iterable[Path]) -> List[ServerConfig]:
    servers: List[ServerConfig] = []
    for path in paths:
        servers.extend(load_manifest(path))
    return servers


def build_context(root: Path | str, state_dir: Optional[str | Path] = None) -> CommandContext:
    manifests = resolve_manifests(root)
    servers = load_servers(manifests)
    state = build_state(state_dir)
    return CommandContext(manifests=manifests, servers=servers, state=state)


def make_survey_result(context: CommandContext) -> SurveyResult:
    fingerprint = calculate_fingerprint(context.manifests)
    return SurveyResult(
        servers=context.servers,
        fingerprint=fingerprint,
        generated_at=datetime.now(timezone.utc),
        source_paths=context.manifests,
    )


def find_server(context: CommandContext, name: str) -> ServerConfig:
    for server in context.servers:
        if server.name == name:
            return server
    raise KeyError(f"Unknown server: {name}")
