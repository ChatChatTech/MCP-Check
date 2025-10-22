from __future__ import annotations

from mcp_check.commands import sieve
from mcp_check.state import StateStore


def test_sieve_flags_hidden_instructions(root_path, state_dir):
    result = sieve.execute(root_path, "echo", state_dir=state_dir, include_defaults=False)
    assert any(issue.rule == "hidden_instruction" for issue in result.issues)
    assert result.score < 100
    store = StateStore(state_dir)
    saved = sieve.load_all(store)
    assert any(item.server.name == "echo" for item in saved)
