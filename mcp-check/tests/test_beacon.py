from mcp_check.commands import beacon


def test_beacon_returns_manifest(root_path, state_dir):
    result = beacon.execute(root_path, state_dir=state_dir, include_defaults=False)
    assert "servers" in result
    assert any(server["name"] == "flux" for server in result["servers"])


def test_beacon_uses_client_registry(client_registry, state_dir):
    result = beacon.execute(None, state_dir=state_dir, client_config=client_registry, include_defaults=False)
    names = {server["name"] for server in result["servers"]}
    assert "inline-scout" in names
