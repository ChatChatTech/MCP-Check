from __future__ import annotations

from mcp_check.commands import fortify, ledger, pinpoint, pulse, sentinel, sieve, survey


SERVERS = ["atlas", "echo", "flux"]


def _run_commands(root_path, state_dir):
    survey.execute(root_path, state_dir=state_dir)
    for server in SERVERS:
        pulse.execute(root_path, server, state_dir=state_dir)
    pinpoint.execute(root_path, "echo", state_dir=state_dir)
    for server in SERVERS:
        sieve.execute(root_path, server, state_dir=state_dir)
    sentinel.execute(root_path, "flux", state_dir=state_dir)


def test_ledger_aggregates_all_results(root_path, state_dir):
    _run_commands(root_path, state_dir)
    report = ledger.execute(state_dir=state_dir)
    assert report.survey is not None
    assert len(report.pulses) >= len(SERVERS)
    assert report.pinpoints
    assert report.sentinels


def test_fortify_generates_actions(root_path, state_dir):
    _run_commands(root_path, state_dir)
    fortify_report = fortify.execute(root_path, state_dir=state_dir)
    assert fortify_report.plans
    echo_plan = next(plan for plan in fortify_report.plans if plan.server.name == "echo")
    assert any(action.category == "runtime" for action in echo_plan.actions)
    flux_plan = next(plan for plan in fortify_report.plans if plan.server.name == "flux")
    assert any("stream" in action.description.lower() for action in flux_plan.actions)
