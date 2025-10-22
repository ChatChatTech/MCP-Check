"""Implementation of the :mod:`mcp-check fortify` command."""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional

from ..models import FortifyAction, FortifyPlan, FortifyReport
from ..state import serialize_fortify
from . import pinpoint, pulse, sentinel, sieve
from .common import build_context


_DEFENCE_ACTIONS = {
    "prompt_injection": "Add guardrails to strip hidden instructions before forwarding to the model.",
    "tool_poisoning": "Quarantine or review the affected tool schema before activation.",
    "rce": "Enforce command allow-list and sandbox execution environment.",
    "stream_overflow": "Apply streamable-http bandwidth cap and chunk throttling.",
}


def _actions_from_pinpoint(findings) -> List[FortifyAction]:
    actions: List[FortifyAction] = []
    for finding in findings:
        if finding.outcome != "vulnerable":
            continue
        description = _DEFENCE_ACTIONS.get(finding.scenario, "Review and patch detected vulnerability.")
        actions.append(
            FortifyAction(
                category="runtime",
                description=description,
                target=finding.scenario,
                value=finding.payload,
            )
        )
    return actions


def _actions_from_sieve(issues) -> List[FortifyAction]:
    actions: List[FortifyAction] = []
    for issue in issues:
        description = f"Mitigate rule '{issue.rule}' for tool {issue.tool or 'unknown'}."
        actions.append(
            FortifyAction(
                category="static",
                description=description,
                target=issue.tool or issue.rule,
                value={"rule": issue.rule, "severity": issue.severity},
            )
        )
    return actions


def _actions_from_pulse(pulses_for_server) -> List[FortifyAction]:
    actions: List[FortifyAction] = []
    for result in pulses_for_server:
        if result.status != "ok":
            actions.append(
                FortifyAction(
                    category="transport",
                    description="Configure retries and authentication for unstable handshake.",
                    target=result.server.name,
                    value={"status": result.status, "errors": result.errors},
                )
            )
    return actions


def _actions_from_sentinel(alerts) -> List[FortifyAction]:
    actions: List[FortifyAction] = []
    for alert in alerts:
        advice = _DEFENCE_ACTIONS.get(alert.event, "Apply stricter runtime policy.")
        actions.append(
            FortifyAction(
                category="runtime",
                description=advice,
                target=alert.event,
                value=alert.detail,
            )
        )
    return actions


def execute(
    root: str | Path,
    *,
    state_dir: Optional[str | Path] = None,
) -> FortifyReport:
    """Generate remediation plans using accumulated command results."""

    context = build_context(root, state_dir)
    state = context.state
    pulse_results = pulse.load_all(state)
    pinpoint_results = pinpoint.load_all(state)
    sieve_results = sieve.load_all(state)
    sentinel_results = sentinel.load_all(state)

    pulses_by_server: Dict[str, List] = {}
    for item in pulse_results:
        pulses_by_server.setdefault(item.server.name, []).append(item)

    pinpoint_by_server: Dict[str, List] = {item.server.name: item.findings for item in pinpoint_results}
    sieve_by_server: Dict[str, List] = {item.server.name: item.issues for item in sieve_results}
    sentinel_by_server: Dict[str, List] = {item.server.name: item.alerts for item in sentinel_results}

    plans: List[FortifyPlan] = []
    for server in context.servers:
        actions: List[FortifyAction] = []
        actions.extend(_actions_from_pulse(pulses_by_server.get(server.name, [])))
        actions.extend(_actions_from_pinpoint(pinpoint_by_server.get(server.name, [])))
        actions.extend(_actions_from_sieve(sieve_by_server.get(server.name, [])))
        actions.extend(_actions_from_sentinel(sentinel_by_server.get(server.name, [])))
        if server.risks.resource_exhaustion:
            actions.append(
                FortifyAction(
                    category="runtime",
                    description="Introduce stream rate limiter for streamable-http endpoints.",
                    target=server.name,
                    value={"stream_limit": 250_000},
                )
            )
        plans.append(FortifyPlan(server=server, actions=actions))

    report = FortifyReport(generated_at=datetime.now(timezone.utc), plans=plans)
    state.write_record("fortify", serialize_fortify(report))
    return report
