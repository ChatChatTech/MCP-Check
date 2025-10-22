"""Implementation of the :mod:`mcp-check sieve` command."""

from __future__ import annotations

import re
from pathlib import Path
from typing import List, Optional

from ..models import SieveIssue, SieveResult
from ..state import StateStore, serialize_sieve
from .common import build_context, find_server

_PATTERNS = {
    "hidden_instruction": re.compile(r"ignore\s+all\s+previous\s+instructions", re.IGNORECASE),
    "exfiltration": re.compile(r"(upload|exfiltrate|send)\s+(file|data)", re.IGNORECASE),
    "sensitive_access": re.compile(r"/(etc|var|home)/", re.IGNORECASE),
    "cross_origin": re.compile(r"https?://[^\s]+", re.IGNORECASE),
}

_SEVERITY = {
    "hidden_instruction": "high",
    "exfiltration": "high",
    "sensitive_access": "medium",
    "cross_origin": "medium",
}


def _inspect_tool(tool) -> List[SieveIssue]:
    issues: List[SieveIssue] = []
    text = f"{tool.description} {tool.input_schema}".lower()
    for key, pattern in _PATTERNS.items():
        if pattern.search(text):
            issues.append(
                SieveIssue(
                    rule=key,
                    description=f"Pattern '{key}' detected in tool description",
                    severity=_SEVERITY.get(key, "low"),
                    tool=tool.name,
                )
            )
    return issues


def execute(
    root: str | Path | None,
    server_name: str,
    *,
    state_dir: Optional[str | Path] = None,
    client_config: Optional[str | Path] = None,
    include_defaults: bool = True,
) -> SieveResult:
    """Run static analysis heuristics against discovered server tools."""

    context = build_context(
        root,
        state_dir,
        client_config=client_config,
        include_defaults=include_defaults,
    )
    server = find_server(context, server_name)
    issues: List[SieveIssue] = []
    for tool in server.tools:
        issues.extend(_inspect_tool(tool))
    score = max(0, 100 - 15 * len(issues))
    result = SieveResult(server=server, issues=issues, score=score)
    context.state.write_record("sieve", serialize_sieve(result))
    return result


def load_all(state: StateStore) -> List[SieveResult]:
    from ..models import ServerConfig

    records = list(state.iter_records("sieve"))
    results: List[SieveResult] = []
    for _, data in records:
        server_obj = ServerConfig.from_dict(data["server"])
        issues = [
            SieveIssue(
                rule=item.get("rule", "unknown"),
                description=item.get("description", ""),
                severity=item.get("severity", "low"),
                tool=item.get("tool"),
            )
            for item in data.get("issues", [])
        ]
        results.append(SieveResult(server=server_obj, issues=issues, score=int(data.get("score", 0))))
    return results
