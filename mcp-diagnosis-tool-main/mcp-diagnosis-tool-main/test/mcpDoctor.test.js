const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs/promises');
const os = require('os');
const path = require('path');

const {
  loadMcpConfig,
  diagnoseConfigFile,
  parseMcpConfigContent,
  diagnoseConfigEntries,
  mergeNormalizedConfig,
  serializeMcpConfigToJson,
  serializeMcpConfigToToml
} = require('../mcpDoctor');

async function writeTempConfig(data) {
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'mcp-config-'));
  const filePath = path.join(tmpDir, 'mcp.json');
  await fs.writeFile(filePath, JSON.stringify(data), 'utf8');
  return { tmpDir, filePath };
}

test('loadMcpConfig parses stdio and http entries', async (t) => {
  const sampleConfig = {
    mcpServers: {
      playwright: {
        command: 'npx',
        args: ['-y', '@playwright/mcp@latest'],
        env: { FOO: 'bar', COUNT: 2 }
      },
      'cognitive-visual-req': {
        command: '/usr/bin/node',
        args: ['server.js']
      },
      httpServer: {
        url: 'https://example.com/mcp'
      }
    }
  };
  const { tmpDir, filePath } = await writeTempConfig(sampleConfig);
  t.after(async () => {
    await fs.rm(tmpDir, { recursive: true, force: true });
  });

  const normalized = await loadMcpConfig(filePath);
  const { path: resolvedPath } = normalized;

  assert.strictEqual(normalized.format, 'json');
  assert.ok(normalized.topLevel);
  const { servers } = normalized;

  assert.strictEqual(resolvedPath, path.resolve(filePath));
  assert.strictEqual(servers.length, 3);

  const playwright = servers.find((s) => s.name === 'playwright');
  assert.ok(playwright);
  assert.strictEqual(playwright.mode, 'stdio');
  assert.strictEqual(playwright.command, 'npx');
  assert.deepEqual(playwright.args, ['-y', '@playwright/mcp@latest']);
  assert.deepEqual(playwright.env, { FOO: 'bar', COUNT: '2' });

  const httpServer = servers.find((s) => s.name === 'httpServer');
  assert.ok(httpServer);
  assert.strictEqual(httpServer.mode, 'http');
  assert.strictEqual(httpServer.url, 'https://example.com/mcp');
});

test('parseMcpConfigContent accepts JSON string input', () => {
  const json = JSON.stringify({
    mcpServers: {
      hello_world: {
        command: 'node',
        args: ['server.js'],
        env: { ENABLE_SOMETHING: true }
      }
    }
  });
  const normalized = parseMcpConfigContent(json);
  assert.strictEqual(normalized.format, 'json');
  assert.strictEqual(normalized.servers.length, 1);
  const server = normalized.servers[0];
  assert.strictEqual(server.name, 'hello_world');
  assert.strictEqual(server.mode, 'stdio');
  assert.strictEqual(server.command, 'node');
  assert.deepEqual(server.args, ['server.js']);
  assert.deepEqual(server.env, { ENABLE_SOMETHING: 'true' });
});

test('diagnoseConfigFile invokes diagnose for each entry', async (t) => {
  const sampleConfig = {
    mcpServers: {
      stdioTool: {
        command: 'npx',
        args: ['tool.js'],
        env: { ABC: '123' }
      },
      httpTool: {
        url: 'http://localhost:3000/mcp'
      }
    }
  };
  const { tmpDir, filePath } = await writeTempConfig(sampleConfig);
  t.after(async () => {
    await fs.rm(tmpDir, { recursive: true, force: true });
  });

  const calls = [];
  const fakeDiagnose = async (spec) => {
    calls.push(spec);
    return { ok: true, transport: spec.mode };
  };

  const results = await diagnoseConfigFile(filePath, { diagnoseFn: fakeDiagnose });

  assert.strictEqual(calls.length, 2);
  assert.deepEqual(calls[0], {
    mode: 'stdio',
    command: 'npx',
    args: ['tool.js'],
    env: { ABC: '123' }
  });
  assert.deepEqual(calls[1], {
    mode: 'http',
    url: 'http://localhost:3000/mcp'
  });

  assert.strictEqual(results.length, 2);
  assert.deepEqual(results[0], {
    name: 'stdioTool',
    mode: 'stdio',
    spec: {
      mode: 'stdio',
      command: 'npx',
      args: ['tool.js'],
      env: { ABC: '123' }
    },
    result: { ok: true, transport: 'stdio' }
  });
  assert.deepEqual(results[1], {
    name: 'httpTool',
    mode: 'http',
    spec: {
      mode: 'http',
      url: 'http://localhost:3000/mcp'
    },
    result: { ok: true, transport: 'http' }
  });
});

test('diagnoseConfigEntries generates specs from parsed servers', async () => {
  const servers = [
    { name: 'stdio', mode: 'stdio', command: 'node', args: ['server.js'], env: { KEY: 'VALUE' } },
    { name: 'http', mode: 'http', url: 'http://localhost:1234/mcp' }
  ];
  const specs = [];
  const fakeDiagnose = async (spec) => {
    specs.push(spec);
    return { ok: true, transport: spec.mode };
  };
  const results = await diagnoseConfigEntries(servers, { diagnoseFn: fakeDiagnose });
  assert.strictEqual(results.length, 2);
  assert.deepEqual(specs[0], {
    mode: 'stdio',
    command: 'node',
    args: ['server.js'],
    env: { KEY: 'VALUE' }
  });
  assert.deepEqual(specs[1], {
    mode: 'http',
    url: 'http://localhost:1234/mcp'
  });
});

