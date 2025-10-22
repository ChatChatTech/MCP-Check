"""Command line entry point for MCP-Check."""

from __future__ import annotations

import argparse
import json
from dataclasses import is_dataclass
from pathlib import Path
from typing import Any

from .commands import beacon, fortify, ledger, pinpoint, pulse, sentinel, sieve, survey
from .state import _default as serialize_default
from .version import __version__


def _json_dump(obj: Any) -> str:
    payload = serialize_default(obj) if is_dataclass(obj) else obj
    return json.dumps(payload, indent=2, sort_keys=True)


def _print(obj: Any) -> None:
    print(_json_dump(obj))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="MCP-Check security toolkit")
    parser.add_argument("--state-dir", default=None, help="Directory for persisted command output")
    parser.add_argument(
        "--root",
        default=None,
        help="Directory that contains MCP manifests (optional when client registry is provided)",
    )
    parser.add_argument(
        "--client-config",
        default=None,
        help="Path to an MCP-aware client registry file or directory",
    )
    parser.add_argument(
        "--no-default-client-search",
        action="store_true",
        help="Disable automatic lookup of well-known client registries",
    )
    parser.add_argument("--version", action="version", version=f"mcp-check {__version__}")

    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("survey", help="Discover MCP servers and capture a baseline")

    pulse_parser = subparsers.add_parser("pulse", help="Perform handshake diagnostics")
    pulse_parser.add_argument("server", help="Server name to probe")
    pulse_parser.add_argument("--scenario", default="handshake", help="Scenario key to use")

    pinpoint_parser = subparsers.add_parser("pinpoint", help="Run targeted exploit simulations")
    pinpoint_parser.add_argument("server", help="Server name to target")
    pinpoint_parser.add_argument(
        "--scenario",
        action="append",
        dest="scenarios",
        help="Scenario to execute (may be specified multiple times)",
    )

    sieve_parser = subparsers.add_parser("sieve", help="Run static analysis on tools")
    sieve_parser.add_argument("server", help="Server name to analyze")

    sentinel_parser = subparsers.add_parser("sentinel", help="Evaluate runtime telemetry")
    sentinel_parser.add_argument("server", help="Server name to guard")
    sentinel_parser.add_argument("--stream-threshold", type=int, default=500_000, help="Threshold for stream chunks")
    sentinel_parser.add_argument("--rate-limit", type=int, default=200, help="Allowed requests per window")

    subparsers.add_parser("ledger", help="Aggregate stored findings")

    subparsers.add_parser("fortify", help="Produce remediation plan")

    beacon_parser = subparsers.add_parser("beacon", help="Expose discovered servers via a lightweight MCP endpoint")
    beacon_parser.add_argument("--serve", action="store_true", help="Run an HTTP server instead of printing the manifest")
    beacon_parser.add_argument("--host", default="127.0.0.1", help="Host interface for --serve mode")
    beacon_parser.add_argument("--port", type=int, default=0, help="Port for --serve mode (0 selects a free port)")

    return parser


def dispatch(args: argparse.Namespace) -> Any:
    state_dir = args.state_dir
    root = Path(args.root) if args.root is not None else None
    command = args.command
    client_config = args.client_config
    include_defaults = not getattr(args, "no_default_client_search", False)

    if command == "survey":
        return survey.execute(root, state_dir, client_config=client_config, include_defaults=include_defaults)
    if command == "pulse":
        return pulse.execute(
            root,
            args.server,
            scenario=args.scenario,
            state_dir=state_dir,
            client_config=client_config,
            include_defaults=include_defaults,
        )
    if command == "pinpoint":
        return pinpoint.execute(
            root,
            args.server,
            scenarios=args.scenarios,
            state_dir=state_dir,
            client_config=client_config,
            include_defaults=include_defaults,
        )
    if command == "sieve":
        return sieve.execute(
            root,
            args.server,
            state_dir=state_dir,
            client_config=client_config,
            include_defaults=include_defaults,
        )
    if command == "sentinel":
        return sentinel.execute(
            root,
            args.server,
            stream_threshold=args.stream_threshold,
            rate_limit=args.rate_limit,
            state_dir=state_dir,
            client_config=client_config,
            include_defaults=include_defaults,
        )
    if command == "ledger":
        return ledger.execute(state_dir)
    if command == "fortify":
        return fortify.execute(
            root,
            state_dir=state_dir,
            client_config=client_config,
            include_defaults=include_defaults,
        )
    if command == "beacon":
        return beacon.execute(
            root,
            state_dir=state_dir,
            client_config=client_config,
            include_defaults=include_defaults,
            host=args.host,
            port=args.port,
            serve=args.serve,
        )
    raise ValueError(f"Unknown command: {command}")


def main(argv: list[str] | None = None) -> None:
    parser = build_parser()
    args = parser.parse_args(argv)
    result = dispatch(args)
    _print(result)


if __name__ == "__main__":
    main()
