"""Expose discovered MCP servers as a lightweight MCP-compatible beacon."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, Optional

from ..state import serialize_survey
from .common import build_context, make_survey_result


class _BeaconHandler(BaseHTTPRequestHandler):
    manifest: Dict[str, object] = {}

    def do_GET(self) -> None:  # noqa: N802 (method name required by BaseHTTPRequestHandler)
        if self.path in {"/", "/manifest"}:
            payload = json.dumps(self.manifest).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_error(404, "Not Found")

    def log_message(self, format: str, *args) -> None:  # noqa: A003 - consistent with stdlib signature
        # Silence default logging to keep CLI output clean.
        return


def _serve_http(host: str, port: int, manifest: Dict[str, object]) -> Dict[str, object]:
    _BeaconHandler.manifest = manifest
    with ThreadingHTTPServer((host, port), _BeaconHandler) as server:
        actual_port = server.server_address[1]
        try:
            server.serve_forever()
        except KeyboardInterrupt:  # pragma: no cover - manual shutdown path
            pass
    return {"host": host, "port": actual_port}


def execute(
    root: str | Path | None,
    *,
    state_dir: Optional[str | Path] = None,
    client_config: Optional[str | Path] = None,
    include_defaults: bool = True,
    host: Optional[str] = None,
    port: int = 0,
    serve: bool = False,
) -> Dict[str, object]:
    """Aggregate discovered servers and optionally expose them over HTTP."""

    context = build_context(
        root,
        state_dir,
        client_config=client_config,
        include_defaults=include_defaults,
    )
    survey = make_survey_result(context)
    manifest = serialize_survey(survey)
    manifest["generated_at"] = datetime.now(timezone.utc).isoformat()

    # Persist the manifest for later introspection.
    context.state.write_record("beacon", manifest)

    if serve and host:
        return _serve_http(host, port, manifest)
    return manifest
