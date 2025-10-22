# MCP-Check 设计概览

本文档总结当前代码实现的模块拆分、命令协作与数据流，帮助读者理解如何在不复用外部仓库源码的情况下实现多阶段 MCP 安全检测。

## 核心模块

- `loader.py`：负责定位并解析 MCP 配置清单，支持 JSON/TOML，提供 `discover_manifests`、`load_manifest` 与 `calculate_fingerprint` 等工具方法。
- `models.py`：定义 `ServerConfig`、`PulseResult`、`SentinelResult`、`FortifyPlan` 等数据结构，并用枚举刻画传输类型、风险向量与策略动作。
- `state.py`：提供 `StateStore` 文件存储与 `_default` 序列化逻辑，每个命令使用 `serialize_*` 函数将结果写入 `~/.mcp-check/<command>/timestamp.json`。
- `commands/`：包含七个子命令的独立实现，模块间通过 `common.py` 提供的 `build_context`、`find_server`、`make_survey_result` 协同工作。
- `cli.py`：统一封装命令行解析与结果输出，所有命令返回结构化数据并以 JSON 打印，便于脚本化调用或集成到 CI。

## 子命令设计

### `survey`
- 利用 `discover_manifests` 遍历配置目录，`load_manifest` 解析出 `ServerConfig`，并通过 `calculate_fingerprint` 生成资产基线指纹。
- 结果使用 `serialize_survey` 持久化，供 `ledger`/`fortify` 读取。

### `pulse`
- 读取 `ServerConfig.scenarios` 中的模拟握手结果，输出握手延迟、协议状态、错误分类，错误列表与状态判定逻辑参考 `handshake_errors`。
- 结果写入 `state/pulse/`，`load_all` 可用于后续聚合。

### `pinpoint`
- 内置注入、工具滥用、RCE 三类脚本，根据服务器的 `RiskVector` 标记判定是否命中漏洞，并生成复现证据。
- 输出 `PinpointResult`（包含 payload、severity 与 evidence），为 `fortify` 提供策略依据。

### `sieve`
- 通过正则模式匹配工具描述与输入 schema，识别隐藏指令、数据外传、敏感路径访问与跨域 URL，并以 `SieveIssue` 形式记录。
- 评分机制采用简单扣分模型（每条问题 -15 分），便于快速排序。

### `sentinel`
- 消费 `ServerConfig.runtime_profile` 中的运行期事件，检测未授权调用、命令执行、streamable-http 超量流量与速率超标，生成对应告警事件。
- 支持通过参数调整 `stream_threshold` 与 `rate_limit`，便于评估不同安全策略。

### `ledger`
- 使用 `StateStore` 拉取最新/全部命令结果，构造 `LedgerReport`，形成 `survey + pulse + pinpoint + sieve + sentinel` 的整合视图。
- 输出 JSON 结构，适合导入安全台账或 CI 报告。

### `fortify`
- 将 `ledger`、`pinpoint`、`sieve`、`sentinel` 的结果映射为可执行策略建议：如限流、工具隔离、流控、命令白名单等。
- 针对 `resource_exhaustion` 风险自动补充 streamable-http 限速建议，涵盖新增的问题点。

## 数据流

1. `survey` 生成初始资产清单与指纹。
2. `pulse`、`pinpoint`、`sieve`、`sentinel` 分别写入状态仓库（按命令归档）。
3. `ledger` 聚合所有命令结果，形成时间戳化的综合报告。
4. `fortify` 读取聚合数据，输出面向运行期/配置的策略计划，可进一步转化为配置补丁或审计任务。

## 测试环境

- `tests/fixtures/manifests.json` 提供三个示例服务器：
  - `atlas`：基线健康。
  - `echo`：包含提示注入、跨域与命令执行风险。
  - `flux`：模拟 streamable-http 资源耗尽与速率超限。
- 每条命令均有单元测试：`test_survey.py`、`test_pulse.py`、`test_pinpoint.py`、`test_sieve.py`、`test_sentinel.py`、`test_ledger.py` 覆盖成功/告警路径，确保状态持久化与策略生成逻辑正确。

---

当前实现以模块化 Python 代码复现 MCP 安全工具链的关键能力，便于进一步扩展真实握手、外部模型接入与 IDE 集成。通过状态仓库与统一 CLI，可快速串联资产发现、风险诊断、动态防护与策略治理的闭环流程。