test('parseMcpConfigContent handles TOML input', () => {
  const toml = `
experimental_use_rmcp_client = true

[mcp_servers.playwright]
command = "npx"
args = ["-y", "@playwright/mcp@latest"]

[mcp_servers.docs]
url = "https://example.com/mcp"
bearer_token_env_var = "DOCS_TOKEN"
`;
  const normalized = parseMcpConfigContent(toml, 'toml');
  assert.strictEqual(normalized.format, 'toml');
  assert.strictEqual(normalized.topLevel.experimental_use_rmcp_client, true);
  assert.strictEqual(normalized.servers.length, 2);
  const stdio = normalized.servers.find((s) => s.name === 'playwright');
  assert.ok(stdio);
  assert.strictEqual(stdio.mode, 'stdio');
  assert.strictEqual(stdio.command, 'npx');
  assert.deepEqual(stdio.args, ['-y', '@playwright/mcp@latest']);
  const http = normalized.servers.find((s) => s.name === 'docs');
  assert.ok(http);
  assert.strictEqual(http.mode, 'http');
  assert.strictEqual(http.url, 'https://example.com/mcp');
  assert.strictEqual(http.bearerTokenEnvVar, 'DOCS_TOKEN');
});

test('serializeMcpConfigToJson round-trips normalized config', () => {
  const toml = `
experimental_use_rmcp_client = true

[mcp_servers.cli]
command = "node"
args = ["cli.js"]
tool_timeout_sec = 45
`;
  const normalized = parseMcpConfigContent(toml, 'toml');
  const jsonOutput = serializeMcpConfigToJson(normalized);
  const parsed = JSON.parse(jsonOutput);
  assert.strictEqual(parsed.experimental_use_rmcp_client, true);
  assert.ok(parsed.mcpServers.cli);
  assert.strictEqual(parsed.mcpServers.cli.command, 'node');
  assert.deepEqual(parsed.mcpServers.cli.args, ['cli.js']);
  assert.strictEqual(parsed.mcpServers.cli.toolTimeoutSec, 45);
});

test('serializeMcpConfigToToml round-trips normalized config', () => {
  const json = {
    experimental_use_rmcp_client: true,
    mcpServers: {
      httpTool: {
        url: 'https://example.com/mcp',
        bearerTokenEnvVar: 'HTTP_TOKEN'
      }
    }
  };
  const normalized = parseMcpConfigContent(json, 'json');
  const tomlOutput = serializeMcpConfigToToml(normalized);
  const reparsed = parseMcpConfigContent(tomlOutput, 'toml');
  assert.strictEqual(reparsed.format, 'toml');
  assert.strictEqual(reparsed.topLevel.experimental_use_rmcp_client, true);
  const server = reparsed.servers.find((s) => s.name === 'httpTool');
  assert.ok(server);
  assert.strictEqual(server.mode, 'http');
  assert.strictEqual(server.url, 'https://example.com/mcp');
  assert.strictEqual(server.bearerTokenEnvVar, 'HTTP_TOKEN');
});

test('mergeNormalizedConfig merges servers and top-level fields', () => {
  const baseJson = {
    experimental_use_rmcp_client: false,
    mcpServers: {
      core: {
        command: 'node',
        args: ['server.js']
      }
    }
  };
  const additionToml = `experimental_use_rmcp_client = true

[mcp_servers.logger]
url = "https://example.com/logger"
`;
  const base = parseMcpConfigContent(baseJson, 'json');
  const addition = parseMcpConfigContent(additionToml, 'toml');
  const merged = mergeNormalizedConfig(base, addition);
  assert.strictEqual(merged.format, 'json');
  assert.strictEqual(merged.topLevel.experimental_use_rmcp_client, true);
  assert.strictEqual(merged.servers.length, 2);
  const logger = merged.servers.find((s) => s.name === 'logger');
  assert.ok(logger);
  assert.strictEqual(logger.mode, 'http');
  assert.strictEqual(logger.url, 'https://example.com/logger');
});

test('mergeNormalizedConfig replaces existing server definitions and handles empty base', () => {
  const additionToml = `[mcp_servers.shared]
command = "python"
args = ["tool.py"]
`;
  const baseJson = {
    mcpServers: {
      shared: {
        command: 'node',
        args: ['old.js']
      }
    }
  };
  const base = parseMcpConfigContent(baseJson, 'json');
  const addition = parseMcpConfigContent(additionToml, 'toml');
  const merged = mergeNormalizedConfig(base, addition);
  const shared = merged.servers.find((s) => s.name === 'shared');
  assert.ok(shared);
  assert.strictEqual(shared.command, 'python');
  assert.deepEqual(shared.args, ['tool.py']);

  const mergedFromNull = mergeNormalizedConfig(null, addition);
  assert.strictEqual(mergedFromNull.format, 'toml');
  assert.strictEqual(mergedFromNull.servers.length, 1);
  assert.strictEqual(mergedFromNull.servers[0].command, 'python');
});
