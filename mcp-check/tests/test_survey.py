from __future__ import annotations

from mcp_check.commands import survey
from mcp_check.state import StateStore


def test_survey_discovers_servers(root_path, state_dir):
    result = survey.execute(root_path, state_dir=state_dir, include_defaults=False)
    names = {server.name for server in result.servers}
    assert {"atlas", "echo", "flux"}.issubset(names)
    assert result.fingerprint
    store = StateStore(state_dir)
    latest = survey.latest(store)
    assert latest is not None
    assert latest.fingerprint == result.fingerprint


def test_survey_uses_client_registry(client_registry, state_dir):
    result = survey.execute(None, state_dir=state_dir, client_config=client_registry, include_defaults=False)
    names = {server.name for server in result.servers}
    assert "inline-scout" in names
    assert "atlas" in names  # loaded via manifest reference


def test_survey_env_autodiscovery(monkeypatch, client_registry, state_dir):
    monkeypatch.setenv("MCP_CHECK_CLIENT_PATHS", str(client_registry))
    result = survey.execute(None, state_dir=state_dir)
    names = {server.name for server in result.servers}
    assert "inline-scout" in names
