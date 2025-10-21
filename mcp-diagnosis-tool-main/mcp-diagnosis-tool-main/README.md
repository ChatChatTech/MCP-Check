# MCP Diagnosis Tool

MCP Diagnosis Tool is a browser-based utility for inspecting [Model Context Protocol (MCP)](https://modelcontextprotocol.io/about) servers. It automates the handshake, lists tools/prompts/resources, captures handshake metadata, and provides quick actions for testing tools. You can load full MCP configurations (JSON or Codex-style TOML), merge additional server definitions, and convert between formats.

## Table of contents

- [Features](#features)
- [Quick start](#quick-start)
- [Diagnosing individual servers](#diagnosing-individual-servers)
- [Working with MCP configurations](#working-with-mcp-configurations)
  - [Loading configs (JSON or TOML)](#loading-configs-json-or-toml)
  - [Adding server snippets](#adding-server-snippets)
  - [Saving / converting configs](#saving--converting-configs)
  - [How configs are normalised](#how-configs-are-normalised)
- [Tool testing & reports](#tool-testing--reports)
- [REST API](#rest-api)
- [Implementation overview](#implementation-overview)
- [Disclaimer](#disclaimer)

## Features

- **Connection diagnostics** for stdio, Streamable HTTP, and SSE transports with timeout handling and rich error classification.
- **Capability discovery** showing tools/prompts/resources, handshake metadata, and protocol version.
- **Tool tester** that renders argument schemas, gathers inputs via modal forms, runs the tool, and generates Markdown reports (including timing and output).
- **Config management UI** that loads `mcp.json` or Codex `config.toml`, merges additional snippets, and exports either format—perfect for format conversion workflows.
- **Backend normalisation** ensuring consistent data structures, deterministic merges, and format-preserving exports.

## Quick start

```bash
git clone <repository-url>
cd mcp-diagnosis-tool
npm install
npm start
```

Open `http://localhost:3000` in your browser. To change the port, use `PORT=4000 npm start`.

> **Prerequisites:** Node.js ≥ 18, npm, network access for Streamable HTTP diagnostics, and any MCP servers you want to test.

## Diagnosing individual servers

1. Choose **HTTP** or **STDIO** in the form at the top of the UI.
2. Provide either the MCP URL (HTTP) or the command line to launch your stdio server.
3. Click **Diagnose**. The entry appears in the “Known MCP Servers” list:
   - Amber dot → in progress
   - Green → success with tool/prompt/resource counts
   - Red → error, with expandable details
4. Click the chevron to see:
   - Handshake metadata (transport, protocol version, server info, capabilities, instructions)
   - Tools (with schema summary, “Test” button, last status)
   - Prompts and resources lists
5. For stdio entries, the command is re-displayed with arguments split.

## Working with MCP configurations

### Loading configs (JSON or TOML)

- **Load standard mcp.json:** selects JSON files following the OpenAI MCP client schema (`mcpServers` object).
- **Load mcp.toml:** selects Codex-style TOML configs (`mcp_servers` tables and optional top-level flags).

When you load a config:

- The backend normalises field names (`bearer_token_env_var` → `bearerTokenEnvVar`, etc.).
- The UI re-runs diagnostics for every server entry and displays the results.
- The status label shows file name, format, and server count.
- Save-as buttons are enabled based on source format.

### Adding server snippets

Use the **Add server (JSON)** or **Add server (TOML)** buttons:

- A modal opens with instructions and a textarea.
- Paste a snippet containing either an `mcpServers` object (JSON) or `[mcp_servers.*]` tables (TOML).
- Click **Merge** to send the snippet to the backend.
- The server merges the new definitions into the existing config (overwriting by name), re-diagnoses the full list, and refreshes the UI.

> The modal merges onto whatever configuration is currently loaded. If none is loaded, the snippet becomes the new configuration.

### Saving / converting configs

- **Save as JSON** produces a canonical `mcp.json` with a top-level `mcpServers` object.
- **Save as TOML** converts to Codex-style TOML using nested `[mcp_servers.<name>]` tables.
- Save buttons disable when already in that format to prevent redundant exports.

Conversion is powered by the normalised config representation (`format`, `topLevel`, `servers`), ensuring:

- Top-level keys like `experimental_use_rmcp_client`, `tool_timeout_sec`, etc., are preserved.
- Server entries include consistent keys (`command`, `args`, `env`, `url`, `bearer_token_env_var`, etc.).

### How configs are normalised

Internally, configs are represented as:

```json
{
  "format": "json" | "toml",
  "topLevel": { ... },           // Non-server keys
  "servers": [
    {
      "name": "playwright",
      "mode": "stdio" | "http",
      "command": "...",           // stdio only
      "args": ["..."],            // stdio only
      "env": { "KEY": "VALUE" },
      "url": "...",               // http only
      "bearerTokenEnvVar": "...", // http optional
      "bearerTokenFile": "...",
      "startupTimeoutSec": 15,
      "toolTimeoutSec": 60,
      "enabled": true,
      "extra": {...}              // unrecognised fields retained
    }
  ]
}
```

Serialisers rebuild the exact JSON or TOML schema on export, so you can round-trip without losing metadata.

## Tool testing & reports

- Click **Test** next to a tool to open the tool modal.
- If the server exposed `inputSchema`, the modal renders form fields respecting types, enums, and required flags.
- Submit runs `tools/call` and captures start/end timestamps, duration, transport, and handshake.
- **Download Report** (enabled after a run) generates `MCPDiagnois_Report_<timestamp>_<server>_<tool>.md` with markdown content:
  - Handshake summary
  - Serialized server spec and arguments
  - Tool output or error details

Reports are perfect for audits or sharing diagnostics with teammates.

## REST API

Behind the UI is an Express API you can integrate programmatically:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/diagnose` | POST | Diagnose a single server (`{ mode: "stdio"|"http", command?, args?, url? }`). |
| `/api/config/diagnose` | POST | Normalise and diagnose an MCP config (`configText`, optional `configFormat`). Returns normalized config + per-server results. |
| `/api/config/add-server` | POST | Merge a config snippet into an existing normalized config (`baseConfig`, `additionText`, `additionFormat`). |
| `/api/config/export` | POST | Convert normalized config to JSON or TOML (`targetFormat`). |
| `/api/tools/call` | POST | Invoke `tools/call` on a spec (same payload as `/api/diagnose` plus `toolName`, `toolArgs`). |

Responses follow the same shapes used in the UI. See `server.js` for full request/response details.

## Implementation overview

- **`server.js`** – Express server exposing diagnostic/config endpoints and hosting static assets.
- **`mcpDoctor.js`** – Connects via `@modelcontextprotocol/sdk`, handles timeouts/error classification, normalizes configs, merges additions, and serializes JSON/TOML.
- **`public/`** – Vanilla JS UI with:
  - Config management bar (`public/index.html`, `public/style.css`)
  - Diagnosed server dashboard with expandable cards
  - Tool tester and config merge modals (`public/script.js`)
- **Tests** – `node:test` suite in `test/mcpDoctor.test.js` covering parsing, merging, and diagnostics.

## Version history

### 1.0.1

- Added in-app config management controls: view/edit server config snippets, merge updates via modal, and remove servers from the active configuration without leaving the UI.
- Unified save buttons so JSON and TOML exports are always available, making format conversion a single click regardless of the source format.
- Improved backend support for per-server metadata (snippets, normalized entries) and exposed dedicated endpoints for adding/removing servers.
- Updated the UI to show config-specific controls alongside diagnostics, matching the layout in the screenshot above.

### 1.0.0

- Initial release with core diagnostics (stdio/HTTP/SSE), capability listings, error classification, and the tool testing modal with Markdown report generation.
- Introduced JSON/TOML config loading, normalization, and conversion flows.
- Delivered the dark-themed dashboard for tracking multiple MCP servers in a single session.

## Disclaimer

This utility depends on the stability of MCP server implementations and the `@modelcontextprotocol/sdk`. It’s best-effort and may need adjustments to match server-specific behaviours (timeouts, transports, schema variations). Contributions and issue reports are welcome!  

Happy diagnosing! 🚀
