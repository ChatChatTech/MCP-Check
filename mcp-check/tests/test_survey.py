from __future__ import annotations

from mcp_check.commands import survey
from mcp_check.state import StateStore


def test_survey_discovers_servers(root_path, state_dir):
    result = survey.execute(root_path, state_dir=state_dir)
    assert len(result.servers) == 3
    assert result.fingerprint
    store = StateStore(state_dir)
    latest = survey.latest(store)
    assert latest is not None
    assert latest.fingerprint == result.fingerprint
