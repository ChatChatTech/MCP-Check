"""State management utilities for MCP-Check commands."""

from __future__ import annotations

import json
from dataclasses import asdict, is_dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, Iterator, Optional, Tuple

from .models import (
    FortifyPlan,
    FortifyReport,
    LedgerReport,
    PinpointResult,
    PulseResult,
    SentinelResult,
    ServerConfig,
    SurveyResult,
    SieveResult,
)


def _default(obj: Any) -> Any:
    """JSON serializer for dataclasses, enums and datetimes."""

    if isinstance(obj, datetime):
        return obj.astimezone(timezone.utc).isoformat()
    if hasattr(obj, "value") and not isinstance(obj, (str, bytes)):
        value = getattr(obj, "value", None)
        if isinstance(value, str):
            return value
    if isinstance(obj, Path):
        return str(obj)
    if is_dataclass(obj):
        return {
            key: _default(value)
            for key, value in asdict(obj).items()
        }
    if isinstance(obj, dict):
        return {key: _default(value) for key, value in obj.items()}
    if isinstance(obj, (list, tuple, set)):
        return [_default(value) for value in obj]
    return obj


class StateStore:
    """Simple JSON file based storage for command outputs."""

    def __init__(self, root: Optional[Path | str] = None) -> None:
        base = Path(root) if root is not None else Path.home() / ".mcp-check"
        self.root = base.expanduser().resolve()
        self.root.mkdir(parents=True, exist_ok=True)

    def _timestamp(self) -> str:
        return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")

    def _command_dir(self, namespace: str) -> Path:
        path = self.root / namespace
        path.mkdir(parents=True, exist_ok=True)
        return path

    def write_record(self, namespace: str, payload: Dict[str, Any]) -> Path:
        """Persist a JSON payload under *namespace*."""

        command_dir = self._command_dir(namespace)
        timestamp = self._timestamp()
        file_path = command_dir / f"{timestamp}.json"
        file_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
        return file_path

    def write_dataclass(self, namespace: str, obj: Any) -> Path:
        """Serialize a dataclass oriented object graph into the store."""

        payload = _default(obj)
        if not isinstance(payload, dict):
            payload = {"value": payload}
        return self.write_record(namespace, payload)  # type: ignore[arg-type]

    def latest_record(self, namespace: str) -> Optional[Tuple[Path, Dict[str, Any]]]:
        command_dir = self._command_dir(namespace)
        files = sorted(command_dir.glob("*.json"))
        if not files:
            return None
        latest = files[-1]
        return latest, json.loads(latest.read_text(encoding="utf-8"))

    def iter_records(self, namespace: str) -> Iterator[Tuple[Path, Dict[str, Any]]]:
        command_dir = self._command_dir(namespace)
        for path in sorted(command_dir.glob("*.json")):
            yield path, json.loads(path.read_text(encoding="utf-8"))


def serialize_survey(result: SurveyResult) -> Dict[str, Any]:
    return _default(result)


def serialize_pulse(result: PulseResult) -> Dict[str, Any]:
    return _default(result)


def serialize_pinpoint(result: PinpointResult) -> Dict[str, Any]:
    return _default(result)


def serialize_sieve(result: SieveResult) -> Dict[str, Any]:
    return _default(result)


def serialize_sentinel(result: SentinelResult) -> Dict[str, Any]:
    return _default(result)


def serialize_ledger(report: LedgerReport) -> Dict[str, Any]:
    return _default(report)


def serialize_fortify(report: FortifyReport) -> Dict[str, Any]:
    return _default(report)
