# MCP-Check 实战教程

本教程面向首次接触 MCP-Check 的安全工程师，演示如何在本地准备真实的 MCP 服务器集合、生成基线清单，并用 CLI 子命令对其进行全链路安全检测（含 streamable-http 资源耗尽场景）。

## 1. 前置准备

| 依赖 | 说明 |
| --- | --- |
| Python 3.11+ | 运行 MCP-Check CLI 与测试套件 |
| `pipx` / `uv`（可选） | 隔离安装各类 MCP 服务端进程 |
| `git`、`node`、`pnpm` | 少数社区 MCP 服务器基于 Node.js，需要包管理器支持 |

安装 MCP-Check（开发模式便于调试）：

```bash
cd /path/to/MCP-Check/mcp-check
pip install -e .
```

## 2. 准备 10 个真实 MCP 服务器

下表列出了当前社区维护且活跃的 10 个 MCP 服务器项目，覆盖文件系统、代码协作、办公自动化与数据服务。请按照各仓库 README 指引安装与启动（多数提供 `uv`/`pipx run` 或 `pnpm dlx` 启动脚本），并在本地监听独立端口或提供 `stdio` 入口。

| 序号 | 服务名称 | 仓库/发布渠道 | 启动示例 |
| --- | --- | --- | --- |
| 1 | Filesystem Server | `https://github.com/modelcontextprotocol/servers/tree/main/filesystem` | `uv run mcp-filesystem --root ~/workspace` |
| 2 | GitHub Server | `https://github.com/modelcontextprotocol/servers/tree/main/github` | `uv run mcp-github --token $GITHUB_TOKEN` |
| 3 | Google Calendar Server | `https://github.com/modelcontextprotocol/servers/tree/main/google-calendar` | `uv run mcp-google-calendar --credentials creds.json` |
| 4 | Google Drive Server | `https://github.com/modelcontextprotocol/servers/tree/main/google-drive` | `uv run mcp-google-drive --credentials creds.json` |
| 5 | Slack Server | `https://github.com/modelcontextprotocol/servers/tree/main/slack` | `uv run mcp-slack --bot-token $SLACK_BOT_TOKEN` |
| 6 | Zendesk Server | `https://github.com/modelcontextprotocol/servers/tree/main/zendesk` | `uv run mcp-zendesk --subdomain your_subdomain` |
| 7 | Jira Server | `https://github.com/modelcontextprotocol/servers/tree/main/jira` | `uv run mcp-jira --site https://your-domain.atlassian.net` |
| 8 | Confluence Server | `https://github.com/modelcontextprotocol/servers/tree/main/confluence` | `uv run mcp-confluence --site https://your-domain.atlassian.net/wiki` |
| 9 | Linear Server | `https://github.com/modelcontextprotocol/servers/tree/main/linear` | `uv run mcp-linear --api-key $LINEAR_API_KEY` |
| 10 | Notion Server | `https://github.com/modelcontextprotocol/servers/tree/main/notion` | `uv run mcp-notion --integration-token $NOTION_TOKEN` |

> **提示**
> 1. 若某些服务器需 HTTP 运行，请在 `--port` 参数中指定不冲突的端口（例如 `localhost:5101` ~ `localhost:5110`）。
> 2. 将敏感凭证写入 `.env` 或操作系统秘钥管理器，避免直接出现在命令历史中。
> 3. 为 streamable-http 演练，可在 Filesystem 或 Slack Server 的配置中开启大文件/日志流模式，或额外运行支持流式输出的 `mcp-log-streamer`（同样可在官方仓库找到）。

## 3. 生成统一清单

各服务启动后，创建一个清单目录并以 JSON 或 TOML 描述它们的传输方式与入口。例如在 `tutorial/manifests` 下编写 `ten_servers.json`：

```json
{
  "servers": [
    {"name": "filesystem", "transport": "stdio", "endpoint": "mcp-filesystem"},
    {"name": "github", "transport": "stdio", "endpoint": "mcp-github"},
    {"name": "google_calendar", "transport": "stdio", "endpoint": "mcp-google-calendar"},
    {"name": "google_drive", "transport": "stdio", "endpoint": "mcp-google-drive"},
    {"name": "slack", "transport": "stdio", "endpoint": "mcp-slack"},
    {"name": "zendesk", "transport": "http", "endpoint": "http://localhost:5106/mcp"},
    {"name": "jira", "transport": "http", "endpoint": "http://localhost:5107/mcp"},
    {"name": "confluence", "transport": "http", "endpoint": "http://localhost:5108/mcp"},
    {"name": "linear", "transport": "http", "endpoint": "http://localhost:5109/mcp"},
    {"name": "notion", "transport": "streamable-http", "endpoint": "http://localhost:5110/mcp"}
  ]
}
```

> **校验**：运行 `jq . tutorial/manifests/ten_servers.json` 或使用编辑器的 JSON 校验插件，确保格式正确。

为避免手动维护 CLI 参数，可以同时准备一个客户端注册表，模拟常见 IDE 的 MCP 插件目录。创建 `tutorial/registry.json`：

```json
{
  "manifests": ["manifests/ten_servers.json"],
  "servers": [
    {
      "name": "infra_monitor",
      "transport": "http",
      "endpoint": "http://localhost:5111/mcp",
      "scenarios": {
        "handshake": {
          "handshake_latency_ms": 380,
          "handshake_errors": [],
          "capabilities": {"prompts": true, "tools": 3}
        }
      }
    }
  ]
}
```

