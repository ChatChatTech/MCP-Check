/*
 * MCP doctor module
 *
 * This module provides a single asynchronous function `diagnose` that inspects
 * a Model Context Protocol (MCP) server over either stdio or HTTP. The
 * function uses the official MCP client SDK to establish a connection,
 * perform the initialize/initialized handshake, and then query the server
 * for its exposed tools, prompts and resources. If anything goes wrong
 * during connection or handshake the error is classified into a structured
 * shape to make it easy for callers (e.g. a web UI) to display helpful
 * messages to the user.
 *
 * The implementation borrows heavily from the CLI‑based mcp‑doctor script
 * developed earlier. It is packaged as a reusable module here so that
 * server.js can invoke it directly without spawning a child process. When
 * adding additional transports or error conditions, update the classifyError
 * function accordingly.
 */

const { Client } = require('@modelcontextprotocol/sdk/client/index.js');
const { StdioClientTransport } = require('@modelcontextprotocol/sdk/client/stdio.js');
const { StreamableHTTPClientTransport } = require('@modelcontextprotocol/sdk/client/streamableHttp.js');
const { SSEClientTransport } = require('@modelcontextprotocol/sdk/client/sse.js');
const fs = require('fs/promises');
const path = require('path');
const TOML = require('@iarna/toml');

const DEFAULT_TIMEOUT_MS = 15000;

/**
 * Wrap a promise with a timeout. If the promise does not resolve within the
 * allotted time the returned promise rejects with a timeout error.
 *
 * @param {Promise<T>} promise The promise to wrap
 * @param {number} ms Timeout in milliseconds
 * @param {string} label A label used in the timeout error message
 * @returns {Promise<T>}
 * @template T
 */
function withTimeout(promise, ms, label) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      const err = new Error(`${label} timed out after ${ms}ms`);
      err.code = 'ETIMEDOUT';
      reject(err);
    }, ms);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      }
    );
  });
}

/**
 * Attempt to classify an arbitrary error into a friendlier shape. The
 * classification logic is adapted from the earlier CLI version of the MCP
 * doctor. It inspects the error message, code and HTTP status (if present)
 * and assigns a short `kind` string along with a human‑readable `advice`
 * whenever possible. Any unrecognised errors are reported as `unknown` and
 * the original error is attached in the `details` field for further
 * inspection.
 *
 * @param {any} e The error thrown by the MCP client or HTTP layer
 * @returns {{kind: string, advice?: string, details?: unknown}}
 */
function classifyError(e) {
  const msg = (e?.message || '').toLowerCase();
  const code = e?.error?.code ?? e?.code;
  const status = e?.response?.status ?? e?.status;

  // Node‑level connection problems
  if (msg.includes('econnrefused') || (msg.includes('connect') && msg.includes('refused'))) {
    return { kind: 'connection_refused', advice: 'Check that the server is running and reachable on the specified port/path.' };
  }
  if (msg.includes('timed out') || code === 'ETIMEDOUT') {
    return { kind: 'timeout', advice: 'The connection timed out. Increase the timeout or ensure the server is responsive.' };
  }

  // JSON‑RPC protocol mismatch
  if (msg.includes('unsupported protocol version') || code === -32602) {
    return {
      kind: 'protocol_version_mismatch',
      advice: 'Client and server disagree on the protocol version. Upgrade/downgrade or configure the MCP version header accordingly.',
      details: e?.error ?? e
    };
  }
  if (msg.includes('method not found') || code === -32601) {
    return {
      kind: 'method_not_found',
      advice: 'The server does not implement the requested method. Ensure the capability is supported and spelled correctly.',
      details: e?.error ?? e
    };
  }
  if (msg.includes('invalid request') || code === -32600) {
    return {
      kind: 'invalid_request',
      advice: 'The server rejected our JSON‑RPC. Check that there is no extraneous output on stdout and that the request body is valid JSON.',
      details: e?.error ?? e
    };
  }
  if (msg.includes('sse') && msg.includes('not')) {
    return {
      kind: 'transport_mismatch',
      advice: 'The server may only support Server‑Sent Events (SSE). Try using an SSE client or ensure the server exposes a Streamable HTTP endpoint.'
    };
  }

  // HTTP layer hints
  if (status === 404 || msg.includes('404')) {
    return { kind: 'http_404', advice: 'The path is not an MCP endpoint. Check that the URL is correct (e.g. /mcp).' };
  }
  if (status === 405 || msg.includes('405')) {
    return { kind: 'http_405', advice: 'The HTTP method is not allowed at this endpoint. Verify the MCP route and transport.' };
  }
  if (status === 400 || msg.includes('400') || msg.includes('mcp-protocol-version')) {
    return {
      kind: 'missing_version_header',
      advice: 'For HTTP transports you must send the MCP‑Protocol‑Version header with every request after initialize.'
    };
  }

  return { kind: 'unknown', details: e };
}

