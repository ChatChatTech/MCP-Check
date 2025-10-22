# MCP-Check

MCP-Check 是一套面向 MCP 服务器安全检测与治理的综合工具包，覆盖从配置治理、静态分析、动态监测到运行期防护的完整链路。方案聚焦常见威胁（提示注入、工具投毒、跨域越权、敏感数据泄露、RCE 以及 streamable-http 场景下的资源耗尽）并沉淀为统一的 CLI 工作流。

## 代码结构

```
├── pyproject.toml            # 包定义与 CLI 入口
├── src/mcp_check             # 核心实现
│   ├── cli.py                # 命令解析与调度
│   ├── loader.py             # 配置扫描与指纹计算
│   ├── models.py             # 数据模型（服务器、诊断结果、策略建议）
│   ├── state.py              # JSON 状态仓库序列化
│   ├── discovery.py          # MCP 客户端注册表自动发现
│   └── commands/             # 各子命令实现（survey/pulse/…）
├── tests/                    # 单元测试与示例环境
│   ├── fixtures/manifests.json  # atlas/echo/flux 示例服务器
│   └── test_*.py             # 覆盖全部命令的测试用例
└── docs/                     # 设计与实现规划
    ├── overview.md
    └── implementation_plan.md
```

## 命令一览

| 命令 | 说明 | 核心逻辑 |
| --- | --- | --- |
| `survey` | 从清单或客户端注册表自动发现 MCP 资产并指纹化 | `commands.survey.execute` 调用 `discovery.discover_environment` + `state.serialize_survey` |
| `pulse` | 多协议握手体检，记录延迟与错误分类 | `commands.pulse.execute` 读取场景延迟/错误，模拟诊断并写入状态 |
| `pinpoint` | 定向复现提示注入、工具投毒、RCE 等高危脚本 | `commands.pinpoint.execute` 结合服务器风险向量输出复现证据 |
| `sieve` | 静态审计工具描述，捕捉隐藏指令/跨域/敏感访问 | `commands.sieve.execute` 基于模式匹配生成 `SieveIssue` |
| `sentinel` | 运行期代理模拟，监测审批拒绝、命令执行、streamable-http 资源耗尽 | `commands.sentinel.execute` 检测事件阈值并生成告警 |
| `ledger` | 汇总历史检测结果，导出统一报告 | `commands.ledger.execute` 聚合最新 survey/pulse/pinpoint/sieve/sentinel |
| `fortify` | 将风险转化为策略补丁与运行期建议 | `commands.fortify.execute` 结合检测结果生成 `FortifyPlan` |
| `beacon` | 以轻量 HTTP 端点或 JSON 输出方式对外提供统一 MCP 资产视图 | `commands.beacon.execute` 复用 `survey` 指纹并可监听端口 |

每次命令执行都会将结构化结果写入状态目录（默认 `~/.mcp-check`，可通过 `--state-dir` 指定），`ledger` 与 `fortify` 会复用这些数据生成报告与修复计划。`survey`、`pulse` 等命令默认会尝试三种来源发现 MCP：

1. `--client-config` 指定的客户端注册表（JSON/TOML 文件或目录）。
2. `--root` 指定的 manifest 根目录。
3. 未显式提供时，会扫描 `MCP_CHECK_CLIENT_PATHS` 环境变量列出的注册表，或常见客户端的默认存储路径。

若不希望自动扫描，可附加 `--no-default-client-search`。

## 快速上手

1. **安装依赖**

   ```bash
   pip install -e .
   ```

2. **准备测试环境**

   仓库自带三个示例服务器（`atlas`、`echo`、`flux`），位于 `tests/fixtures/manifests.json`，并额外提供模拟客户端注册表 `tests/fixtures/client-registry.json`，涵盖内联与外部 manifest 两种形式，方便演示自动发现能力。

3. **执行全链路检测示例**

   ```bash
   # 方式一：显式指定 manifest 目录
   mcp-check --root tests/fixtures --state-dir .tmp/state survey
   mcp-check --root tests/fixtures --state-dir .tmp/state pulse echo
   mcp-check --root tests/fixtures --state-dir .tmp/state pinpoint echo
   mcp-check --root tests/fixtures --state-dir .tmp/state sieve echo
   mcp-check --root tests/fixtures --state-dir .tmp/state sentinel flux
   mcp-check --root tests/fixtures --state-dir .tmp/state fortify

   # 方式二：依赖客户端注册表自动发现
   export MCP_CHECK_CLIENT_PATHS="$(pwd)/tests/fixtures/client-registry.json"
   mcp-check --state-dir .tmp/state survey
   mcp-check --state-dir .tmp/state pulse inline-scout
   mcp-check --state-dir .tmp/state beacon

   # 汇总
   mcp-check --state-dir .tmp/state ledger
   ```

   以上命令会逐步构建状态仓库，并最终输出综合报告与策略建议，同时 `beacon` 将生成可供其他 MCP 客户端消费的统一清单（可搭配 `--serve` 监听端口）。

## 测试

项目使用 `pytest` 覆盖所有命令逻辑及状态持久化流程，包含对 streamable-http 资源耗尽、跨域滥用与提示注入等场景的验证。

```bash
pytest
```

## 设计文档

- [`docs/overview.md`](docs/overview.md) 概述系统架构、命令协作与策略落地思路。
- [`docs/implementation_plan.md`](docs/implementation_plan.md) 对应外部经验映射，明确各模块与参考设计的关系。
- [`docs/tutorial.md`](docs/tutorial.md) 提供 10 个真实 MCP 服务的本地化演练与七大命令的逐步示例。

---

MCP-Check 通过模块化 CLI、状态仓库与策略引擎，帮助团队以最低的集成成本快速识别 MCP 服务器风险、验证运行期行为并给出修复建议。
