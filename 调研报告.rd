# Codex Monitor for Windows 调研报告

日期：2026-05-21

## 目标

你明确不使用 Claude Code，希望用 Codex 实现一个类似文章中 Claude Code Monitor 的工具。本文档重新以 Codex 为第一目标，Claude Code 只作为参考案例，不作为实现前提。

结论：Windows 上可以做 Codex Monitor，而且你的机器已经有足够的本地数据源。第一版不需要 Claude hooks，也不需要 Raycast。更合理的路线是直接读取 `~/.codex` 下的会话、配置和日志，做一个 Windows 本地 Web Dashboard；后续再封装成 Tauri 桌面应用，补系统托盘、通知和窗口跳转。

## 从原文抽象出的本质

Yu 的文章实现的是 Claude Code Monitor：

- 实时会话状态。
- token/用量统计。
- 插件、skills、MCP 状态。
- 菜单栏常驻。
- 点击跳回工作现场。

但这些能力并不依赖 Claude Code 本身。第一性原理看，它真正解决的是：

- 我开了哪些 AI 编程会话。
- 哪个会话正在执行、等待、空闲、结束。
- 哪个项目消耗最多上下文和 token。
- 哪些工具调用失败或卡住。
- 哪些 MCP/config/skill/plugin 影响当前工作环境。
- 我如何快速回到对应项目继续工作。

因此 Codex 版本不应照搬 `Claude hooks + ~/.claude/projects`，而应围绕 Codex 自己的数据边界设计：

```text
~/.codex/sessions/**/*.jsonl
~/.codex/history.jsonl
~/.codex/config.toml
~/.codex/log
~/.codex/skills
~/.codex/plugins / .tmp/plugins
~/.codex/state_*.sqlite / logs_*.sqlite
```

## 本机 Codex 数据源观察

你的机器存在：

```text
C:\Users\34763\.codex\sessions
C:\Users\34763\.codex\history.jsonl
C:\Users\34763\.codex\config.toml
C:\Users\34763\.codex\skills
C:\Users\34763\.codex\log
C:\Users\34763\.codex\state_5.sqlite
C:\Users\34763\.codex\logs_2.sqlite
```

`~/.codex/sessions` 按日期分层保存 rollout JSONL，例如：

```text
C:\Users\34763\.codex\sessions\2026\05\21\rollout-2026-05-21T10-41-59-019e4869-4804-7ac1-9cbe-20dda042894d.jsonl
```

抽样观察到的 Codex JSONL 事件类型：

```text
session_meta
turn_context
event_msg
response_item
```

其中 `event_msg.payload.type` 可见：

```text
task_started
task_complete
token_count
agent_message
web_search_end
```

`response_item.payload.type` 可见：

```text
message
reasoning
function_call
function_call_output
web_search_call
```

`session_meta.payload` 包含：

```text
id
timestamp
cwd
originator
cli_version
source
thread_source
model_provider
base_instructions
```

`turn_context.payload` 包含：

```text
turn_id
cwd
current_date
timezone
approval_policy
sandbox_policy
permission_profile
model
realtime_active
effort
summary
```

`event_msg.payload.type == token_count` 包含：

```text
total_token_usage.input_tokens
total_token_usage.cached_input_tokens
total_token_usage.output_tokens
total_token_usage.reasoning_output_tokens
total_token_usage.total_tokens
last_token_usage.input_tokens
last_token_usage.cached_input_tokens
last_token_usage.output_tokens
last_token_usage.reasoning_output_tokens
last_token_usage.total_tokens
model_context_window
rate_limits.primary.used_percent
rate_limits.primary.window_minutes
rate_limits.primary.resets_at
rate_limits.secondary.used_percent
plan_type
rate_limit_reached_type
```

这说明 Codex Monitor 第一版可以从 JSONL 中直接得到：

- 会话 ID。
- 项目目录。
- Codex CLI 版本。
- 模型。
- 每轮开始和结束。
- 最后一条 agent 消息。
- token 总量和最近一轮 token。
- 5 小时/7 天窗口使用比例。
- 工具调用及结果。
- sandbox/permission 上下文。