/**
 * Establish a client connection using the provided specification and capture handshake details.
 *
 * @param {{mode: 'stdio'|'http', command?: string, args?: string[], env?: Record<string, string>, url?: string, cwd?: string, stderr?: string}} spec
 * @param {number} timeoutMs
 * @returns {Promise<{client: InstanceType<typeof Client>, transportName: 'stdio'|'http'|'sse', handshake: {protocolVersion: string, serverInfo?: any, capabilities?: any, instructions?: any}}>}
 */
async function connectClient(spec, timeoutMs = DEFAULT_TIMEOUT_MS) {
  const client = new Client({ name: 'mcp-diagnosis-ui', version: '0.1.0' });
  let transportName = null;
  let transport = null;
  try {
    if (spec.mode === 'stdio') {
      const command = spec.command;
      if (!command) throw new Error('No command provided for stdio mode');
      const args = spec.args || [];
      const stdioOptions = { command, args };
      if (spec.env && typeof spec.env === 'object') {
        stdioOptions.env = spec.env;
      }
      if (spec.cwd) {
        stdioOptions.cwd = spec.cwd;
      }
      if (spec.stderr) {
        stdioOptions.stderr = spec.stderr;
      }
      transport = new StdioClientTransport(stdioOptions);
      await withTimeout(client.connect(transport), timeoutMs, 'connect (stdio)');
      transportName = 'stdio';
    } else if (spec.mode === 'http') {
      if (!spec.url) throw new Error('No URL provided for http mode');
      const urlObj = new URL(spec.url);
      try {
        transport = new StreamableHTTPClientTransport(urlObj);
        await withTimeout(client.connect(transport), timeoutMs, 'connect (http)');
        transportName = 'http';
      } catch (httpErr) {
        transport = new SSEClientTransport(urlObj);
        await withTimeout(client.connect(transport), timeoutMs, 'connect (sse)');
        transportName = 'sse';
      }
    } else {
      throw new Error(`Unknown mode: ${spec.mode}`);
    }

    const handshake = {
      protocolVersion: typeof transport?.protocolVersion === 'string' && transport.protocolVersion
        ? transport.protocolVersion
        : 'negotiated',
      serverInfo: client.getServerVersion() ?? null,
      capabilities: client.getServerCapabilities() ?? null,
      instructions: client.getInstructions() ?? null
    };

    return { client, transportName, handshake };
  } catch (err) {
    try {
      await client.close();
    } catch (_) {
      /* ignore close errors */
    }
    throw err;
  }
}

/**
 * Diagnose an MCP server by connecting using the appropriate transport and
 * querying its exposed capabilities. Supports both stdio servers (spawned
 * locally) and HTTP endpoints. The returned object has the shape used by
 * the CLI doctor script: an `ok` flag, the transport used (stdio, http or
 * sse), and lists of tools, prompts and resources if available. On error
 * the `error` field contains a classification describing what went wrong.
 *
 * @param {{mode: 'stdio'|'http', command?: string, args?: string[], env?: Record<string, string>, url?: string}} spec
 * @returns {Promise<{ok: boolean, transport: 'stdio'|'http'|'sse'|null, serverInfo?: any, protocolVersion?: string, capabilities?: any, tools?: Array<{name: string, description?: string}>, prompts?: Array<{name: string, description?: string}>, resources?: Array<{uri: string, name?: string, description?: string}>, error?: {kind: string, advice?: string, details?: unknown}}>} The diagnostic result
 */
