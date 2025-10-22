# MCP-Check 实现规划

本规划梳理即将落地的 MCP-Check 核心能力，并说明它们对应吸收的工程经验（函数 / 模块参考），以便在不直接复制源码的前提下复现既有最佳实践。

## 模块与命令映射

| MCP-Check 命令 | 目标能力 | 参考实现要点 |
| --- | --- | --- |
| `survey` | 自动发现与编目 MCP 服务器配置，生成可比较的基线清单。 | 借鉴诊断工具中 `parseMcpConfigContent` / `mergeNormalizedConfig` 的配置读取与规范化流程，以及扫描器 `MCPScanner.get_servers_from_path` 对多格式配置的容错解析，并扩展至客户端注册表（含内联服务器）的合并逻辑。 |
| `pulse` | 对指定服务器执行多通道握手，采集协议能力、握手延迟与错误分类。 | 参考诊断器 `connectClient` 与 `diagnose` 中的超时封装 `withTimeout`、错误归类 `classifyError`，并结合扫描器 `check_server_with_timeout` 的超时守护逻辑。 |
| `pinpoint` | 使用预设攻击脚本针对风险服务器做深度复现，捕捉提示注入、工具投毒、RCE 征兆。 | 对照扫描器 `direct_scan` 的 payload 驱动探测，以及 Shield `detectHiddenInstructions` / `detectSensitiveFileAccess` 之类静态模式匹配函数的结果结构，输出含复现脚本的诊断记录。 |
| `sieve` | 对工具/提示描述执行规则与模型双模静态审计，输出风险评级与修复建议。 | 结合 Shield `detectHiddenInstructions`、`detectExfiltrationChannels` 等分析器的匹配格式，以及扫描器 `analyze_scan_path` 的远程模型调用包装结构。 |
| `sentinel` | 提供透明代理模拟、审批流与流量限速，监控 streamable-http 资源耗尽与异常命令。 | 借鉴 Snitch `MCPProxy` 的双向管道缓冲 (`LineBuffer`) 与 `MCPSecurityManager` 事件日志思路，以及扫描器 `gateway` 里的运行时拦截策略。 |
| `ledger` | 聚合历史检测数据，输出 Markdown / JSON 报告与趋势。 | 参考诊断工具服务器端 `attachConfigMetadata` 的清单合并模式，与扫描器 `Storage` 的增量存储接口，将多命令结果标准化写入事件仓库。 |
| `fortify` | 将检测结果转化为安全策略补丁与配置建议，保持运行期与静态策略一致。 | 结合 Shield 修复建议的结构化输出、扫描器 `Storage` 的差异检测，以及 Snitch 信任库更新逻辑，将策略映射为配置变更计划。 |
| `beacon` | 以 MCP 服务器身份对外暴露本地已安装 MCP 资产清单。 | 参考诊断器的报告导出与 Snitch 代理的透明中继思路，封装轻量 HTTP 服务 (`/manifest`) 以便 IDE/客户端直接读取。 |

## 核心功能拆解

1. **配置扫描与资产盘点（`survey`）**
   - 实现跨格式（JSON/TOML）加载、路径归一化与去重。
   - 支持解析客户端注册表（JSON/TOML 或目录），自动收集内联服务器定义并与 manifest 结果合并。
   - 产出带哈希指纹的基线记录，便于后续检测漂移。
   - 存储结构参考 `Storage.record_scan_result` 的增量更新模型。

2. **握手体检与错误分类（`pulse`）**
   - 模拟 stdio/HTTP/SSE 三通道连接，记录握手延迟、协议版本、能力列表。
   - 错误分类沿用 `classifyError` 的枚举，同时兼容 streamable-http 连接异常。

3. **高危复现脚本（`pinpoint`）**
   - 预置注入、命令执行、敏感资源访问三类脚本；可扩展。
   - 结果格式包含输入 Payload、服务器响应、风险评级，与扫描器 `Issue` 结构对应。

4. **静态审计（`sieve`）**
   - 基于工具描述文本运行多条规则，使用 Shield 分析器类似的匹配输出。
   - 可选调用外部模型（预留接口），保持 `analyze_scan_path` 的异步模式。

5. **运行期代理（`sentinel`）**
   - 构建事件管道模拟器，检测：未授权调用、速率超限、streamable-http 资源耗尽。
   - 参考 Snitch `LineBuffer` 的流控处理，记录事件轨迹。

6. **资产广播（`beacon`）**
   - 将 `survey` 结果封装为可复用的 `/manifest` 接口或 JSON 输出。
   - 提供 `--serve` 选项启动本地 HTTP 服务，让 IDE/模型在无需额外配置的情况下读取 MCP 清单。

7. **报告中心（`ledger`）**
   - 将所有命令的输出写入统一 state 目录，以时间线组织。
   - 报告包含风险统计、服务器健康度、策略缺口。

8. **策略落地（`fortify`）**
   - 根据检测结果生成 YAML/JSON 补丁草案，涵盖：禁用工具、限流、超时、凭证要求。
   - 对应 Snitch 信任模型：维护 `trusted_servers`、`blocked_tools`、`rate_limits` 等字段。

## 测试与环境准备

- 构建最小 MCP 测试环境：
  1. `atlas` —— 基线健康服务器。
  2. `echo` —— 存在提示注入与工具投毒风险。
  3. `flux` —— streamable-http 端点存在资源耗尽隐患。
- 提供客户端注册表样例 `client-registry.json`，模拟常见 IDE/助手的 MCP 插件目录，测试自动发现与 `beacon` 广播能力。
- 提供仿真握手、工具响应、运行期事件数据，用于单元测试与集成测试。
- 每条命令均需提供对应的单元测试，覆盖正常路径与至少一条异常路径，包括 `beacon` 与基于环境变量的自动发现流程。

## 时间线

1. 完成 CLI 框架、数据模型与状态存储。
2. 逐条实现命令功能与测试。
3. 构建测试环境与服务器样例。
4. 更新 README 与设计文档反映实际实现。

以上规划确保 MCP-Check 能够在继承成熟方案经验的同时，以全新代码落地全链路安全检测能力。
