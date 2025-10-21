/*
 * server.js
 *
 * This file starts a small Express server that exposes a single API endpoint
 * for diagnosing MCP servers and serves a static front‑end for interacting
 * with the diagnostic logic. The API delegates the heavy lifting to the
 * mcpDoctor module which uses the MCP client SDK to negotiate the
 * initialize/initialized handshake and list available tools/prompts/resources.
 */

const express = require('express');
const cors = require('cors');
const path = require('path');

const {
  diagnose,
  parseMcpConfigContent,
  diagnoseConfigEntries,
  mergeNormalizedConfig,
  removeServerFromConfig,
  serializeMcpConfigToJson,
  serializeMcpConfigToToml,
  serializeServerSnippet,
  callTool
} = require('./mcpDoctor');

const app = express();
const PORT = process.env.PORT || 3000;

// Enable JSON body parsing
app.use(express.json());
// Allow cross‑origin requests in case the UI is served from a different host
app.use(cors());

// API route for diagnosing servers
app.post('/api/diagnose', async (req, res) => {
  const { mode, url, command, args } = req.body || {};
  if (!mode) {
    return res.status(400).json({ error: 'mode is required ("http" or "stdio")' });
  }
  try {
    const spec = { mode };
    if (mode === 'http') {
      spec.url = url;
    } else if (mode === 'stdio') {
      spec.command = command;
      spec.args = Array.isArray(args) ? args : typeof args === 'string' ? args.split(/\s+/) : [];
    }
    const result = await diagnose(spec);
    res.json(result);
  } catch (err) {
    res.status(500).json({ ok: false, error: { kind: 'internal_error', details: err.message } });
  }
});

// API route for diagnosing all servers within an uploaded MCP config
app.post('/api/config/diagnose', async (req, res) => {
  const { configText, config, configFormat } = req.body || {};
  if (!configText && !config) {
    return res.status(400).json({ error: 'configText (string) or config (object) is required' });
  }
  try {
    const normalized = parseMcpConfigContent(configText ?? config, configFormat);
    const results = await diagnoseConfigEntries(normalized);
    const servers = attachConfigMetadata(normalized, results);
    res.json({ ok: true, format: normalized.format, config: normalized, servers });
  } catch (err) {
    const status = err.code && err.code.startsWith('CONFIG_') ? 400 : 500;
    res.status(status).json({ ok: false, error: { kind: 'config_error', details: err.message } });
  }
});

// API route for converting/saving configs
app.post('/api/config/export', async (req, res) => {
  const { config, targetFormat } = req.body || {};
  if (!config || typeof config !== 'object' || !targetFormat) {
    return res.status(400).json({ ok: false, error: { kind: 'invalid_request', details: 'config and targetFormat are required' } });
  }
  try {
    let content;
    if (targetFormat === 'json') {
      content = serializeMcpConfigToJson(config);
    } else if (targetFormat === 'toml') {
      content = serializeMcpConfigToToml(config);
    } else {
      return res.status(400).json({ ok: false, error: { kind: 'unsupported_format', details: 'targetFormat must be "json" or "toml"' } });
    }
    res.json({ ok: true, format: targetFormat, content });
  } catch (err) {
    const status = err.code && err.code.startsWith('CONFIG_') ? 400 : 500;
    res.status(status).json({ ok: false, error: { kind: 'config_export_error', details: err.message } });
  }
});