async function diagnose(spec) {
  let connection;
  try {
    connection = await connectClient(spec, DEFAULT_TIMEOUT_MS);
    const { client, transportName, handshake } = connection;

    // Once connected, list tools/prompts/resources. Some servers may omit
    // certain methods; in those cases we safely catch and ignore errors.
    let tools = [];
    let prompts = [];
    let resources = [];
    let serverInfo = null;
    let capabilities = null;
    let instructions = null;
    try {
      const toolsList = await withTimeout(client.listTools(), DEFAULT_TIMEOUT_MS, 'tools/list');
      const arr = Array.isArray(toolsList) ? toolsList : toolsList?.tools;
      if (Array.isArray(arr)) {
        tools = arr.map((t) => ({
          name: t.name,
          description: t.description,
          inputSchema: t.inputSchema ?? null,
          outputSchema: t.outputSchema ?? null,
          annotations: t.annotations ?? null
        }));
      }
    } catch (e) {
      // Some servers may not implement tools/list; ignore
    }
    try {
      const promptsList = await client.listPrompts().catch(() => undefined);
      const arr = Array.isArray(promptsList) ? promptsList : promptsList?.prompts;
      if (Array.isArray(arr)) {
        prompts = arr.map((p) => ({ name: p.name, description: p.description }));
      }
    } catch (e) {
      // ignore
    }
    try {
      const resourcesList = await client.listResources().catch(() => undefined);
      const arr = Array.isArray(resourcesList) ? resourcesList : resourcesList?.resources;
      if (Array.isArray(arr)) {
        resources = arr.map((r) => ({ uri: r.uri ?? r.href ?? '', name: r.name, description: r.description }));
      }
    } catch (e) {
      // ignore
    }
    serverInfo = handshake.serverInfo;
    capabilities = handshake.capabilities;
    instructions = handshake.instructions;
    await client.close().catch(() => {});

    // The MCP client hides the exact negotiated protocol version; indicate success generically.
    return {
      ok: true,
      transport: transportName,
      protocolVersion: handshake.protocolVersion,
      handshake: {
        protocolVersion: handshake.protocolVersion,
        serverInfo,
        capabilities,
        instructions
      },
      tools,
      prompts,
      resources
    };
  } catch (err) {
    if (connection?.client) {
      await connection.client.close().catch(() => {});
    }
    return {
      ok: false,
      transport: connection?.transportName ?? null,
      handshake: connection?.handshake,
      error: classifyError(err)
    };
  }
}

/**
 * Load and validate an MCP configuration file.
 *
 * The configuration must follow the shape shown in the supported template:
 * {
 *   "mcpServers": {
 *     "serverName": {
 *       "command": "npx",
 *       "args": ["@playwright/mcp@latest"],
 *       "env": { "FOO": "bar" }
 *     }
 *   }
 * }
 *
 * Alternatively a server entry may specify a `url` for HTTP transports.
 *
 * @param {string} configPath Absolute or relative path to mcp.json
 * @returns {Promise<{path: string, servers: Array<{name: string, mode: 'stdio'|'http', command?: string, args?: string[], env?: Record<string, string>, url?: string}>}>}
 */
async function loadMcpConfig(configPath) {
  if (typeof configPath !== 'string' || !configPath.trim()) {
    throw new Error('configPath must be a non-empty string');
  }
  const resolvedPath = path.resolve(configPath);
  let raw;
  try {
    raw = await fs.readFile(resolvedPath, 'utf8');
  } catch (err) {
    const error = new Error(`Unable to read MCP config file at ${resolvedPath}: ${err.message}`);
    error.code = 'CONFIG_READ_ERROR';
    error.cause = err;
    throw error;
  }
  const ext = path.extname(resolvedPath).toLowerCase();
  const formatHint = ext === '.toml' ? 'toml' : ext === '.json' ? 'json' : undefined;
  const normalized = parseMcpConfigContent(raw, formatHint);
  return { path: resolvedPath, ...normalized };
}

/**
 * Validate and normalise a parsed MCP configuration object.
 *
 * @param {unknown} parsed
 * @param {{format: 'json'|'toml'}} options
 * @returns {{format: 'json'|'toml', topLevel: Record<string, unknown>, servers: Array<object>}}
 */
