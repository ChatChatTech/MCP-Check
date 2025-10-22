"""Shared data models for MCP-Check."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional


class Transport(str, Enum):
    """Supported MCP transport types."""

    STDIO = "stdio"
    HTTP = "http"
    SSE = "sse"
    STREAMABLE_HTTP = "streamable-http"


@dataclass(slots=True)
class ToolDefinition:
    """Simplified representation of an MCP tool."""

    name: str
    description: str
    input_schema: Dict[str, Any] = field(default_factory=dict)


@dataclass(slots=True)
class ServerScenario:
    """Synthetic scenario definitions used by the tests and commands."""

    handshake_latency_ms: int
    handshake_errors: List[str] = field(default_factory=list)
    capabilities: Dict[str, Any] = field(default_factory=dict)
    instructions: Optional[str] = None


@dataclass(slots=True)
class RuntimeEvent:
    """A single runtime observation captured by the sentinel."""

    event: str
    detail: Dict[str, Any] = field(default_factory=dict)
    severity: str = "info"


@dataclass(slots=True)
class RiskVector:
    """Flag set describing simulated vulnerabilities for a server."""

    prompt_injection: bool = False
    tool_poisoning: bool = False
    cross_origin: bool = False
    sensitive_access: bool = False
    rce: bool = False
    resource_exhaustion: bool = False


@dataclass(slots=True)
class ServerConfig:
    """In-memory representation of a server manifest."""

    name: str
    transport: Transport
    endpoint: str
    tools: List[ToolDefinition] = field(default_factory=list)
    scenarios: Dict[str, ServerScenario] = field(default_factory=dict)
    runtime_profile: List[RuntimeEvent] = field(default_factory=list)
    risks: RiskVector = field(default_factory=RiskVector)
    metadata: Dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "ServerConfig":
        transport = Transport(data.get("transport", "stdio"))
        tools = [
            ToolDefinition(
                name=item["name"],
                description=item.get("description", ""),
                input_schema=item.get("input_schema", {}),
            )
            for item in data.get("tools", [])
        ]
        scenarios = {
            key: ServerScenario(
                handshake_latency_ms=value.get("handshake_latency_ms", 0),
                handshake_errors=list(value.get("handshake_errors", [])),
                capabilities=value.get("capabilities", {}),
                instructions=value.get("instructions"),
            )
            for key, value in data.get("scenarios", {}).items()
        }
        runtime_profile = [
            RuntimeEvent(
                event=item.get("event", "unknown"),
                detail=dict(item.get("detail", {})),
                severity=item.get("severity", "info"),
            )
            for item in data.get("runtime_profile", [])
        ]
        risk_data = data.get("risks", {})
        risks = RiskVector(
            prompt_injection=bool(risk_data.get("prompt_injection", False)),
            tool_poisoning=bool(risk_data.get("tool_poisoning", False)),
            cross_origin=bool(risk_data.get("cross_origin", False)),
            sensitive_access=bool(risk_data.get("sensitive_access", False)),
            rce=bool(risk_data.get("rce", False)),
            resource_exhaustion=bool(risk_data.get("resource_exhaustion", False)),
        )
        return cls(
            name=data["name"],
            transport=transport,
            endpoint=data.get("endpoint", ""),
            tools=tools,
            scenarios=scenarios,
            runtime_profile=runtime_profile,
            risks=risks,
            metadata={key: value for key, value in data.items() if key not in {
                "name",
                "transport",
                "endpoint",
                "tools",
                "scenarios",
                "runtime_profile",
                "risks",
            }},
        )


@dataclass(slots=True)
class SurveyResult:
    """Structured output for the survey command."""

    servers: List[ServerConfig]
    fingerprint: str
    generated_at: datetime
    source_paths: List[Path]


@dataclass(slots=True)
class PulseResult:
    """Handshake assessment result."""

    server: ServerConfig
    latency_ms: int
    transport_used: Transport
    status: str
    errors: List[str] = field(default_factory=list)


@dataclass(slots=True)
class PinpointScenario:
    """Result for a pinpoint test."""

    scenario: str
    payload: Dict[str, Any]
    outcome: str
    evidence: Dict[str, Any]
    severity: str


@dataclass(slots=True)
class PinpointResult:
    server: ServerConfig
    findings: List[PinpointScenario]


@dataclass(slots=True)
class SieveIssue:
    rule: str
    description: str
    severity: str
    tool: Optional[str] = None


@dataclass(slots=True)
class SieveResult:
    server: ServerConfig
    issues: List[SieveIssue]
    score: int


@dataclass(slots=True)
class SentinelResult:
    server: ServerConfig
    events: List[RuntimeEvent]
    alerts: List[RuntimeEvent]


@dataclass(slots=True)
class LedgerReport:
    generated_at: datetime
    survey: Optional[SurveyResult]
    pulses: List[PulseResult]
    pinpoints: List[PinpointResult]
    sieves: List[SieveResult]
    sentinels: List[SentinelResult]


@dataclass(slots=True)
class FortifyAction:
    """Single recommended remediation action."""

    category: str
    description: str
    target: str
    value: Any


@dataclass(slots=True)
class FortifyPlan:
    server: ServerConfig
    actions: List[FortifyAction]


@dataclass(slots=True)
class FortifyReport:
    generated_at: datetime
    plans: List[FortifyPlan]


def summarize_tools(tools: Iterable[ToolDefinition]) -> List[str]:
    """Return a compact list of tool identifiers for serialization."""

    return [f"{tool.name}:{tool.description[:40]}" for tool in tools]
