"""Implementation of the :mod:`mcp-check pulse` command."""

from __future__ import annotations

from pathlib import Path
from typing import List, Optional

from ..models import PulseResult, Transport
from ..state import StateStore, serialize_pulse
from .common import build_context, find_server


def execute(
    root: str | Path | None,
    server_name: str,
    *,
    scenario: str = "handshake",
    state_dir: Optional[str | Path] = None,
    client_config: Optional[str | Path] = None,
    include_defaults: bool = True,
) -> PulseResult:
    """Simulate a handshake for *server_name* using discovered manifests or registries."""

    context = build_context(
        root,
        state_dir,
        client_config=client_config,
        include_defaults=include_defaults,
    )
    server = find_server(context, server_name)
    profile = server.scenarios.get(scenario)
    latency = profile.handshake_latency_ms if profile else 0
    errors: List[str] = list(profile.handshake_errors) if profile else []
    status = "ok"
    if errors:
        status = "failed" if any(err for err in errors if err != "warning") else "degraded"
    result = PulseResult(
        server=server,
        latency_ms=latency,
        transport_used=server.transport,
        status=status,
        errors=errors,
    )
    context.state.write_record("pulse", serialize_pulse(result))
    return result


def load_all(state: StateStore) -> List[PulseResult]:
    """Load all pulse entries from *state*."""

    records = list(state.iter_records("pulse"))
    results: List[PulseResult] = []
    from ..models import ServerConfig

    for _, data in records:
        server_obj = ServerConfig.from_dict(data["server"])
        transport_value = data.get("transport_used", server_obj.transport.value)
        results.append(
            PulseResult(
                server=server_obj,
                latency_ms=int(data.get("latency_ms", 0)),
                transport_used=Transport(transport_value),
                status=data.get("status", "unknown"),
                errors=list(data.get("errors", [])),
            )
        )
    return results