function normalizeMcpConfig(parsed, { format }) {
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('MCP configuration must be a JSON/TOML object.');
  }
  const topLevel = deepClone(parsed);

  if (format === 'json') {
    // Allow both mcpServers and mcp_servers just in case.
    const serversNode = parsed.mcpServers ?? parsed.mcp_servers;
    if (!serversNode || typeof serversNode !== 'object' || Array.isArray(serversNode)) {
      const error = new Error('mcp.json must contain an "mcpServers" object with named entries.');
      error.code = 'CONFIG_SCHEMA_ERROR';
      throw error;
    }
    delete topLevel.mcpServers;
    delete topLevel.mcp_servers;
    const servers = normalizeServersMap(serversNode, { format });
    return { format, topLevel, servers };
  }

  if (format === 'toml') {
    const serversNode = parsed.mcp_servers;
    if (!serversNode || typeof serversNode !== 'object' || Array.isArray(serversNode)) {
      const error = new Error('config.toml must contain an "mcp_servers" table with named entries.');
      error.code = 'CONFIG_SCHEMA_ERROR';
      throw error;
    }
    delete topLevel.mcp_servers;
    const servers = normalizeServersMap(serversNode, { format });
    return { format, topLevel, servers };
  }

  throw new Error(`Unsupported MCP config format: ${format}`);
}

/**
 * Diagnose all servers defined in an MCP configuration file.
 *
 * @param {string} configPath Path to the config file
 * @param {{ diagnoseFn?: typeof diagnose }} [options] Optional overrides for testing
 * @returns {Promise<Array<{name: string, mode: 'stdio'|'http', spec: object, result: any}>>}
 */
async function diagnoseConfigFile(configPath, options = {}) {
  const normalized = await loadMcpConfig(configPath);
  return diagnoseConfigEntries(normalized, options);
}

/**
 * Parse raw configuration content and normalise it.
 *
 * @param {string|object} content Raw config string or already parsed object
 * @param {'json'|'toml'} [formatHint]
 * @returns {{format: 'json'|'toml', topLevel: Record<string, unknown>, servers: Array<object>}}
 */
function parseMcpConfigContent(content, formatHint) {
  let parsed;
  let format = formatHint ?? null;
  if (typeof content === 'string') {
    const trimmed = content.trim();
    if (!trimmed) {
      throw new Error('Config content is empty.');
    }
    if (!format || format === 'json') {
      try {
        parsed = JSON.parse(trimmed);
        format = 'json';
      } catch (jsonErr) {
        if (format === 'json') {
          const error = new Error(`Malformed JSON content: ${jsonErr.message}`);
          error.code = 'CONFIG_PARSE_ERROR';
          error.cause = jsonErr;
          throw error;
        }
        try {
          parsed = TOML.parse(trimmed);
          format = 'toml';
        } catch (tomlErr) {
          const error = new Error(`Unable to parse config content as JSON or TOML: ${tomlErr.message}`);
          error.code = 'CONFIG_PARSE_ERROR';
          error.cause = tomlErr;
          throw error;
        }
      }
    } else if (format === 'toml') {
      try {
        parsed = TOML.parse(trimmed);
      } catch (tomlErr) {
        const error = new Error(`Malformed TOML content: ${tomlErr.message}`);
        error.code = 'CONFIG_PARSE_ERROR';
        error.cause = tomlErr;
        throw error;
      }
    } else {
      throw new Error(`Unsupported config format hint: ${format}`);
    }
  } else if (content && typeof content === 'object') {
    parsed = content;
    if (!format) {
      format = 'json';
    }
  } else {
    throw new Error('Config content must be a string or object.');
  }

  const resolvedFormat = format ?? 'json';
  return normalizeMcpConfig(parsed, { format: resolvedFormat });
}

/**
 * Diagnose an array of server definitions produced by normalizeMcpConfig.
 *
 * @param {{servers: Array<object>}|Array<object>} configOrServers
 * @param {{ diagnoseFn?: typeof diagnose }} [options]
 * @returns {Promise<Array<{name: string, mode: 'stdio'|'http', spec: object, result: any}>>}
 */
