"""Implementation of the :mod:`mcp-check survey` command."""

from __future__ import annotations

from pathlib import Path
from typing import Optional

from ..models import SurveyResult
from ..state import StateStore, serialize_survey
from .common import build_context, make_survey_result


def execute(
    root: str | Path | None,
    state_dir: Optional[str | Path] = None,
    *,
    client_config: Optional[str | Path] = None,
    include_defaults: bool = True,
) -> SurveyResult:
    """Discover MCP servers from manifests or client registries and persist a snapshot."""

    context = build_context(
        root,
        state_dir,
        client_config=client_config,
        include_defaults=include_defaults,
    )
    survey = make_survey_result(context)
    payload = serialize_survey(survey)
    context.state.write_record("survey", payload)
    return survey


def latest(state: StateStore) -> Optional[SurveyResult]:
    """Return the most recent survey entry from *state*."""

    from datetime import datetime
    from ..models import ServerConfig

    record = state.latest_record("survey")
    if record is None:
        return None
    _, data = record
    servers = [ServerConfig.from_dict(item) for item in data.get("servers", [])]
    generated_at = datetime.fromisoformat(data["generated_at"])
    source_paths = [Path(path) for path in data.get("source_paths", [])]
    return SurveyResult(
        servers=servers,
        fingerprint=data.get("fingerprint", ""),
        generated_at=generated_at,
        source_paths=source_paths,
    )