## Codex 与 Claude Code 的关键差异

Claude Code Monitor 常见做法：

```text
hooks 负责实时状态
JSONL 负责 token 和历史统计
Raycast 负责 UI
```

Codex Monitor 第一版更适合：

```text
Codex rollout JSONL 负责会话、轮次、token、工具事件
Codex config.toml 负责 projects、MCP、sandbox、model 配置
文件 watcher 负责近实时刷新
本地 Web/Tauri 负责 UI
```

原因：

- 当前没有必要假设 Codex 有 Claude Code 那样的 hook 生命周期。
- Codex 自己的 rollout JSONL 已经包含 `task_started`、`task_complete`、`token_count`。
- 状态可以由“最后事件 + 文件 mtime + task_complete 是否出现”推导。
- 第一版应避免修改 Codex 配置或安装 hooks，降低风险。

## 状态推导方法

Codex 版本无法直接照搬 `Active / Waiting / Idle / Ended`，需要先定义可从日志证明的状态。

建议第一版状态：

```text
Running      最近事件是 task_started，且同 turn 未出现 task_complete
Completed    最近 turn 有 task_complete
Recent       文件最近 N 分钟更新过，但没有明确 running
Stale        文件超过 N 分钟未更新，且无明确结束事件
Errored      最近 function_call_output 或 event_msg 中出现失败/非零退出
Unknown      数据不足
```

可以展示成更用户友好的中文：

```text
执行中
已完成
最近活跃
已停滞
有错误
未知
```

注意：Codex TUI 正在等用户输入时，日志未必有单独的 `waiting` 事件。第一版不应承诺精准识别“等待输入”。可以用 `task_complete` 后的状态近似表示“本轮完成，可能等待下一条指令”。

## Token 与用量统计

Codex 的 `token_count` 事件比 Claude JSONL 更直接，第一版优先使用：

- `last_token_usage` 统计每轮增量。
- `total_token_usage` 展示会话累计。
- `rate_limits` 展示 5 小时和 7 天窗口。
- `model_context_window` 展示上下文窗口。

需要注意：

- `total_token_usage` 是会话内累计，不应跨会话简单相加后再当成增量。
- 全局日统计应优先累计每个 `token_count.last_token_usage`。
- 如果历史日志缺少 `last_token_usage`，再用相邻 `total_token_usage` 做差值估算。
- 成本金额不作为第一版核心，因为 Plus/Pro/订阅计划与 API 单价不是同一个账单模型。

## 配置与扩展状态

你的 `~/.codex/config.toml` 中已经有：

```text
model
model_reasoning_effort
projects.<path>.trust_level
windows.sandbox
mcp_servers.<name>.command
mcp_servers.<name>.args
mcp_servers.<name>.env
mcp_servers.<name>.tools.<tool>.approval_mode
```

第一版可以只读展示：

- 默认模型和 reasoning effort。
- trusted projects。
- Windows sandbox 设置。
- MCP servers 列表。
- 每个 MCP 的 command、args、env key 名称。
- 每个 MCP tool 的 approval mode。

MCP 健康判断必须保守：

- 对 stdio MCP：检查 command 是否存在、配置是否可解析，不做 HTTP ping。
- 对 HTTP/SSE MCP：后续再做 endpoint 检查。
- env 值默认不显示明文，只显示 key 是否存在。

## Windows UI 路线

### 第一版：本地 Web Dashboard

推荐。

优点：

- 最快验证 Codex 数据模型。
- 不依赖 Raycast。
- 不需要 Windows native API。
- 方便显示表格、筛选、token 图表、日志详情。
- 后续可被 Tauri 直接包进去。

### 第二版：Tauri 桌面应用

适合在第一版稳定后做。

能力：

- 系统托盘。
- 后台常驻。
- Windows 通知。
- 打开 Dashboard。
- 最近会话快速菜单。

### 第三版：Raycast for Windows / Flow Launcher 入口