async function diagnoseConfigEntries(configOrServers, options = {}) {
  const servers = Array.isArray(configOrServers) ? configOrServers : configOrServers?.servers;
  if (!Array.isArray(servers)) {
    throw new Error('No MCP servers found to diagnose.');
  }
  const diagnoseFn = options.diagnoseFn || diagnose;
  const results = [];
  for (const entry of servers) {
    const spec = buildSpecFromEntry(entry);
    const result = await diagnoseFn(spec);
    results.push({ name: entry.name, mode: entry.mode, spec, result });
  }
  return results;
}

/**
 * Convert a normalised MCP configuration back into the JSON structure.
 *
 * @param {{format: string, topLevel: Record<string, unknown>, servers: Array<object>}} config
 * @returns {string}
 */
function serializeMcpConfigToJson(config) {
  validateNormalizedConfig(config);
  const root = deepClone(config.topLevel) || {};
  const mcpServers = {};
  for (const server of config.servers) {
    const serverObj = buildJsonServerObject(server);
    mcpServers[server.name] = serverObj;
  }
  root.mcpServers = mcpServers;
  return JSON.stringify(root, null, 2);
}

/**
 * Convert a normalised MCP configuration back into TOML.
 *
 * @param {{format: string, topLevel: Record<string, unknown>, servers: Array<object>}} config
 * @returns {string}
 */
function serializeMcpConfigToToml(config) {
  validateNormalizedConfig(config);
  const root = deepClone(config.topLevel) || {};
  const mcpServers = {};
  for (const server of config.servers) {
    const serverTable = buildTomlServerObject(server);
    mcpServers[server.name] = serverTable;
  }
  root.mcp_servers = mcpServers;
  return `${TOML.stringify(root).trim()}\n`;
}

/**
 * Call a specific tool on an MCP server described by the given spec.
 *
 * @param {{mode: 'stdio'|'http', command?: string, args?: string[], env?: Record<string, string>, url?: string}} spec
 * @param {string} toolName
 * @param {Record<string, unknown>} [toolArgs]
 * @returns {Promise<{ok: boolean, transport: 'stdio'|'http'|'sse'|null, handshake?: object, output?: unknown, error?: {kind: string, advice?: string, details?: unknown}}>}
 */
async function callTool(spec, toolName, toolArgs = {}) {
  if (typeof toolName !== 'string' || !toolName.trim()) {
    throw new Error('toolName must be a non-empty string');
  }
  if (toolArgs === null || typeof toolArgs !== 'object' || Array.isArray(toolArgs)) {
    throw new Error('toolArgs must be an object');
  }
  let client;
  let connection;
  try {
    connection = await connectClient(spec, DEFAULT_TIMEOUT_MS);
    client = connection.client;
    const result = await withTimeout(
      client.callTool({ name: toolName, arguments: toolArgs }),
      DEFAULT_TIMEOUT_MS,
      `tools/call (${toolName})`
    );
    await client.close().catch(() => {});
    return {
      ok: true,
      transport: connection.transportName,
      handshake: connection.handshake,
      output: result
    };
  } catch (err) {
    if (client) {
      await client.close().catch(() => {});
    }
    return {
      ok: false,
      transport: connection?.transportName ?? null,
      handshake: connection?.handshake,
      error: classifyError(err)
    };
  }
}

module.exports = {
  diagnose,
  loadMcpConfig,
  diagnoseConfigFile,
  parseMcpConfigContent,
  diagnoseConfigEntries,
  mergeNormalizedConfig,
  removeServerFromConfig,
  serializeMcpConfigToJson,
  serializeMcpConfigToToml,
  serializeServerSnippet,
  callTool
};

// ---------- normalisation helpers ----------

const SERVER_KEY_ALIASES = {
  bearer_token_env_var: 'bearerTokenEnvVar',
  bearerTokenEnvVar: 'bearerTokenEnvVar',
  bearer_token_file: 'bearerTokenFile',
  bearerTokenFile: 'bearerTokenFile',
  startup_timeout_sec: 'startupTimeoutSec',
  startupTimeoutSec: 'startupTimeoutSec',
  tool_timeout_sec: 'toolTimeoutSec',
  toolTimeoutSec: 'toolTimeoutSec'
};

