"""Implementation of the :mod:`mcp-check sentinel` command."""

from __future__ import annotations

from pathlib import Path
from typing import List, Optional

from ..models import RuntimeEvent, SentinelResult
from ..state import StateStore, serialize_sentinel
from .common import build_context, find_server


def _detect_alerts(events: List[RuntimeEvent], stream_threshold: int, rate_limit: int) -> List[RuntimeEvent]:
    alerts: List[RuntimeEvent] = []
    for event in events:
        if event.event == "tool_call" and not event.detail.get("approved", True):
            alerts.append(RuntimeEvent(event="tool_call_blocked", detail=event.detail, severity="high"))
        if event.event == "command_exec" and event.detail.get("command"):
            alerts.append(RuntimeEvent(event="command_exec", detail=event.detail, severity="critical"))
        if event.event == "stream_chunk":
            size = int(event.detail.get("bytes", 0))
            if size > stream_threshold:
                alerts.append(RuntimeEvent(event="stream_overflow", detail={"bytes": size}, severity="high"))
        if event.event == "request_rate":
            count = int(event.detail.get("count", 0))
            if count > rate_limit:
                alerts.append(RuntimeEvent(event="rate_limit", detail={"count": count}, severity="medium"))
    return alerts


def execute(
    root: str | Path,
    server_name: str,
    *,
    stream_threshold: int = 500_000,
    rate_limit: int = 200,
    state_dir: Optional[str | Path] = None,
) -> SentinelResult:
    """Evaluate runtime events for anomalies."""

    context = build_context(root, state_dir)
    server = find_server(context, server_name)
    events = list(server.runtime_profile)
    alerts = _detect_alerts(events, stream_threshold, rate_limit)
    result = SentinelResult(server=server, events=events, alerts=alerts)
    context.state.write_record("sentinel", serialize_sentinel(result))
    return result


def load_all(state: StateStore) -> List[SentinelResult]:
    from ..models import ServerConfig

    records = list(state.iter_records("sentinel"))
    results: List[SentinelResult] = []
    for _, data in records:
        server_obj = ServerConfig.from_dict(data["server"])
        events = [
            RuntimeEvent(
                event=item.get("event", "unknown"),
                detail=item.get("detail", {}),
                severity=item.get("severity", "info"),
            )
            for item in data.get("events", [])
        ]
        alerts = [
            RuntimeEvent(
                event=item.get("event", "unknown"),
                detail=item.get("detail", {}),
                severity=item.get("severity", "info"),
            )
            for item in data.get("alerts", [])
        ]
        results.append(SentinelResult(server=server_obj, events=events, alerts=alerts))
    return results
