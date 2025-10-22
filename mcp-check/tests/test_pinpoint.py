from __future__ import annotations

from mcp_check.commands import pinpoint
from mcp_check.state import StateStore


def test_pinpoint_detects_vulnerabilities(root_path, state_dir):
    result = pinpoint.execute(root_path, "echo", state_dir=state_dir, include_defaults=False)
    vulnerable = {item.scenario for item in result.findings if item.outcome == "vulnerable"}
    assert "prompt_injection" in vulnerable
    assert "tool_poisoning" in vulnerable
    store = StateStore(state_dir)
    saved = pinpoint.load_all(store)
    assert any(item.server.name == "echo" for item in saved)