const KNOWN_SERVER_KEYS = new Set([
  'command',
  'args',
  'env',
  'cwd',
  'stderr',
  'url',
  'enabled',
  'bearerTokenEnvVar',
  'bearerTokenFile',
  'startupTimeoutSec',
  'toolTimeoutSec'
]);

function normalizeServersMap(serversNode, { format }) {
  const servers = [];
  for (const [rawName, serverConfig] of Object.entries(serversNode)) {
    const name = String(rawName || '').trim();
    if (!name) {
      throw new Error('Server names must not be empty.');
    }
    if (!serverConfig || typeof serverConfig !== 'object' || Array.isArray(serverConfig)) {
      throw new Error(`Server "${name}" must be an object/table.`);
    }
    const rawClone = deepClone(serverConfig);
    const normalized = {
      name,
      mode: null,
      command: undefined,
      args: undefined,
      env: undefined,
      cwd: serverConfig.cwd ? String(serverConfig.cwd) : undefined,
      stderr: serverConfig.stderr,
      url: undefined,
      enabled: typeof serverConfig.enabled === 'boolean' ? serverConfig.enabled : undefined,
      bearerTokenEnvVar: undefined,
      bearerTokenFile: undefined,
      startupTimeoutSec: parseOptionalNumber(serverConfig.startup_timeout_sec ?? serverConfig.startupTimeoutSec),
      toolTimeoutSec: parseOptionalNumber(serverConfig.tool_timeout_sec ?? serverConfig.toolTimeoutSec),
      extra: {},
      raw: rawClone,
      sourceFormat: format
    };

    for (const [key, value] of Object.entries(serverConfig)) {
      const canonicalKey = SERVER_KEY_ALIASES[key] ?? key;
      switch (canonicalKey) {
        case 'command':
          if (typeof value === 'string' && value.trim()) {
            normalized.command = value.trim();
          }
          break;
        case 'args':
          normalized.args = normalizeArgs(value);
          break;
        case 'env':
          normalized.env = normalizeEnvMap(value);
          break;
        case 'url':
          if (typeof value === 'string' && value.trim()) {
            normalized.url = value.trim();
          }
          break;
        case 'bearerTokenEnvVar':
          if (value !== undefined && value !== null) {
            normalized.bearerTokenEnvVar = String(value);
          }
          break;
        case 'bearerTokenFile':
          if (value !== undefined && value !== null) {
            normalized.bearerTokenFile = String(value);
          }
          break;
        case 'startupTimeoutSec':
          normalized.startupTimeoutSec = parseOptionalNumber(value);
          break;
        case 'toolTimeoutSec':
          normalized.toolTimeoutSec = parseOptionalNumber(value);
          break;
        case 'cwd':
          normalized.cwd = typeof value === 'string' ? value : normalized.cwd;
          break;
        case 'stderr':
          normalized.stderr = value;
          break;
        case 'enabled':
          normalized.enabled = typeof value === 'boolean' ? value : normalized.enabled;
          break;
        default:
          if (!KNOWN_SERVER_KEYS.has(canonicalKey)) {
            normalized.extra[key] = deepClone(value);
          }
      }
    }

    if (normalized.url) {
      normalized.mode = 'http';
    } else if (normalized.command) {
      normalized.mode = 'stdio';
    } else {
      throw new Error(`Server "${name}" must define either "command" (stdio) or "url" (http).`);
    }

    if (normalized.mode === 'stdio' && !normalized.command) {
      throw new Error(`STDIO server "${name}" requires a "command".`);
    }
    if (normalized.mode === 'http' && !normalized.url) {
      throw new Error(`HTTP server "${name}" requires a "url".`);
    }

    servers.push(normalized);
  }
  return servers;
}

function normalizeArgs(value) {
  if (value === undefined) return undefined;
  if (!Array.isArray(value)) {
    throw new Error('Server "args" must be an array of strings.');
  }
  return value.map((item, idx) => {
    if (item === undefined || item === null) {
      throw new Error(`Server args[${idx}] must not be null/undefined.`);
    }
    return String(item);
  });
}

function normalizeEnvMap(value) {
  if (value === undefined) return undefined;
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('Server "env" must be an object of key/value pairs.');
  }
  const env = {};
  for (const [key, raw] of Object.entries(value)) {
    env[key] = raw === undefined || raw === null ? '' : String(raw);
  }
  return env;
}

