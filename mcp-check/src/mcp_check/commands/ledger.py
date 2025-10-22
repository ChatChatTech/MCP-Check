"""Implementation of the :mod:`mcp-check ledger` command."""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from ..models import LedgerReport
from ..state import StateStore, serialize_ledger
from . import pulse, pinpoint, sentinel, sieve, survey


def execute(state_dir: Optional[str | Path] = None) -> LedgerReport:
    """Aggregate the latest data from previous commands."""

    state = StateStore(state_dir)
    report = LedgerReport(
        generated_at=datetime.now(timezone.utc),
        survey=survey.latest(state),
        pulses=pulse.load_all(state),
        pinpoints=pinpoint.load_all(state),
        sieves=sieve.load_all(state),
        sentinels=sentinel.load_all(state),
    )
    state.write_record("ledger", serialize_ledger(report))
    return report