可选。

Raycast for Windows 目前已是 public beta，但不适合作为第一版核心，因为：

- 扩展兼容性仍需实测。
- Windows 上是否能完整复刻 menu bar/status item 体验不确定。
- Codex 监控首先是数据问题，不是启动器问题。

## 相关项目参考

### wuyuxiangX/claude-code-monitor

链接：https://github.com/wuyuxiangX/claude-code-monitor

参考价值：

- 产品形态和功能分组值得参考。
- “事件源 + 日志源 + UI”的思想值得参考。

不能照搬：

- Claude hooks。
- `~/.claude/projects` JSONL 格式。
- Raycast/macOS 跳转逻辑。

### ek33450505/claude-code-dashboard

链接：https://github.com/ek33450505/claude-code-dashboard

参考价值：

- 本地 Web dashboard 路线。
- SSE/实时刷新。
- SQLite 作为聚合缓存。

不能照搬：

- CAST/Claude Code 生态假设。

### phuryn/claude-usage

链接：https://github.com/phuryn/claude-usage

参考价值：

- 本地扫描 JSONL。
- 增量扫描。
- Windows 可用的轻量 dashboard。

不能照搬：

- Claude usage 字段。
- API 价格估算逻辑。

## 推荐功能范围

第一版：

- Codex 会话列表。
- 每个会话的项目、模型、开始时间、最后更新时间、状态。
- 当前/最近任务状态。
- token_count 统计。
- rate limit 使用比例。
- 工具调用列表和失败标记。
- Codex config.toml 只读解析。
- MCP 配置只读展示。
- 打开项目目录。
- 打开 VS Code/Cursor。
- 复制 session file path。

第二版：

- 系统托盘。
- Windows 通知。
- 会话详情页。
- 日志全文搜索。
- 按项目/日期/model 统计。
- 错误事件聚合。

第三版：

- 从 UI 启动新的 Codex 会话。
- 尝试恢复/继续历史会话。
- 聚焦 Windows Terminal/PowerShell/编辑器窗口。
- 插件/skills 管理。
- Raycast/Flow Launcher 快捷入口。

## 关键风险

- Codex JSONL 格式可能随版本变化，需要宽松解析。
- 部分内容是 encrypted_content，不能展示推理正文，只展示元数据。
- token_count 事件是最可靠的 token 来源，但旧会话可能没有完整字段。
- “等待输入”状态可能无法从日志精确判断。
- 不应读取或展示敏感 env 明文，比如 API key。
- 不应直接修改 `~/.codex/config.toml`，第一版只读。

## 第一性原理后的架构判断

Codex Monitor 的核心不是“复刻 Claude Monitor”，而是为 Codex 的本地工作流建立 observability layer。

建议架构：

```text
CodexSessionScanner
  reads ~/.codex/sessions/**/*.jsonl
  emits sessions, turns, token events, tool events

CodexConfigScanner
  reads ~/.codex/config.toml
  emits model config, projects, MCP servers, sandbox

StateStore
  SQLite cache for incremental parsing and fast UI

Local API
  REST for initial page data
  SSE/WebSocket for file watcher updates

Web UI
  Dashboard
  Sessions
  Usage
  Tools
  Config
  Settings

Windows Actions
  open folder
  open editor
  copy path/command
```

## 资料来源

- Yu 的文章：https://yudesk.dev/blog/claude-code-monitor-dev-journey
- 作者仓库：https://github.com/wuyuxiangX/claude-code-monitor
- Raycast for Windows 官方页：https://www.raycast.com/windows
- Raycast Windows public beta 官方博客：https://www.raycast.com/blog/raycast-for-windows
- Raycast Extensions 文档：https://manual.raycast.com/extensions
- claude-code-dashboard：https://github.com/ek33450505/claude-code-dashboard
- claude-usage：https://github.com/phuryn/claude-usage
- 本机 Codex 数据抽样：`C:\Users\34763\.codex\sessions`、`C:\Users\34763\.codex\config.toml`