function parseOptionalNumber(value) {
  if (value === undefined || value === null || value === '') return undefined;
  const num = Number(value);
  return Number.isFinite(num) ? num : undefined;
}

function deepClone(value) {
  if (value === undefined) return undefined;
  return JSON.parse(JSON.stringify(value));
}

function buildSpecFromEntry(entry) {
  if (entry.mode === 'http') {
    const spec = {
      mode: 'http',
      url: entry.url
    };
    return spec;
  }
  const spec = {
    mode: 'stdio',
    command: entry.command,
    args: Array.isArray(entry.args) ? [...entry.args] : []
  };
  if (entry.env) {
    spec.env = { ...entry.env };
  }
  if (entry.cwd) {
    spec.cwd = entry.cwd;
  }
  if (entry.stderr !== undefined) {
    spec.stderr = entry.stderr;
  }
  return spec;
}

function buildJsonServerObject(server) {
  if (server.mode === 'stdio' && !server.command) {
    throw new Error(`STDIO server "${server.name}" is missing a command.`);
  }
  if (server.mode === 'http' && !server.url) {
    throw new Error(`HTTP server "${server.name}" is missing a url.`);
  }
  const obj = {};
  if (server.mode === 'stdio') {
    obj.command = server.command;
    if (Array.isArray(server.args) && server.args.length) {
      obj.args = [...server.args];
    }
    if (server.env && Object.keys(server.env).length) {
      obj.env = { ...server.env };
    }
    if (server.cwd) {
      obj.cwd = server.cwd;
    }
    if (server.stderr !== undefined) {
      obj.stderr = server.stderr;
    }
  } else if (server.mode === 'http') {
    obj.url = server.url;
    if (server.env && Object.keys(server.env).length) {
      obj.env = { ...server.env };
    }
    if (server.bearerTokenEnvVar) {
      obj.bearerTokenEnvVar = server.bearerTokenEnvVar;
    }
    if (server.bearerTokenFile) {
      obj.bearerTokenFile = server.bearerTokenFile;
    }
  }
  if (server.enabled !== undefined) {
    obj.enabled = server.enabled;
  }
  if (server.toolTimeoutSec !== undefined) {
    obj.toolTimeoutSec = server.toolTimeoutSec;
  }
  if (server.startupTimeoutSec !== undefined) {
    obj.startupTimeoutSec = server.startupTimeoutSec;
  }
  if (server.extra && typeof server.extra === 'object') {
    for (const [key, value] of Object.entries(server.extra)) {
      if (value !== undefined) {
        obj[key] = deepClone(value);
      }
    }
  }
  pruneUndefined(obj);
  return obj;
}

function buildTomlServerObject(server) {
  if (server.mode === 'stdio' && !server.command) {
    throw new Error(`STDIO server "${server.name}" is missing a command.`);
  }
  if (server.mode === 'http' && !server.url) {
    throw new Error(`HTTP server "${server.name}" is missing a url.`);
  }
  const table = {};
  if (server.mode === 'stdio') {
    table.command = server.command;
    if (Array.isArray(server.args) && server.args.length) {
      table.args = [...server.args];
    }
    if (server.env && Object.keys(server.env).length) {
      table.env = { ...server.env };
    }
    if (server.cwd) {
      table.cwd = server.cwd;
    }
    if (server.stderr !== undefined) {
      table.stderr = server.stderr;
    }
  } else if (server.mode === 'http') {
    table.url = server.url;
    if (server.env && Object.keys(server.env).length) {
      table.env = { ...server.env };
    }
    if (server.bearerTokenEnvVar) {
      table.bearer_token_env_var = server.bearerTokenEnvVar;
    }
    if (server.bearerTokenFile) {
      table.bearer_token_file = server.bearerTokenFile;
    }
  }
  if (server.enabled !== undefined) {
    table.enabled = server.enabled;
  }
  if (server.toolTimeoutSec !== undefined) {
    table.tool_timeout_sec = server.toolTimeoutSec;
  }
  if (server.startupTimeoutSec !== undefined) {
    table.startup_timeout_sec = server.startupTimeoutSec;
  }
  if (server.extra && typeof server.extra === 'object') {
    for (const [key, value] of Object.entries(server.extra)) {
      if (value === undefined) continue;
      table[toSnakeCase(key)] = deepClone(value);
    }
  }
  pruneUndefined(table);
  return table;
}

