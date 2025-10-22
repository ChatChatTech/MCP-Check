"""Shared helpers for command implementations."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, List, Optional

from ..discovery import DiscoveryResult, discover_environment
from ..loader import calculate_fingerprint, load_manifest
from ..models import ServerConfig, SurveyResult
from ..state import StateStore


@dataclass(slots=True)
class CommandContext:
    """Execution context shared by all commands."""

    manifests: List[Path]
    inline_servers: List[ServerConfig]
    source_paths: List[Path]
    servers: List[ServerConfig]
    state: StateStore


def build_state(state_dir: Optional[str | Path]) -> StateStore:
    return StateStore(state_dir)


def load_servers(paths: Iterable[Path]) -> List[ServerConfig]:
    servers: List[ServerConfig] = []
    for path in paths:
        servers.extend(load_manifest(path))
    return servers


def merge_servers(primary: Iterable[ServerConfig], secondary: Iterable[ServerConfig]) -> List[ServerConfig]:
    merged: dict[str, ServerConfig] = {}
    for server in primary:
        merged[server.name] = server
    for server in secondary:
        merged[server.name] = server
    return list(merged.values())


def build_context(
    root: Path | str | None,
    state_dir: Optional[str | Path] = None,
    *,
    client_config: Optional[str | Path] = None,
    include_defaults: bool = True,
) -> CommandContext:
    discovery: DiscoveryResult = discover_environment(
        root=root,
        client_config=client_config,
        include_defaults=include_defaults,
    )
    manifests = discovery.manifest_paths
    inline_servers = discovery.inline_servers
    servers = merge_servers(load_servers(manifests), inline_servers)
    if not servers:
        raise FileNotFoundError("No MCP servers discovered")
    state = build_state(state_dir)
    source_paths = discovery.source_paths or manifests
    return CommandContext(
        manifests=manifests,
        inline_servers=inline_servers,
        source_paths=source_paths,
        servers=servers,
        state=state,
    )


def make_survey_result(context: CommandContext) -> SurveyResult:
    fingerprint = calculate_fingerprint(context.source_paths or context.manifests, context.inline_servers)
    return SurveyResult(
        servers=context.servers,
        fingerprint=fingerprint,
        generated_at=datetime.now(timezone.utc),
        source_paths=context.source_paths or context.manifests,
    )


def find_server(context: CommandContext, name: str) -> ServerConfig:
    for server in context.servers:
        if server.name == name:
            return server
    raise KeyError(f"Unknown server: {name}")