// API route for merging a single server config into the current config
app.post('/api/config/add-server', async (req, res) => {
  const { baseConfig, additionText, additionFormat } = req.body || {};
  if (!additionText || typeof additionText !== 'string') {
    return res.status(400).json({ ok: false, error: { kind: 'invalid_request', details: 'additionText (string) is required' } });
  }
  try {
    const addition = parseMcpConfigContent(additionText, additionFormat);
    if (!addition.servers.length) {
      const error = new Error('Provided config did not contain any MCP servers.');
      error.code = 'CONFIG_SCHEMA_ERROR';
      throw error;
    }
    let baseNormalized = null;
    if (baseConfig && typeof baseConfig === 'object') {
      baseNormalized = JSON.parse(JSON.stringify(baseConfig));
      if (!Array.isArray(baseNormalized.servers)) {
        baseNormalized.servers = [];
      }
      if (!baseNormalized.topLevel || typeof baseNormalized.topLevel !== 'object') {
        baseNormalized.topLevel = {};
      }
      if (!baseNormalized.format) {
        baseNormalized.format = addition.format ?? 'json';
      }
    }
    const merged = mergeNormalizedConfig(baseNormalized, addition);
    const results = await diagnoseConfigEntries(merged);
    const servers = attachConfigMetadata(merged, results);
    res.json({ ok: true, config: merged, servers });
  } catch (err) {
    const status = err.code && err.code.startsWith('CONFIG_') ? 400 : 500;
    res.status(status).json({ ok: false, error: { kind: 'config_merge_error', details: err.message } });
  }
});

// API route for removing a server from the current config
app.post('/api/config/remove-server', async (req, res) => {
  const { baseConfig, serverName } = req.body || {};
  if (!baseConfig || typeof baseConfig !== 'object') {
    return res.status(400).json({ ok: false, error: { kind: 'invalid_request', details: 'baseConfig is required' } });
  }
  if (!serverName || typeof serverName !== 'string') {
    return res.status(400).json({ ok: false, error: { kind: 'invalid_request', details: 'serverName is required' } });
  }
  try {
    const normalizedBase = JSON.parse(JSON.stringify(baseConfig));
    const reduced = removeServerFromConfig(normalizedBase, serverName);
    const results = await diagnoseConfigEntries(reduced);
    const servers = attachConfigMetadata(reduced, results);
    res.json({ ok: true, config: reduced, servers });
  } catch (err) {
    const status =
      err.code && (err.code.startsWith('CONFIG_') || err.code === 'CONFIG_NOT_FOUND') ? 400 : 500;
    res.status(status).json({ ok: false, error: { kind: 'config_remove_error', details: err.message } });
  }
});

// API route for testing individual tools
app.post('/api/tools/call', async (req, res) => {
  const { spec, toolName, toolArgs } = req.body || {};
  if (!spec || typeof spec !== 'object' || !spec.mode) {
    return res.status(400).json({ error: 'spec with a valid mode is required' });
  }
  if (!toolName || typeof toolName !== 'string') {
    return res.status(400).json({ error: 'toolName is required' });
  }
  try {
    const result = await callTool(spec, toolName, toolArgs ?? {});
    res.json(result);
  } catch (err) {
    res.status(500).json({ ok: false, error: { kind: 'internal_error', details: err.message } });
  }
});

// Serve static files from the public directory
const publicDir = path.join(__dirname, 'public');
app.use(express.static(publicDir));

// Fallback to index.html for any other route (supports client‑side routing if needed)
app.get('*', (_req, res) => {
  res.sendFile(path.join(publicDir, 'index.html'));
});

// Start the server
app.listen(PORT, () => {
  console.log(`MCP diagnosis UI server is running on http://localhost:${PORT}`);
});

function attachConfigMetadata(normalized, results) {
  const map = new Map();
  (normalized.servers || []).forEach((server) => {
    map.set(server.name, server);
  });
  return results.map((item) => {
    const configEntry = map.get(item.name);
    const snippetJson = configEntry ? serializeServerSnippet(configEntry, 'json') : null;
    const snippetToml = configEntry ? serializeServerSnippet(configEntry, 'toml') : null;
    const defaultSnippet =
      normalized.format === 'toml'
        ? snippetToml ?? snippetJson
        : snippetJson ?? snippetToml;
    return {
      ...item,
      configEntry: configEntry ? JSON.parse(JSON.stringify(configEntry)) : null,
      configSnippet: defaultSnippet,
      configSnippets: {
        json: snippetJson,
        toml: snippetToml
      },
      configFormat: normalized.format
    };
  });
}