function pruneUndefined(obj) {
  for (const key of Object.keys(obj)) {
    if (obj[key] === undefined) {
      delete obj[key];
    } else if (obj[key] && typeof obj[key] === 'object' && !Array.isArray(obj[key])) {
      pruneUndefined(obj[key]);
      if (Object.keys(obj[key]).length === 0) {
        delete obj[key];
      }
    } else if (Array.isArray(obj[key]) && obj[key].length === 0) {
      delete obj[key];
    }
  }
}

function toSnakeCase(key) {
  return key
    .replace(/([A-Z])/g, '_$1')
    .replace(/[-\s]+/g, '_')
    .toLowerCase();
}

function validateNormalizedConfig(config) {
  if (!config || typeof config !== 'object') {
    throw new Error('Invalid config payload.');
  }
  if (!Array.isArray(config.servers)) {
    throw new Error('Config payload missing servers array.');
  }
  config.servers.forEach((server) => {
    if (!server || typeof server !== 'object') {
      throw new Error('Invalid server entry in config payload.');
    }
    if (!server.name) {
      throw new Error('Server entry missing name.');
    }
  });
}

function removeServerFromConfig(config, serverName) {
  if (!serverName) {
    throw new Error('serverName is required.');
  }
  if (!config || typeof config !== 'object') {
    throw new Error('Config payload must be an object.');
  }
  validateNormalizedConfig(config);
  const next = deepClone(config);
  const beforeCount = next.servers.length;
  next.servers = next.servers.filter((server) => server.name !== serverName);
  if (next.servers.length === beforeCount) {
    const error = new Error(`Server "${serverName}" not found in configuration.`);
    error.code = 'CONFIG_NOT_FOUND';
    throw error;
  }
  return next;
}

function serializeServerSnippet(server, format) {
  if (!server || typeof server !== 'object') {
    throw new Error('Server entry must be an object.');
  }
  if (format === 'toml') {
    const root = { mcp_servers: { [server.name]: buildTomlServerObject(server) } };
    return `${TOML.stringify(root).trim()}\n`;
  }
  const root = { mcpServers: { [server.name]: buildJsonServerObject(server) } };
  return JSON.stringify(root, null, 2);
}

function mergeNormalizedConfig(baseConfig, additionConfig) {
  if (!additionConfig || typeof additionConfig !== 'object') {
    throw new Error('Addition config must be an object.');
  }
  const base = baseConfig ? JSON.parse(JSON.stringify(baseConfig)) : { format: additionConfig.format, topLevel: {}, servers: [] };
  if (!Array.isArray(base.servers)) {
    base.servers = [];
  }
  if (!base.topLevel || typeof base.topLevel !== 'object' || Array.isArray(base.topLevel)) {
    base.topLevel = {};
  }
  validateNormalizedConfig(base);
  validateNormalizedConfig(additionConfig);
  if (!additionConfig.servers.length) {
    throw new Error('No MCP servers provided in addition config.');
  }

  const mergedTopLevel = deepClone(base.topLevel) || {};
  if (additionConfig.topLevel && typeof additionConfig.topLevel === 'object' && !Array.isArray(additionConfig.topLevel)) {
    Object.assign(mergedTopLevel, deepClone(additionConfig.topLevel));
  }

  const serverMap = new Map();
  (base.servers || []).forEach((server) => {
    serverMap.set(server.name, deepClone(server));
  });
  (additionConfig.servers || []).forEach((server) => {
    serverMap.set(server.name, deepClone(server));
  });

  const mergedServers = [];
  (base.servers || []).forEach((server) => {
    const merged = serverMap.get(server.name);
    if (merged) {
      mergedServers.push(merged);
      serverMap.delete(server.name);
    }
  });
  serverMap.forEach((value) => {
    mergedServers.push(value);
  });

  return {
    format: base.format ?? additionConfig.format ?? 'json',
    topLevel: mergedTopLevel,
    servers: mergedServers
  };
}
