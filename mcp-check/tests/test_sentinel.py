from __future__ import annotations

from mcp_check.commands import sentinel
from mcp_check.state import StateStore


def test_sentinel_detects_resource_exhaustion(root_path, state_dir):
    result = sentinel.execute(root_path, "flux", state_dir=state_dir, stream_threshold=500_000, rate_limit=200)
    alert_events = {event.event for event in result.alerts}
    assert "stream_overflow" in alert_events
    assert "rate_limit" in alert_events
    store = StateStore(state_dir)
    saved = sentinel.load_all(store)
    assert any(item.server.name == "flux" for item in saved)
