//
// script.js
//
// Client-side logic for the MCP Diagnosis UI. Supports manual diagnoses,
// loading mcp.json files, visualising handshake details, listing tool
// arguments (when declared) and testing tools through a modal interface.

(() => {
  const form = document.getElementById('diagnose-form');
  const modeSelect = document.getElementById('mode-select');
  const httpRow = document.getElementById('http-row');
  const stdioRow = document.getElementById('stdio-row');
  const serversList = document.getElementById('servers-list');
  const template = document.getElementById('server-template');

  const loadJsonButton = document.getElementById('load-json-btn');
  const loadTomlButton = document.getElementById('load-toml-btn');
  const addJsonServerButton = document.getElementById('add-json-server-btn');
  const addTomlServerButton = document.getElementById('add-toml-server-btn');
  const saveJsonButton = document.getElementById('save-json-btn');
  const saveTomlButton = document.getElementById('save-toml-btn');
  const configJsonInput = document.getElementById('config-json-input');
  const configTomlInput = document.getElementById('config-toml-input');
  const configFileNameLabel = document.getElementById('config-file-name');

  const modalBackdrop = document.getElementById('modal-backdrop');
  const toolModal = document.getElementById('tool-modal');
  const toolModalBody = document.getElementById('tool-modal-body');
  const toolModalTitle = document.getElementById('tool-modal-title');
  const toolModalSubmit = document.getElementById('tool-modal-submit');
  const toolModalReport = document.getElementById('tool-modal-report');
  const toolModalClose = document.getElementById('tool-modal-close');
  const configModal = document.getElementById('config-modal');
  const configModalTitle = document.getElementById('config-modal-title');
  const configModalDesc = document.getElementById('config-modal-desc');
  const configModalInput = document.getElementById('config-modal-input');
  const configModalMergeButton = document.getElementById('config-modal-merge');
  const configModalClose = document.getElementById('config-modal-close');

  const servers = [];
  let isLoadingConfig = false;
  let currentConfig = null;
  let currentConfigFileName = '';
  let activeToolContext = null;
  let previousBodyOverflow = '';
  let activeConfigFormat = null;
  let activeConfigServerName = null;

  function escapeHtml(value) {
    if (value === null || value === undefined) return '';
    return String(value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function escapeAttribute(value) {
    return escapeHtml(value);
  }

  function sanitizeKey(value) {
    return String(value).replace(/[^a-zA-Z0-9_-]/g, '-');
  }

  function sanitizeFilenameSegment(value) {
    return String(value)
      .trim()
      .replace(/\s+/g, '_')
      .replace(/[^a-zA-Z0-9_-]/g, '');
  }

  function toISOStringWithTZ(date) {
    return date.toISOString();
  }

  function formatTimestampForFilename(date) {
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    const hours = String(date.getHours()).padStart(2, '0');
    const minutes = String(date.getMinutes()).padStart(2, '0');
    const seconds = String(date.getSeconds()).padStart(2, '0');
    return `${year}${month}${day}_${hours}${minutes}${seconds}`;
  }

  function formatDuration(ms) {
    if (!Number.isFinite(ms)) return 'n/a';
    const seconds = ms / 1000;
    if (seconds < 1) {
      return `${ms.toFixed(0)} ms`;
    }
    if (seconds < 60) {
      return `${seconds.toFixed(2)} s`;
    }
    const minutes = Math.floor(seconds / 60);
    const remaining = seconds % 60;
    return `${minutes}m ${remaining.toFixed(1)}s`;
  }

  function downloadTextFile(filename, content, mime = 'text/plain;charset=utf-8') {
    const blob = new Blob([content], { type: mime });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);
  }

  function formatAsCodeBlock(value, fallbackLanguage = 'json') {
    let language = fallbackLanguage;
    let text;
    if (value === undefined || value === null) {
      text = '{}';
    } else if (typeof value === 'string') {
      try {
        const parsed = JSON.parse(value);
        text = JSON.stringify(parsed, null, 2);
      } catch (_err) {
        language = '';
        text = value;
      }
    } else {
      try {
        text = JSON.stringify(value, null, 2);
      } catch (_err) {
        language = '';
        text = String(value);
      }
    }
    return `\`\`\`${language}\n${text}\n\`\`\``;
  }

  function updateSaveButtons() {
    const disabled = !currentConfig || isLoadingConfig;
    saveJsonButton.disabled = disabled;
    saveTomlButton.disabled = disabled;
  }

  function setLoadingConfig(state) {
    isLoadingConfig = state;
    loadJsonButton.disabled = state;
    loadTomlButton.disabled = state;
    if (configModal.classList.contains('hidden')) {
      addJsonServerButton.disabled = state;
      addTomlServerButton.disabled = state;
    } else {
      addJsonServerButton.disabled = true;
      addTomlServerButton.disabled = true;
    }
    updateSaveButtons();
  }

  function describeConfigStatus(fileName, format, count) {
    const parts = [];
    if (fileName) {
      parts.push(fileName);
    } else {
      parts.push('Loaded config');
    }
    if (typeof count === 'number') {
      parts.push(`${count} server${count === 1 ? '' : 's'}`);
    }
    if (format) {
      parts.push(format.toUpperCase());
    }
    return parts.join(' • ');
  }

  function refreshConfigStatusLabel() {
    if (currentConfig) {
      const count = Array.isArray(currentConfig.servers) ? currentConfig.servers.length : 0;
      configFileNameLabel.textContent = describeConfigStatus(currentConfigFileName, currentConfig.format, count);
    } else {
      configFileNameLabel.textContent = 'No file selected';
    }
  }

  function setCurrentConfig(configObj, fileName) {
    currentConfig = configObj ? JSON.parse(JSON.stringify(configObj)) : null;
    if (fileName !== undefined) {
      currentConfigFileName = fileName || '';
    }
    updateSaveButtons();
    refreshConfigStatusLabel();
  }

  function clearCurrentConfigStatus(message = 'No file selected') {
    currentConfig = null;
    currentConfigFileName = '';
    configFileNameLabel.textContent = message;
    updateSaveButtons();
  }

  function replaceConfigServers(configObj, serverResults, fileName, expansionOverride) {
    const label = fileName ?? currentConfigFileName ?? '';
    setCurrentConfig(configObj, label);
    const expansionMap = new Map();
    servers.forEach((srv) => {
      if (srv.source === 'config' && srv.serverName) {
        expansionMap.set(srv.serverName, Boolean(srv._expanded));
      }
    });
    if (expansionOverride) {
      expansionOverride.forEach((value, key) => {
        expansionMap.set(key, Boolean(value));
      });
    }
    for (let i = servers.length - 1; i >= 0; i -= 1) {
      if (servers[i].source === 'config') {
        servers.splice(i, 1);
      }
    }
    const baseId = Date.now();
    (serverResults || []).forEach((item, index) => {
      const spec = item.spec ? JSON.parse(JSON.stringify(item.spec)) : {};
      const result = item.result ? JSON.parse(JSON.stringify(item.result)) : {};
      const status = result.ok ? 'ok' : 'error';
      const handshake = result.handshake ?? null;
      const displayName = computeDisplayName(spec, item.name);
      const configSnippets = item.configSnippets || {};
      const defaultFormat = configSnippets.json ? 'json' : configSnippets.toml ? 'toml' : null;
      const expanded = expansionMap.has(item.name) ? expansionMap.get(item.name) : false;
      servers.push({
        id: baseId + index,
        source: 'config',
        serverName: item.name,
        name: item.name,
        displayName,
        spec,
        status,
        result: result.ok ? result : null,
        error: result.ok ? null : result.error,
        handshake,
        toolTests: {},
        configSnippets,
        configSnippetFormat: defaultFormat,
        configSnippetEditing: false,
        configSnippetValue: configSnippets[defaultFormat] ?? '',
        configSnippet: item.configSnippet ?? null,
        configFormat: item.configFormat ?? configObj?.format ?? null,
        configEntry: item.configEntry ? JSON.parse(JSON.stringify(item.configEntry)) : null,
        _expanded: expanded
      });
    });
    refreshConfigStatusLabel();
    renderServers();
  }

  function computeDisplayName(spec, fallbackName) {
    if (spec.mode === 'http') {
      return (spec.url || fallbackName || '').trim() || fallbackName || 'HTTP server';
    }
    const command = spec.command || fallbackName || '';
    const args = Array.isArray(spec.args) && spec.args.length ? ` ${spec.args.join(' ')}` : '';
    const combined = `${command}${args}`.trim();
    return combined || fallbackName || 'STDIO server';
  }

  function buildConfigSnippet(entry) {
    const snippets = entry.configSnippets || {};
    const formats = [];
    if (snippets.json) formats.push('json');
    if (snippets.toml) formats.push('toml');
    if (!formats.length) {
      return '';
    }
    if (!entry.configSnippetFormat || !formats.includes(entry.configSnippetFormat)) {
      entry.configSnippetFormat = formats[0];
    }
    const format = entry.configSnippetFormat;
    const editing = Boolean(entry.configSnippetEditing);
    const currentSnippet = editing
      ? entry.configSnippetValue ?? snippets[format] ?? ''
      : snippets[format] ?? '';

    const formatButtons = formats
      .map((fmt) => {
        const isActive = fmt === format;
        const disabled = editing || !snippets[fmt];
        return `<button type="button" class="config-button config-format-button${isActive ? ' active' : ''}" data-entry-id="${entry.id}" data-config-action="format" data-config-format="${fmt}"${disabled ? ' disabled' : ''}>${fmt.toUpperCase()}</button>`;
      })
      .join('');

    const editButtonLabel = editing ? 'Update' : 'Edit';
    const editAction = editing ? 'update' : 'edit';
    const editButton = `<button type="button" class="config-button" data-entry-id="${entry.id}" data-config-action="${editAction}">${editButtonLabel}</button>`;
    const cancelButton = editing
      ? `<button type="button" class="config-button secondary" data-entry-id="${entry.id}" data-config-action="cancel">Cancel</button>`
      : '';
    const removeButton = `<button type="button" class="config-button danger" data-entry-id="${entry.id}" data-config-action="remove">Remove</button>`;

    const body = editing
      ? `<textarea class="config-snippet-textarea" data-entry-id="${entry.id}" spellcheck="false">${escapeHtml(currentSnippet)}</textarea>`
      : `<pre>${escapeHtml(currentSnippet)}</pre>`;

    return `
      <div class="config-snippet">
        <div class="config-snippet-header">
          <strong>Config Snippet</strong>
          <div class="config-snippet-actions">
            <div class="config-format-group">${formatButtons}</div>
            ${editButton}
            ${cancelButton}
            ${removeButton}
          </div>
        </div>
        <div class="config-snippet-body">${body}</div>
      </div>
    `;
  }

  function generateToolReport(reportData) {
    const {
      serverName,
      toolName,
      spec,
      args,
      startedAt,
      finishedAt,
      durationMs,
      success,
      response,
      error,
      handshake
    } = reportData;
    const lines = [];
    lines.push('# MCP Tool Call Report');
    lines.push('');
    lines.push(`- **Server Name:** ${serverName}`);
    lines.push(`- **Tool:** ${toolName}`);
    lines.push(`- **Mode:** ${spec?.mode ?? 'unknown'}`);
    lines.push(`- **Call Started:** ${startedAt}`);
    lines.push(`- **Response Received:** ${finishedAt}`);
    const hasDuration = typeof durationMs === 'number' && Number.isFinite(durationMs);
    const durationDisplay = hasDuration ? formatDuration(durationMs) : 'n/a';
    const durationExact = hasDuration ? `${durationMs.toFixed(0)} ms` : 'n/a';
    lines.push(`- **Duration:** ${durationDisplay}${hasDuration ? ` (${durationExact})` : ''}`);
    lines.push(`- **Result:** ${success ? 'Success' : 'Failure'}`);
    lines.push('');
    if (handshake) {
      lines.push('## Handshake');
      const summary = {
        transport: handshake.transport ?? null,
        protocolVersion: handshake.protocolVersion ?? null,
        serverInfo: handshake.serverInfo ?? null,
        capabilities: handshake.capabilities ?? null,
        instructions: handshake.instructions ?? null
      };
      lines.push(formatAsCodeBlock(summary));
      lines.push('');
    }
    lines.push('## Server Configuration');
    lines.push(formatAsCodeBlock(spec));
    lines.push('');
    lines.push('## Tool Arguments');
    lines.push(formatAsCodeBlock(args ?? {}));
    lines.push('');
    lines.push('## Output');
    if (success) {
      lines.push(formatAsCodeBlock(response ?? {}));
    } else {
      const errorBlock = {
        kind: error?.kind ?? 'unknown',
        advice: error?.advice ?? null,
        details: error?.details ?? error ?? null
      };
      lines.push(formatAsCodeBlock(errorBlock));
    }
    return lines.join('\n');
  }

  function parseCommandLine(line) {
    const regex = /(["'])(?:(?=\\?)\\?.)*?\1|[^\s]+/g;
    const matches = line.match(regex);
    if (!matches) return [];
    return matches.map((token) => {
      if ((token.startsWith('"') && token.endsWith('"')) || (token.startsWith("'") && token.endsWith("'"))) {
        return token.slice(1, -1);
      }
      return token;
    });
  }

  function updateFormVisibility() {
    if (modeSelect.value === 'http') {
      httpRow.classList.remove('hidden');
      stdioRow.classList.add('hidden');
    } else {
      httpRow.classList.add('hidden');
      stdioRow.classList.remove('hidden');
    }
  }

  function stringifyValue(value) {
    if (value === null || value === undefined) return '';
    if (typeof value === 'string') return value;
    try {
      return JSON.stringify(value, null, 2);
    } catch (err) {
      return String(value);
    }
  }

  function extractToolArguments(inputSchema) {
    if (!inputSchema || typeof inputSchema !== 'object') return [];
    const schemaType = inputSchema.type;
    if (schemaType && schemaType !== 'object') return [];
    const properties =
      inputSchema.properties && typeof inputSchema.properties === 'object' ? inputSchema.properties : {};
    const required = new Set(Array.isArray(inputSchema.required) ? inputSchema.required : []);
    return Object.entries(properties).map(([name, schema]) => {
      const entry = schema && typeof schema === 'object' ? schema : {};
      const type = typeof entry.type === 'string' ? entry.type : 'any';
      return {
        name,
        required: required.has(name),
        schema: entry,
        type,
        description: typeof entry.description === 'string' ? entry.description : '',
        enum: Array.isArray(entry.enum) ? entry.enum : undefined
      };
    });
  }

  function formatSpecMeta(entry) {
    if (!entry?.spec) return '';
    let base = '';
    if (entry.spec.mode === 'http') {
      base = `HTTP • ${entry.spec.url ?? ''}`;
    } else if (entry.spec.mode === 'stdio') {
      const args = Array.isArray(entry.spec.args) && entry.spec.args.length ? ` ${entry.spec.args.join(' ')}` : '';
      base = `STDIO • ${entry.spec.command ?? ''}${args}`;
    }
    if (entry.source === 'config') {
      base += ' • from config';
    }
    return base.trim();
  }

  function buildHandshakeBlock(handshake) {
    if (!handshake) {
      return '';
    }
    const protocol = handshake.protocolVersion ? `<code>${escapeHtml(handshake.protocolVersion)}</code>` : 'negotiated';
    const serverInfo = handshake.serverInfo ?? {};
    const serverName = serverInfo.name ? escapeHtml(serverInfo.name) : 'Unknown server';
    const serverVersion = serverInfo.version ? ` (${escapeHtml(serverInfo.version)})` : '';
    const serverDescription = serverInfo.description ? ` — ${escapeHtml(serverInfo.description)}` : '';
    let html = '<div class="detail-block"><strong>Handshake</strong><ul>';
    html += `<li>Protocol: ${protocol}</li>`;
    html += `<li>Server: ${serverName}${serverVersion}${serverDescription}</li>`;
    html += '</ul>';
    if (handshake.instructions !== undefined && handshake.instructions !== null) {
      html += '<em>Instructions</em>';
      html += `<pre>${escapeHtml(stringifyValue(handshake.instructions))}</pre>`;
    }
    if (handshake.capabilities) {
      html += '<em>Capabilities</em>';
      html += `<pre>${escapeHtml(stringifyValue(handshake.capabilities))}</pre>`;
    }
    html += '</div>';
    return html;
  }

  function renderToolTestStatus(state) {
    if (!state) return '';
    const statusClass = state.status || 'pending';
    let label = 'Testing';
    if (statusClass === 'ok') label = 'Success';
    if (statusClass === 'error') label = 'Failed';
    return `<span class="tool-test-status ${statusClass}">${escapeHtml(label)}</span>`;
  }

  function buildToolResult(state) {
    if (!state) return '';
    if (state.status === 'ok') {
      return `<pre class="tool-output">${escapeHtml(stringifyValue(state.output ?? {}))}</pre>`;
    }
    if (state.status === 'error' && state.error) {
      const lines = [];
      if (state.error.kind) lines.push(`kind: ${state.error.kind}`);
      if (state.error.advice) lines.push(`advice: ${state.error.advice}`);
      if (state.error.details !== undefined) {
        lines.push(`details: ${stringifyValue(state.error.details)}`);
      }
      if (!lines.length) {
        lines.push(stringifyValue(state.error));
      }
      return `<pre class="tool-output">${escapeHtml(lines.join('\n'))}</pre>`;
    }
    return '';
  }

  function buildToolsBlock(entry) {
    const tools = entry.result?.tools ?? [];
    const toolTests = entry.toolTests ?? {};
    let html = '<div class="detail-block"><strong>Tools</strong>';
    if (!tools.length) {
      html += '<div>No tools reported.</div></div>';
      return html;
    }
    html += '<ul>';
    tools.forEach((tool) => {
      const description = tool.description ? ` — ${escapeHtml(tool.description)}` : '';
      const testState = toolTests[tool.name];
      const statusBadge = renderToolTestStatus(testState);
      html += `<li><code>${escapeHtml(tool.name)}</code>${description}`;
      html += ` <button class="tool-test-button" type="button" data-tool="${escapeAttribute(
        tool.name
      )}" data-entry-id="${entry.id}">Test</button>`;
      if (statusBadge) {
        html += ` ${statusBadge}`;
      }
      const args = extractToolArguments(tool.inputSchema);
      if (args.length) {
        html += '<div class="tool-arguments"><em>Arguments</em><ul>';
        args.forEach((arg) => {
          const metaBits = [];
          if (arg.type) metaBits.push(arg.type);
          if (arg.required) metaBits.push('required');
          if (arg.enum && arg.enum.length) {
            metaBits.push(`enum: ${arg.enum.map((value) => String(value)).join(', ')}`);
          }
          const meta = metaBits.length ? `<span class="argument-meta">${escapeHtml(metaBits.join(' • '))}</span>` : '';
          const desc = arg.description ? ` — ${escapeHtml(arg.description)}` : '';
          html += `<li><code>${escapeHtml(arg.name)}</code>${meta}${desc}</li>`;
        });
        html += '</ul></div>';
      }
      html += buildToolResult(testState);
      html += '</li>';
    });
    html += '</ul></div>';
    return html;
  }

  function buildPromptsBlock(entry) {
    const prompts = entry.result?.prompts ?? [];
    let html = '<div class="detail-block"><strong>Prompts</strong>';
    if (!prompts.length) {
      html += '<div>None.</div></div>';
      return html;
    }
    html += '<ul>';
    prompts.forEach((prompt) => {
      const description = prompt.description ? ` — ${escapeHtml(prompt.description)}` : '';
      html += `<li><code>${escapeHtml(prompt.name)}</code>${description}</li>`;
    });
    html += '</ul></div>';
    return html;
  }

  function buildResourcesBlock(entry) {
    const resources = entry.result?.resources ?? [];
    let html = '<div class="detail-block"><strong>Resources</strong>';
    if (!resources.length) {
      html += '<div>None.</div></div>';
      return html;
    }
    html += '<ul>';
    resources.forEach((resource) => {
      const parts = [];
      if (resource.name) {
        parts.push(`<code>${escapeHtml(resource.name)}</code>`);
      }
      if (resource.uri) {
        parts.push(`(${escapeHtml(resource.uri)})`);
      }
      if (resource.description) {
        parts.push(`— ${escapeHtml(resource.description)}`);
      }
      html += `<li>${parts.join(' ')}</li>`;
    });
    html += '</ul></div>';
    return html;
  }

  function buildErrorBlock(entry) {
    const error = entry.error ?? { kind: 'unknown' };
    let html = '<div class="detail-block"><strong>Error</strong><ul>';
    html += `<li>Kind: ${escapeHtml(error.kind ?? 'unknown')}</li>`;
    if (error.advice) {
      html += `<li>Advice: ${escapeHtml(error.advice)}</li>`;
    }
    html += '</ul>';
    if (error.details !== undefined && error.details !== null) {
      html += `<pre>${escapeHtml(stringifyValue(error.details))}</pre>`;
    }
    html += '</div>';
    return html;
  }

  function renderServers() {
    serversList.innerHTML = '';
    if (!servers.length) {
      const emptyMessage = document.createElement('div');
      emptyMessage.className = 'server-summary';
      emptyMessage.textContent = 'No servers diagnosed yet.';
      serversList.appendChild(emptyMessage);
      return;
    }
  servers.forEach((entry) => {
    const node = template.content.cloneNode(true);
    const card = node.querySelector('.server-card');
    const statusDot = node.querySelector('.status-dot');
    const nameSpan = node.querySelector('.server-name');
      const metaSpan = node.querySelector('.server-meta');
      const summaryDiv = node.querySelector('.server-summary');
      const detailsDiv = node.querySelector('.server-details');
      const toggleBtn = node.querySelector('.toggle-details');

    card.dataset.entryId = entry.id;

    nameSpan.textContent = entry.serverName ? entry.serverName : entry.displayName;
      metaSpan.textContent = formatSpecMeta(entry);

      if (entry.status === 'pending') {
        statusDot.style.backgroundColor = '#d69e2e';
        summaryDiv.textContent = 'Checking…';
      } else if (entry.status === 'ok') {
        statusDot.classList.add('ok');
        const toolsCount = entry.result?.tools?.length ?? 0;
        const protocolVersion = entry.handshake?.protocolVersion ?? 'negotiated';
        summaryDiv.textContent = `${toolsCount} tools • protocol ${protocolVersion}`;
      } else {
        statusDot.classList.add('error');
        const kind = entry.error?.kind ? entry.error.kind.replace(/_/g, ' ') : 'error';
        summaryDiv.innerHTML = `<span class="error-message">${escapeHtml(kind)}</span>`;
      }

      const detailSections = [];
      if (entry.source === 'config') {
        detailSections.push(buildConfigSnippet(entry));
      }
      if (entry.handshake) {
        detailSections.push(buildHandshakeBlock(entry.handshake));
      }
      if (entry.status === 'ok') {
        detailSections.push(buildToolsBlock(entry));
        detailSections.push(buildPromptsBlock(entry));
        detailSections.push(buildResourcesBlock(entry));
      } else if (entry.status === 'error') {
        detailSections.push(buildErrorBlock(entry));
      }

      detailsDiv.innerHTML = detailSections.filter(Boolean).join('');

      const shouldExpand = Boolean(entry._expanded);
      toggleBtn.classList.toggle('open', shouldExpand);
      detailsDiv.classList.toggle('hidden', !shouldExpand);

      toggleBtn.addEventListener('click', () => {
        const isOpen = toggleBtn.classList.toggle('open');
        detailsDiv.classList.toggle('hidden', !isOpen);
        entry._expanded = isOpen;
      });

      serversList.appendChild(card);
    });
  }

  serversList.addEventListener('click', (event) => {
    const button = event.target.closest('button');
    if (!button) {
      return;
    }
    if (button.disabled) {
      return;
    }
    const entryId = Number(button.dataset.entryId);
    const entry = Number.isFinite(entryId) ? servers.find((item) => item.id === entryId) : null;

    if (button.classList.contains('tool-test-button')) {
      if (!entry) {
        alert('Unable to locate server entry for this tool.');
        return;
      }
      const toolName = button.dataset.tool;
      if (!toolName) {
        alert('Unable to determine tool name for this button.');
        return;
      }
      openToolModal(entry, toolName);
      return;
    }

    const action = button.dataset.configAction;
    if (!action || !entry) {
      return;
    }
    switch (action) {
      case 'format': {
        const newFormat = button.dataset.configFormat;
        if (!newFormat || newFormat === entry.configSnippetFormat) {
          return;
        }
        entry.configSnippetFormat = newFormat;
        entry.configSnippetEditing = false;
        entry.configSnippetValue = entry.configSnippets?.[newFormat] ?? '';
        entry._expanded = entry._expanded !== false;
        renderServers();
        break;
      }
      case 'edit': {
        entry.configSnippetEditing = true;
        entry.configSnippetValue = entry.configSnippets?.[entry.configSnippetFormat] ?? '';
        entry._expanded = true;
        renderServers();
        break;
      }
      case 'cancel': {
        entry.configSnippetEditing = false;
        entry.configSnippetValue = entry.configSnippets?.[entry.configSnippetFormat] ?? '';
        renderServers();
        break;
      }
      case 'update': {
        if (!currentConfig) {
          alert('Load a configuration before editing servers.');
          return;
        }
        if (!entry.configSnippetFormat) {
          alert('No format selected for this server snippet.');
          return;
        }
        const snippetContainer = button.closest('.config-snippet');
        const textarea = snippetContainer ? snippetContainer.querySelector('.config-snippet-textarea') : null;
        const newValue = textarea ? textarea.value : entry.configSnippets?.[entry.configSnippetFormat] ?? '';
        entry.configSnippetValue = newValue;
        entry.configSnippetEditing = true;
        entry._expanded = true;
        void saveServerSnippet(entry, entry.configSnippetFormat, newValue);
        break;
      }
      case 'remove': {
        void handleRemoveServer(entry);
        break;
      }
      default:
        break;
    }
  });

  async function handleRemoveServer(entry) {
    if (!currentConfig) {
      alert('Load a configuration before removing servers.');
      return;
    }
    const name = entry.serverName || entry.name || '(unnamed)';
    const confirmed = window.confirm(`Remove server "${name}" from the configuration?`);
    if (!confirmed) {
      return;
    }
    try {
      setLoadingConfig(true);
      configFileNameLabel.textContent = `Removing ${name}…`;
      const response = await fetch('/api/config/remove-server', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ baseConfig: currentConfig, serverName: name })
      });
      const data = await response.json();
      if (!response.ok || data.ok === false) {
        const message = data?.error?.details || `Unable to remove server (HTTP ${response.status})`;
        throw new Error(message);
      }
      const label = currentConfigFileName || (currentConfig?.format === 'toml' ? 'config.toml' : 'mcp.json');
      replaceConfigServers(data.config, data.servers || [], label);
    } catch (err) {
      alert(`Failed to remove server: ${err.message}`);
      refreshConfigStatusLabel();
    } finally {
      setLoadingConfig(false);
    }
  }

  async function saveServerSnippet(entry, format, snippet) {
    const trimmed = snippet.trim();
    if (!trimmed) {
      alert('Configuration snippet cannot be empty.');
      return;
    }
    const name = entry.serverName || entry.name || '(unnamed)';
    try {
      setLoadingConfig(true);
      configFileNameLabel.textContent = `Updating ${name}…`;
      const response = await fetch('/api/config/add-server', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ baseConfig: currentConfig, additionText: trimmed, additionFormat: format })
      });
      const data = await response.json();
      if (!response.ok || data.ok === false) {
        const message = data?.error?.details || `Unable to update server (HTTP ${response.status})`;
        throw new Error(message);
      }
      const label = currentConfigFileName || (format === 'toml' ? 'config.toml' : 'mcp.json');
      replaceConfigServers(data.config, data.servers || [], label, new Map([[name, true]]));
      const updatedEntry = servers.find((item) => item.serverName === name && item.source === 'config');
      if (updatedEntry) {
        updatedEntry.configSnippetEditing = false;
        updatedEntry.configSnippetFormat = format;
        updatedEntry.configSnippetValue = updatedEntry.configSnippets?.[format] ?? snippet;
        updatedEntry._expanded = true;
      }
      renderServers();
    } catch (err) {
      alert(`Failed to update server: ${err.message}`);
      const updatedEntry = servers.find((item) => item.serverName === name && item.source === 'config');
      if (updatedEntry) {
        updatedEntry.configSnippetEditing = true;
        updatedEntry.configSnippetValue = snippet;
        updatedEntry._expanded = true;
        renderServers();
      }
      refreshConfigStatusLabel();
    } finally {
      setLoadingConfig(false);
    }
  }

  function applyLastArgs(context) {
    const lastArgs = context.lastArgs ?? {};
    if (context.argSpecs.length) {
      context.argSpecs.forEach((spec) => {
        const field = document.getElementById(spec.inputId);
        if (!field) return;
        const value = lastArgs[spec.name];
        if (value === undefined) return;

        const type = spec.schema?.type;
        if (spec.enum && spec.enum.length) {
          const idx = spec.enum.findIndex((item) => Object.is(item, value));
          field.value = idx >= 0 ? String(idx) : '';
        } else if (type === 'boolean') {
          field.value = value === true ? 'true' : value === false ? 'false' : '';
        } else if (type === 'number' || type === 'integer') {
          field.value = value;
        } else if (type === 'array' || type === 'object' || typeof value === 'object') {
          field.value = stringifyValue(value);
        } else {
          field.value = value;
        }
      });
    } else {
      const textArea = document.getElementById('tool-args-json');
      if (textArea) {
        textArea.value = Object.keys(lastArgs).length ? stringifyValue(lastArgs) : '';
      }
    }
  }

  function renderArgumentFields(context) {
    const container = document.getElementById('tool-modal-form');
    if (!container) return;
    if (context.argSpecs.length) {
      let html = '<p class="modal-note">Provide arguments below. Leave optional fields empty to omit them.</p>';
      context.argSpecs.forEach((spec) => {
        const label = escapeHtml(spec.name);
        const description = spec.description ? `<p class="modal-note">${escapeHtml(spec.description)}</p>` : '';
        html += `<div class="modal-field"><label class="modal-label" for="${spec.inputId}">${label}`;
        if (spec.required) {
          html += '<span class="required">*</span>';
        }
        html += '</label>';

        const type = spec.schema?.type;
        if (spec.enum && spec.enum.length) {
          html += `<select class="modal-select" id="${spec.inputId}" data-arg-name="${escapeAttribute(
            spec.name
          )}" data-arg-type="enum">`;
          if (!spec.required) {
            html += '<option value="">(not set)</option>';
          }
          spec.enum.forEach((value, idx) => {
            const optionLabel = String(value);
            html += `<option value="${idx}">${escapeHtml(optionLabel)}</option>`;
          });
          html += '</select>';
        } else if (type === 'boolean') {
          html += `<select class="modal-select" id="${spec.inputId}" data-arg-name="${escapeAttribute(
            spec.name
          )}" data-arg-type="boolean">`;
          if (!spec.required) {
            html += '<option value="">(not set)</option>';
          }
          html += '<option value="true">true</option>';
          html += '<option value="false">false</option>';
          html += '</select>';
        } else if (type === 'number' || type === 'integer') {
          const step = type === 'integer' ? '1' : 'any';
          html += `<input type="number" class="modal-input" id="${spec.inputId}" data-arg-name="${escapeAttribute(
            spec.name
          )}" data-arg-type="${type}" step="${step}" />`;
        } else if (type === 'array' || type === 'object' || !type) {
          html += `<textarea class="modal-textarea" id="${spec.inputId}" data-arg-name="${escapeAttribute(
            spec.name
          )}" data-arg-type="${type || 'json'}" placeholder="JSON value"></textarea>`;
        } else {
          html += `<input type="text" class="modal-input" id="${spec.inputId}" data-arg-name="${escapeAttribute(
            spec.name
          )}" data-arg-type="${type}" />`;
        }
        html += description;
        html += '</div>';
      });
      container.innerHTML = html;
    } else {
      container.innerHTML = `
        <p class="modal-note">This tool did not declare arguments. Submit to run it with an empty object, or provide custom JSON if needed.</p>
        <textarea class="modal-textarea" id="tool-args-json" placeholder="{ }"></textarea>
      `;
    }
    applyLastArgs(context);
  }

  function setModalResult(payload) {
    const container = document.getElementById('tool-modal-result');
    if (!container) return;
    if (!payload) {
      container.classList.add('hidden');
      container.innerHTML = '';
      return;
    }

    container.classList.remove('hidden');
    if (payload.ok) {
      container.innerHTML =
        '<div class="result-status">Tool executed successfully.</div>' +
        `<pre>${escapeHtml(stringifyValue(payload.output ?? {}))}</pre>`;
    } else {
      const error = payload.error ?? {};
      const lines = [];
      if (error.kind) lines.push(`kind: ${error.kind}`);
      if (error.advice) lines.push(`advice: ${error.advice}`);
      if (error.details !== undefined) lines.push(`details: ${stringifyValue(error.details)}`);
      if (!lines.length) {
        lines.push('Execution failed.');
      }
      container.innerHTML =
        '<div class="result-status">Tool execution failed.</div>' + `<pre>${escapeHtml(lines.join('\n'))}</pre>`;
    }
  }

  function closeToolModal() {
    if (toolModal.classList.contains('hidden')) {
      return;
    }
    activeToolContext = null;
    toolModal.classList.add('hidden');
    modalBackdrop.classList.add('hidden');
    toolModalBody.innerHTML = '';
    toolModalSubmit.disabled = false;
    toolModalSubmit.textContent = 'Run Tool';
    toolModalReport.disabled = true;
    setModalResult(null);
    document.body.style.overflow = previousBodyOverflow;
  }

  function renderToolModalContent(context) {
    toolModalTitle.textContent = `Test ${context.tool.name}`;
    const description = context.tool.description
      ? escapeHtml(context.tool.description)
      : 'No description provided.';
    toolModalBody.innerHTML = `
      <p class="modal-tool-desc">${description}</p>
      <div class="modal-form" id="tool-modal-form"></div>
      <div class="modal-result hidden" id="tool-modal-result"></div>
    `;
    toolModalReport.disabled = true;
    renderArgumentFields(context);
    setModalResult(null);
  }

  function openToolModal(entry, toolName) {
    if (!entry?.result?.tools) {
      alert('No tool information available for this server.');
      return;
    }
    const tool = entry.result.tools.find((t) => t.name === toolName);
    if (!tool) {
      alert(`Tool "${toolName}" not found on this server.`);
      return;
    }
    const argSpecs = extractToolArguments(tool.inputSchema).map((spec) => ({
      ...spec,
      inputId: `tool-arg-${entry.id}-${sanitizeKey(tool.name)}-${sanitizeKey(spec.name)}`
    }));
    const lastArgs = entry.toolTests?.[tool.name]?.lastArgs ?? {};
    activeToolContext = {
      entry,
      tool,
      argSpecs,
      lastArgs: { ...lastArgs },
      reportData: null
    };
    renderToolModalContent(activeToolContext);
    const previous = entry.toolTests?.[tool.name];
    if (previous) {
      if (previous.totalResult) {
        setModalResult(previous.totalResult);
        toolModalReport.disabled = !previous.reportData;
      }
      if (previous.reportData) {
        activeToolContext.reportData = previous.reportData;
        toolModalReport.disabled = false;
      }
    }
    previousBodyOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    modalBackdrop.classList.remove('hidden');
    toolModal.classList.remove('hidden');
  }

  function gatherArgumentsFromModal() {
    if (!activeToolContext) return null;
    const context = activeToolContext;
    if (context.argSpecs.length) {
      const args = {};
      for (const spec of context.argSpecs) {
        const field = document.getElementById(spec.inputId);
        if (!field) continue;
        const rawValue = field.value;
        const trimmed = typeof rawValue === 'string' ? rawValue.trim() : rawValue;
        if (!trimmed && spec.required) {
          alert(`Argument "${spec.name}" is required.`);
          field.focus();
          return null;
        }
        if (!trimmed) {
          continue;
        }
        const type = spec.schema?.type;
        let value;
        try {
          if (spec.enum && spec.enum.length) {
            if (rawValue === '') {
              continue;
            }
            const idx = Number(rawValue);
            if (!Number.isInteger(idx) || idx < 0 || idx >= spec.enum.length) {
              throw new Error('Invalid choice.');
            }
            value = spec.enum[idx];
          } else if (type === 'boolean') {
            if (rawValue === 'true' || rawValue === true) {
              value = true;
            } else if (rawValue === 'false' || rawValue === false) {
              value = false;
            } else {
              throw new Error('Expected boolean value.');
            }
          } else if (type === 'number' || type === 'integer') {
            const num = Number(trimmed);
            if (Number.isNaN(num)) {
              throw new Error('Expected numeric value.');
            }
            value = type === 'integer' ? Math.trunc(num) : num;
          } else if (type === 'array' || type === 'object' || !type) {
            value = JSON.parse(rawValue);
          } else {
            value = rawValue;
          }
        } catch (err) {
          alert(`Unable to parse argument "${spec.name}": ${err.message}`);
          field.focus();
          return null;
        }
        args[spec.name] = value;
      }
      return args;
    }
    const textArea = document.getElementById('tool-args-json');
    const raw = textArea ? textArea.value.trim() : '';
    if (!raw) return {};
    try {
      const parsed = JSON.parse(raw);
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
        throw new Error('JSON must describe an object.');
      }
      return parsed;
    } catch (err) {
      alert(`Unable to parse JSON arguments: ${err.message}`);
      textArea?.focus();
      return null;
    }
  }

  async function submitToolModal() {
    if (!activeToolContext) {
      return;
    }
    const args = gatherArgumentsFromModal();
    if (args === null) {
      return;
    }
    const { entry, tool } = activeToolContext;
    const startedAtDate = new Date();
    const startedAtIso = toISOStringWithTZ(startedAtDate);
    toolModalSubmit.disabled = true;
    toolModalSubmit.textContent = 'Running…';
    const runningContainer = document.getElementById('tool-modal-result');
    if (runningContainer) {
      runningContainer.classList.remove('hidden');
      runningContainer.innerHTML = '<div class="result-status">Running…</div>';
    }

    try {
      const response = await fetch('/api/tools/call', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ spec: entry.spec, toolName: tool.name, toolArgs: args })
      });
      const data = await response.json();
      const finishedAtDate = new Date();
      const finishedAtIso = toISOStringWithTZ(finishedAtDate);
      const durationMs = finishedAtDate.getTime() - startedAtDate.getTime();
      const handshakeInfo = data.handshake ?? entry.handshake;
      if (!response.ok) {
        throw new Error(data?.error?.details || `HTTP ${response.status}`);
      }
      if (!entry.toolTests) {
        entry.toolTests = {};
      }
      if (data.ok) {
        entry.toolTests[tool.name] = { status: 'ok', output: data.output, lastArgs: args };
        activeToolContext.lastArgs = args;
        const resultPayload = { ok: true, output: data.output };
        setModalResult(resultPayload);
        const reportData = {
          serverName: entry.serverName || entry.displayName || 'unknown',
          toolName: tool.name,
          spec: JSON.parse(JSON.stringify(entry.spec ?? {})),
          args,
          startedAt: startedAtIso,
          finishedAt: finishedAtIso,
          durationMs,
          success: true,
          response: data.output,
          error: null,
          handshake: handshakeInfo
        };
        entry.toolTests[tool.name].reportData = reportData;
        entry.toolTests[tool.name].totalResult = resultPayload;
        entry.toolTests[tool.name].startedAt = startedAtIso;
        entry.toolTests[tool.name].finishedAt = finishedAtIso;
        entry.toolTests[tool.name].durationMs = durationMs;
        activeToolContext.reportData = reportData;
        toolModalReport.disabled = false;
      } else {
        entry.toolTests[tool.name] = {
          status: 'error',
          error: data.error ?? { kind: 'tool_error', details: 'Unknown error' },
          lastArgs: args
        };
        activeToolContext.lastArgs = args;
        const resultPayload = { ok: false, error: data.error };
        setModalResult(resultPayload);
        const reportData = {
          serverName: entry.serverName || entry.displayName || 'unknown',
          toolName: tool.name,
          spec: JSON.parse(JSON.stringify(entry.spec ?? {})),
          args,
          startedAt: startedAtIso,
          finishedAt: finishedAtIso,
          durationMs,
          success: false,
          response: null,
          error: data.error,
          handshake: handshakeInfo
        };
        entry.toolTests[tool.name].reportData = reportData;
        entry.toolTests[tool.name].totalResult = resultPayload;
        entry.toolTests[tool.name].startedAt = startedAtIso;
        entry.toolTests[tool.name].finishedAt = finishedAtIso;
        entry.toolTests[tool.name].durationMs = durationMs;
        activeToolContext.reportData = reportData;
        toolModalReport.disabled = false;
      }
      renderServers();
    } catch (err) {
      const finishedAtDate = new Date();
      const finishedAtIso = toISOStringWithTZ(finishedAtDate);
      const durationMs = finishedAtDate.getTime() - startedAtDate.getTime();
      entry.toolTests = entry.toolTests || {};
      entry.toolTests[tool.name] = {
        status: 'error',
        error: { kind: 'network_error', details: err.message },
        lastArgs: args
      };
      activeToolContext.lastArgs = args;
      const resultPayload = { ok: false, error: { kind: 'network_error', details: err.message } };
      setModalResult(resultPayload);
      const reportData = {
        serverName: entry.serverName || entry.displayName || 'unknown',
        toolName: tool.name,
        spec: JSON.parse(JSON.stringify(entry.spec ?? {})),
        args,
        startedAt: startedAtIso,
        finishedAt: finishedAtIso,
        durationMs,
        success: false,
        response: null,
        error: { kind: 'network_error', details: err.message },
        handshake: entry.handshake
      };
      entry.toolTests[tool.name].reportData = reportData;
      entry.toolTests[tool.name].totalResult = resultPayload;
      entry.toolTests[tool.name].startedAt = startedAtIso;
      entry.toolTests[tool.name].finishedAt = finishedAtIso;
      entry.toolTests[tool.name].durationMs = durationMs;
      activeToolContext.reportData = reportData;
      toolModalReport.disabled = false;
      renderServers();
    } finally {
      toolModalSubmit.disabled = false;
      toolModalSubmit.textContent = 'Run Tool';
    }
  }

  async function diagnoseConfigContent(text, fileName, format) {
    if (!text) return;
    setLoadingConfig(true);
    configFileNameLabel.textContent = `Loading ${fileName}…`;
    try {
      const response = await fetch('/api/config/diagnose', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ configText: text, configFormat: format })
      });
      const data = await response.json();
      if (!response.ok || data.ok === false) {
        const message = data?.error?.details || `Unable to diagnose config (HTTP ${response.status})`;
        throw new Error(message);
      }
      const configObj = data.config ?? { format: data.format, topLevel: {}, servers: [] };
      replaceConfigServers(configObj, data.servers || [], fileName);
    } catch (err) {
      alert(`Failed to process ${fileName}: ${err.message}`);
      clearCurrentConfigStatus(`${fileName} — failed`);
    } finally {
      setLoadingConfig(false);
      configJsonInput.value = '';
      configTomlInput.value = '';
    }
  }

  async function handleConfigFile(file, format) {
    if (!file) return;
    try {
      const text = await file.text();
      await diagnoseConfigContent(text, file.name, format);
    } catch (err) {
      alert(`Unable to read file: ${err.message}`);
      configFileNameLabel.textContent = `Failed to read ${file.name}`;
    }
  }

  async function exportCurrentConfig(targetFormat) {
    if (!currentConfig) {
      alert('Load a configuration before saving.');
      return;
    }
    try {
      const response = await fetch('/api/config/export', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ config: currentConfig, targetFormat })
      });
      const data = await response.json();
      if (!response.ok || data.ok === false) {
        const message = data?.error?.details || `Unable to export config (HTTP ${response.status})`;
        throw new Error(message);
      }
      const extension = targetFormat === 'json' ? 'json' : 'toml';
      const baseName =
        currentConfigFileName && currentConfigFileName.includes('.')
          ? currentConfigFileName.replace(/\.[^.]+$/, '')
          : currentConfigFileName || 'mcp-config';
      const mime = targetFormat === 'json' ? 'application/json;charset=utf-8' : 'text/plain;charset=utf-8';
      const filename = `${baseName}.${extension}`;
      downloadTextFile(filename, data.content, mime);
    } catch (err) {
      alert(`Failed to export config: ${err.message}`);
    }
  }

  function openConfigModal(format, snippet = '', serverName = null) {
    if (!toolModal.classList.contains('hidden')) {
      closeToolModal();
    }
    activeConfigFormat = format;
    activeConfigServerName = serverName;
    const isEdit = Boolean(serverName);
    configModalTitle.textContent = isEdit
      ? `Edit MCP Server: ${serverName}`
      : format === 'toml'
        ? 'Add MCP Server (TOML)'
        : 'Add MCP Server (JSON)';
    configModalDesc.textContent = isEdit
      ? 'Update the configuration snippet for this server. Submit to merge and re-diagnose.'
      : format === 'toml'
        ? 'Paste a TOML snippet that defines one or more [mcp_servers.*] tables to merge into the current configuration.'
        : 'Paste a JSON snippet containing an mcpServers object with one or more server definitions to merge into the current configuration.';
    configModalInput.value = snippet || '';
    configModalMergeButton.disabled = false;
    configModalMergeButton.textContent = isEdit ? 'Update' : 'Merge';
    addJsonServerButton.disabled = true;
    addTomlServerButton.disabled = true;
    if (modalBackdrop.classList.contains('hidden')) {
      previousBodyOverflow = document.body.style.overflow;
      document.body.style.overflow = 'hidden';
      modalBackdrop.classList.remove('hidden');
    }
    configModal.classList.remove('hidden');
    setTimeout(() => {
      configModalInput.focus({ preventScroll: true });
    }, 0);
  }

  function closeConfigModal() {
    if (configModal.classList.contains('hidden')) {
      return;
    }
    configModal.classList.add('hidden');
    activeConfigFormat = null;
    activeConfigServerName = null;
    configModalMergeButton.disabled = false;
    configModalMergeButton.textContent = 'Merge';
    configModalInput.value = '';
    if (!isLoadingConfig) {
      addJsonServerButton.disabled = false;
      addTomlServerButton.disabled = false;
    }
    if (toolModal.classList.contains('hidden')) {
      modalBackdrop.classList.add('hidden');
      document.body.style.overflow = previousBodyOverflow;
    }
  }

  async function performAddServer(format, snippet) {
    const trimmed = snippet.trim();
    if (!trimmed) {
      alert('No configuration provided.');
      return;
    }
    const baseConfigPayload = currentConfig ? JSON.parse(JSON.stringify(currentConfig)) : null;
    const previousLabel = configFileNameLabel.textContent;
    configModalMergeButton.disabled = true;
    const isEdit = Boolean(activeConfigServerName);
    configModalMergeButton.textContent = 'Merging…';
    try {
      setLoadingConfig(true);
      configFileNameLabel.textContent = 'Merging server configuration…';
      const response = await fetch('/api/config/add-server', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ baseConfig: baseConfigPayload, additionText: trimmed, additionFormat: format })
      });
      const data = await response.json();
      if (!response.ok || data.ok === false) {
        const message = data?.error?.details || `Unable to add server (HTTP ${response.status})`;
        throw new Error(message);
      }
      const label = currentConfigFileName || (format === 'toml' ? 'config.toml' : 'mcp.json');
      replaceConfigServers(data.config, data.servers || [], label);
      closeConfigModal();
    } catch (err) {
      alert(`Failed to add server: ${err.message}`);
      configModalMergeButton.disabled = false;
      configModalMergeButton.textContent = isEdit ? 'Update' : 'Merge';
      if (currentConfig) {
        refreshConfigStatusLabel();
      } else {
        configFileNameLabel.textContent = previousLabel;
      }
    } finally {
      setLoadingConfig(false);
      if (!configModal.classList.contains('hidden')) {
        addJsonServerButton.disabled = true;
        addTomlServerButton.disabled = true;
      }
    }
  }

  modeSelect.addEventListener('change', updateFormVisibility);
  updateFormVisibility();
  updateSaveButtons();

  loadJsonButton.addEventListener('click', () => {
    if (isLoadingConfig) return;
    configJsonInput.click();
  });

  loadTomlButton.addEventListener('click', () => {
    if (isLoadingConfig) return;
    configTomlInput.click();
  });

  addJsonServerButton.addEventListener('click', () => {
    if (isLoadingConfig) return;
    openConfigModal('json');
  });

  addTomlServerButton.addEventListener('click', () => {
    if (isLoadingConfig) return;
    openConfigModal('toml');
  });

  configJsonInput.addEventListener('change', () => {
    const [file] = configJsonInput.files;
    if (file) {
      void handleConfigFile(file, 'json');
    }
  });

  configTomlInput.addEventListener('change', () => {
    const [file] = configTomlInput.files;
    if (file) {
      void handleConfigFile(file, 'toml');
    }
  });

  saveJsonButton.addEventListener('click', () => {
    if (!saveJsonButton.disabled) {
      void exportCurrentConfig('json');
    }
  });

  saveTomlButton.addEventListener('click', () => {
    if (!saveTomlButton.disabled) {
      void exportCurrentConfig('toml');
    }
  });

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const mode = modeSelect.value;
    let spec;
    if (mode === 'http') {
      const urlField = document.getElementById('http-url');
      const url = urlField.value.trim();
      if (!url) {
        alert('Please enter an MCP HTTP URL');
        return;
      }
      spec = { mode, url };
    } else {
      const cmdField = document.getElementById('stdio-command');
      const cmdLine = cmdField.value.trim();
      if (!cmdLine) {
        alert('Please enter a command to launch the MCP server');
        return;
      }
      const tokens = parseCommandLine(cmdLine);
      if (!tokens.length) {
        alert('Invalid command line');
        return;
      }
      const [command, ...args] = tokens;
      spec = { mode, command, args };
    }
    const displayName =
      mode === 'http'
        ? spec.url
        : `${spec.command} ${Array.isArray(spec.args) ? spec.args.join(' ') : ''}`.trim();
    const entry = {
      id: Date.now(),
      source: 'manual',
      serverName: null,
      displayName,
      spec,
      status: 'pending',
      result: null,
      error: null,
      handshake: null,
      toolTests: {}
    };
    servers.push(entry);
    renderServers();
    try {
      const response = await fetch('/api/diagnose', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(spec)
      });
      const data = await response.json();
      if (!response.ok) {
        throw new Error(data?.error ?? `HTTP ${response.status}`);
      }
      if (data.ok) {
        entry.status = 'ok';
        entry.result = data;
        entry.error = null;
        entry.handshake = data.handshake ?? null;
        entry.toolTests = {};
      } else {
        entry.status = 'error';
        entry.error = data.error;
        entry.handshake = data.handshake ?? null;
      }
    } catch (err) {
      entry.status = 'error';
      entry.error = { kind: 'network_error', details: err.message };
    }
    renderServers();
  });

  toolModalSubmit.addEventListener('click', submitToolModal);
  toolModalReport.addEventListener('click', () => {
    if (!activeToolContext) {
      alert('No tool execution to report.');
      return;
    }
    const context = activeToolContext;
    const stored =
      context.reportData ||
      context.entry?.toolTests?.[context.tool.name]?.reportData ||
      null;
    if (!stored) {
      alert('Run the tool before generating a report.');
      return;
    }
    const finishedDate = new Date(stored.finishedAt);
    const timestamp = formatTimestampForFilename(finishedDate);
    const serverSegment = sanitizeFilenameSegment(stored.serverName || 'server');
    const toolSegment = sanitizeFilenameSegment(stored.toolName || 'tool');
    const filename = `MCPDiagnois_Report_${timestamp}_${serverSegment}_${toolSegment}.md`;
    const content = generateToolReport(stored);
    downloadTextFile(filename, content, 'text/markdown;charset=utf-8');
  });
  toolModalClose.addEventListener('click', closeToolModal);
  configModalClose.addEventListener('click', closeConfigModal);
  configModalMergeButton.addEventListener('click', () => {
    if (!activeConfigFormat) {
      alert('No target format selected.');
      return;
    }
    void performAddServer(activeConfigFormat, configModalInput.value);
  });
  modalBackdrop.addEventListener('click', () => {
    if (!configModal.classList.contains('hidden')) {
      closeConfigModal();
    } else if (!toolModal.classList.contains('hidden')) {
      closeToolModal();
    }
  });
  window.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      if (!configModal.classList.contains('hidden')) {
        closeConfigModal();
      } else if (!toolModal.classList.contains('hidden')) {
        closeToolModal();
      }
    }
  });
})();
