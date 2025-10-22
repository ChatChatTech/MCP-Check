from __future__ import annotations

from mcp_check.commands import pulse
from mcp_check.state import StateStore


def test_pulse_reports_latency(root_path, state_dir):
    result = pulse.execute(root_path, "atlas", state_dir=state_dir, include_defaults=False)
    assert result.latency_ms == 120
    assert result.status == "ok"

    flux_result = pulse.execute(root_path, "flux", state_dir=state_dir, include_defaults=False)
    assert flux_result.status == "failed"
    assert "timeout" in flux_result.errors

    store = StateStore(state_dir)
    saved = pulse.load_all(store)
    assert len(saved) >= 2