> 以上注册表引用了上一节的 manifest，并额外定义了一个内联服务器 `infra_monitor`，用于演示 MCP-Check 如何在无额外配置的情况下发现本地安装的服务器。

## 4. CLI 全链路演练

以下命令假设：

- `tutorial/manifests` 与 `tutorial/registry.json` 均已创建。
- 状态仓库存储在 `tutorial/state`（若不存在可提前创建或交由命令自动创建）。
- 所有 MCP 服务已运行并可达。

为方便自动发现，本节示例将注册表路径导出为环境变量：

```bash
export MCP_CHECK_CLIENT_PATHS="$(pwd)/tutorial/registry.json"
STATE_DIR=tutorial/state
```

> 如需禁用自动查找，可在单个命令后附加 `--no-default-client-search`，或直接使用 `--root tutorial/manifests` / `--client-config tutorial/registry.json` 覆盖。

### 4.1 资产盘点 `survey`

```bash
mcp-check --state-dir "$STATE_DIR" survey
```

预期输出：列出 11 个服务器（10 个 manifest + 1 个内联）的指纹摘要与发现路径，状态仓库生成 `survey.json`。

### 4.2 多协议探测 `pulse`

对全部服务器执行握手体检，可用 shell 循环：

```bash
for name in filesystem github google_calendar google_drive slack zendesk jira confluence linear notion infra_monitor; do
  mcp-check --state-dir "$STATE_DIR" pulse "$name"
done
```

CLI 会为每个服务器展示握手耗时、协议信息、错误分类与 streamable-http 的流量警戒线。

### 4.3 漏洞复现 `pinpoint`

针对高风险目标（示例选择 `notion` 与 `filesystem`）：

```bash
mcp-check --state-dir "$STATE_DIR" pinpoint notion --scenario prompt_injection --scenario rce
mcp-check --state-dir "$STATE_DIR" pinpoint filesystem --scenario tool_poisoning
```

命令会模拟提示注入、工具投毒与资源耗尽脚本，输出复现证据及严重度评级。

### 4.4 静态审计 `sieve`

扫描关键服务器的工具描述与资源：

```bash
for name in filesystem notion infra_monitor; do
  mcp-check --state-dir "$STATE_DIR" sieve "$name"
done
```

报告包含潜在的敏感路径访问、跨域指令及可疑的默认 payload。

### 4.5 运行期监控 `sentinel`

选择具备流式或命令执行能力的服务运行模拟代理：

```bash
mcp-check --state-dir "$STATE_DIR" sentinel notion --stream-threshold 10485760 --rate-limit 150
mcp-check --state-dir "$STATE_DIR" sentinel infra_monitor --stream-threshold 524288 --rate-limit 120
```

命令会捕获审批拒绝、命令链路与大流量事件，并在超阈值时给出熔断建议。

### 4.6 报告聚合 `ledger`

```bash
mcp-check --state-dir "$STATE_DIR" ledger
```

输出的报告将汇总前述所有命令的最新结果，适合导出为 JSON 供后续处理。

### 4.7 策略修复 `fortify`

```bash
mcp-check --state-dir "$STATE_DIR" fortify
```

CLI 会生成建议的访问控制与运行期限流策略，可结合内部工作流程转化为配置补丁。

### 4.8 资产广播 `beacon`

```bash
# 打印一次性资产快照
mcp-check --state-dir "$STATE_DIR" beacon

# 监听 HTTP 端口供 IDE 直接读取（按 Ctrl+C 停止）
mcp-check --state-dir "$STATE_DIR" beacon --serve --host 127.0.0.1 --port 5150
```

第一条命令会输出与 `survey` 同步的 JSON 清单；第二条命令将启动轻量服务，`GET /manifest` 即可获取实时资产视图。

## 5. 自动化测试

使用仓库内置测试确保所有命令逻辑正常：

```bash
pytest
```

对教程环境进行最小回归，可执行：

```bash
pytest tests/test_survey.py tests/test_pulse.py tests/test_pinpoint.py tests/test_sieve.py tests/test_sentinel.py tests/test_ledger.py
```

## 6. 常见问题

| 问题 | 处理方式 |
| --- | --- |
| `No manifests found` | 若未设置 `MCP_CHECK_CLIENT_PATHS`，请显式传入 `--client-config tutorial/registry.json` 或 `--root tutorial/manifests` |
| HTTP 握手 401/403 | 检查服务端凭证或 OAuth 配置，并确认注册表中的 `endpoint` 地址与认证头一致 |
| streamable-http 阈值触发 | 调整 `sentinel` 的 `--stream-threshold` / `--rate-limit`，或在服务器端启用压缩/分页 |
| 状态数据陈旧 | 删除 `tutorial/state` 下的旧文件或重新运行 `mcp-check --state-dir "$STATE_DIR" survey` 构建新基线 |

## 7. 教程总结

通过以上步骤，新用户可以：

1. 引入 10 个常见的企业级 MCP 服务并建立统一清单，同时通过客户端注册表演示自动发现。
2. 利用 MCP-Check 的八个子命令（含 `beacon`）从资产发现、静态/动态检测到策略修复与资产广播形成闭环。
3. 针对 streamable-http 的资源耗尽风险设置阈值与熔断策略，确保持续运行安全。

完成演练后，可将生成的 `tutorial/state` 与 `tutorial/reports` 归档，作为后续上线/巡检的基线与追踪资料。
