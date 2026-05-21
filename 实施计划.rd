# Codex Monitor for Windows 分阶段实施计划

> 目标：用 Codex 本机数据做一个 Windows 上的 Codex Monitor。第一版只服务 Codex，不接 Claude Code，不依赖 Raycast，不修改 `~/.codex/config.toml`。

## 总体判断

之前的计划偏“文件和任务清单”，对实际推进不够友好。这个版本改成阶段式路线图：每个阶段都有明确目标、产物、可能实现方法、验收标准和暂不做内容。

核心路线：

```text
阶段 0：数据探针，确认 Codex 本地日志能支撑哪些功能
阶段 1：解析内核，把 JSONL/config.toml 转成结构化数据
阶段 2：只读 Web Dashboard，先看到真实会话和用量
阶段 3：近实时刷新 + Windows 操作，接近监控工具体验
阶段 4：桌面化，增加系统托盘和通知
阶段 5：增强能力，做搜索、错误分析、恢复入口和多项目效率工具
```

首个可用版本应做到：

- 能扫描 `~/.codex/sessions/**/*.jsonl`。
- 能列出真实 Codex 会话。
- 能展示项目、模型、轮次、状态、token、rate limit、工具调用。
- 能解析 `~/.codex/config.toml` 中的 model、trusted projects、MCP servers。
- 能打开项目目录或编辑器。
- 不展示 API key。
- 不修改 Codex 配置。

## 阶段 0：数据探针和风险确认

### 阶段目标

先证明 Codex 本地数据足够支撑这个产品，避免一上来搭大工程。这个阶段只写少量脚本和一份样例报告，不做 UI。

### 要实现的内容

- 扫描 `~/.codex/sessions/**/*.jsonl`。
- 抽取所有出现过的顶层 `type`。
- 抽取所有出现过的 `event_msg.payload.type`。
- 抽取所有出现过的 `response_item.payload.type`。
- 找出最近 20 个 session 文件。
- 对每个 session 给出：
  - session id
  - cwd
  - model
  - startedAt
  - lastUpdatedAt
  - token_count 是否存在
  - task_started/task_complete 是否存在
  - function_call_output 是否存在
- 读取 `~/.codex/config.toml`，确认 model、projects、MCP servers 的结构。

### 可能实现方法

先写一个独立 Node 脚本：

```text
scripts/probe-codex-data.ts
```

输出到：

```text
docs/probe-report.json
docs/probe-report.md
```

脚本逻辑：

```text
1. 找到 USERPROFILE\.codex\sessions。
2. 递归读取 .jsonl 文件。
3. 逐行 JSON.parse。
4. 对 malformed line 计数但不中断。
5. 聚合事件类型和字段样例。
6. 读取 config.toml。
7. 生成 markdown 报告。
```

### 验收标准

- 能生成 `docs/probe-report.md`。
- 报告里能看到你机器上的真实 session 数量。
- 报告里能看到 `session_meta`、`turn_context`、`event_msg`、`response_item`。
- 报告里能看到 `task_started`、`task_complete`、`token_count`。
- 报告里确认是否能从日志推导状态。

### 暂不做

- 不做数据库。
- 不做 Web UI。
- 不做文件监听。
- 不读 `~/.claude`。
- 不做任何配置写入。

## 阶段 1：Codex 数据解析内核

### 阶段目标

把 Codex 的原始 JSONL 和 TOML 变成稳定的内部数据模型。这个阶段的重点是“数据正确”，不是界面。

### 要实现的内容

项目目录：

```text
D:\codex_tool\codex-monitor\
  apps\
    server\
      src\
        codex\
          codex-jsonl-scanner.ts
          codex-event-normalizer.ts
          codex-status.ts
          codex-config-scanner.ts
        domain\
          session.ts
          turn.ts
          usage.ts
          tool-event.ts
          codex-config.ts
        tests\
          fixtures\
            codex-session-basic.jsonl
            codex-session-token-count.jsonl
            codex-config-basic.toml
          codex-jsonl-scanner.test.ts
          codex-event-normalizer.test.ts
          codex-status.test.ts
          codex-config-scanner.test.ts
```

内部模型：

```ts
type CodexSessionStatus =
  | "running"
  | "completed"
  | "recent"
  | "stale"
  | "errored"
  | "unknown";

type CodexSession = {
  id: string;
  filePath: string;
  cwd: string;
  projectName: string;
  originator?: string;
  cliVersion?: string;
  modelProvider?: string;
  model?: string;
  effort?: string;
  startedAt: string;
  lastUpdatedAt: string;
  status: CodexSessionStatus;
  turns: number;
  toolCalls: number;
  failedToolCalls: number;
  totalInputTokens: number;
  totalCachedInputTokens: number;
  totalOutputTokens: number;
  totalReasoningOutputTokens: number;
  totalTokens: number;
  contextWindow?: number;
  primaryRateLimitUsedPercent?: number;
  secondaryRateLimitUsedPercent?: number;
  lastAgentMessage?: string;
};
```

### 可能实现方法

`codex-jsonl-scanner.ts`：

- 负责文件系统扫描和逐行解析。
- 返回 raw records，不做业务判断。
- malformed line 只计数，不中断。
- 每条记录带 `filePath` 和 `lineNumber`。

`codex-event-normalizer.ts`：

- 把 raw records 归并成 session、turn、tool event、usage event。
- `session_meta` 提供 session 基础字段。
- `turn_context` 提供 model、cwd、sandbox、permission 信息。
- `event_msg.task_started` 创建/更新 turn。
- `event_msg.task_complete` 结束 turn。
- `event_msg.token_count` 提取 token 和 rate limit。
- `response_item.function_call_output` 提取工具结果。
- 不暴露 `encrypted_content`。

`codex-status.ts`：

```text
running:
  最近一个 turn 有 task_started，但没有 task_complete

completed:
  最近一个 turn 有 task_complete

recent:
  文件 10 分钟内更新，但没有明确 task 状态

stale:
  最近 turn 未完成，且文件 10 分钟以上没更新

errored:
  最近工具结果显示非零退出或结构化失败

unknown:
  数据不足
```

`codex-config-scanner.ts`：

- 解析 `~/.codex/config.toml`。
- 读取 model、model_reasoning_effort。
- 读取 trusted projects。
- 读取 windows sandbox。
- 读取 MCP servers。
- MCP env 只返回 key，不返回 value。
- stdio MCP 只做 command 是否存在检查，不做 HTTP 健康检查。

### 验收标准

- `npm test -- codex-jsonl-scanner` 通过。
- `npm test -- codex-event-normalizer` 通过。
- `npm test -- codex-status` 通过。
- `npm test -- codex-config-scanner` 通过。
- 能从真实 session 文件解析出至少 1 个 session。
- 能从真实 `config.toml` 解析出 model 和 MCP servers。
- 不输出 API key、proxy token 等 env 明文。

### 暂不做

- 不上 SQLite。
- 不做前端。
- 不做性能优化。
- 不做会话恢复命令。

## 阶段 2：只读 Web Dashboard MVP

### 阶段目标

把解析结果用网页展示出来，先做“看得见”。这个阶段完成后，项目已经能作为一个只读 Codex Monitor 使用。

### 要实现的内容

项目结构：

```text
D:\codex_tool\codex-monitor\
  package.json
  apps\
    server\
      src\
        index.ts
        api\
          sessions.ts
          usage.ts
          tools.ts
          config.ts
    web\
      src\
        App.tsx
        api.ts
        pages\
          Dashboard.tsx
          Sessions.tsx
          SessionDetail.tsx
          Usage.tsx
          Tools.tsx
          Config.tsx
        components\
          StatusBadge.tsx
          SessionTable.tsx
          TokenSummary.tsx
          RateLimitBar.tsx
          ToolEventTable.tsx
          McpServerTable.tsx
```

API：

```text
GET /api/health
GET /api/sessions
GET /api/sessions/:id
GET /api/usage/summary
GET /api/usage/daily
GET /api/tools
GET /api/config
POST /api/scan
```

页面：

- Dashboard：状态数量、今日 token、rate limit、最近会话、最近失败工具。
- Sessions：所有会话表格。
- SessionDetail：单个会话的 turns、token_count、tool events、最后 agent message。
- Usage：按日期、项目、模型统计 token。
- Tools：工具调用、失败输出、web search、shell command。
- Config：model、trusted projects、Windows sandbox、MCP servers。

### 可能实现方法

先不引入复杂 UI 库：

- 前端用 Vite + React + TypeScript。
- 样式用普通 CSS 或 Tailwind 二选一。
- 图表第一版可以先用表格和 progress bar，不急着引入 chart library。
- 后端用 Express/Fastify 任一轻量框架。
- 第一版可直接每次请求扫描文件，若性能可接受，SQLite 放到阶段 3。

数据流：

```text
Browser
  -> GET /api/sessions
  -> server scans ~/.codex/sessions
  -> normalizer returns sessions
  -> UI renders tables
```

如果扫描慢，再提前进入阶段 3 的 SQLite 增量缓存。

### 验收标准

- `npm run dev` 后可打开本地网页。
- Dashboard 能显示真实 Codex session。
- Sessions 表格能按更新时间排序。
- SessionDetail 能显示至少一个真实会话的 turns 和 token_count。
- Config 页面能显示 MCP servers，但不显示 env value。
- 页面没有因 encrypted_content 或缺字段崩溃。

### 暂不做

- 不做系统托盘。
- 不做实时刷新。
- 不做复杂图表。
- 不做配置编辑。
- 不做自动打开/恢复 session。

## 阶段 3：增量缓存、近实时刷新和 Windows 操作

### 阶段目标

让工具从“只读报表”变成“日常监控工具”：打开后能自动刷新，能快速回到项目。

### 要实现的内容

SQLite 表：

```sql
CREATE TABLE scan_files (
  path TEXT PRIMARY KEY,
  mtime_ms INTEGER NOT NULL,
  size_bytes INTEGER NOT NULL,
  scanned_at TEXT NOT NULL,
  parse_errors INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  file_path TEXT NOT NULL,
  cwd TEXT NOT NULL,
  project_name TEXT NOT NULL,
  model TEXT,
  effort TEXT,
  started_at TEXT NOT NULL,
  last_updated_at TEXT NOT NULL,
  status TEXT NOT NULL,
  turns INTEGER NOT NULL DEFAULT 0,
  tool_calls INTEGER NOT NULL DEFAULT 0,
  failed_tool_calls INTEGER NOT NULL DEFAULT 0,
  total_tokens INTEGER NOT NULL DEFAULT 0,
  primary_rate_limit_used_percent REAL,
  secondary_rate_limit_used_percent REAL,
  last_agent_message TEXT
);

CREATE TABLE turns (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  started_at TEXT NOT NULL,
  completed_at TEXT,
  duration_ms INTEGER,
  status TEXT NOT NULL,
  model TEXT,
  total_tokens INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE tool_events (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  turn_id TEXT,
  timestamp TEXT NOT NULL,
  kind TEXT NOT NULL,
  name TEXT,
  status TEXT,
  exit_code INTEGER,
  summary TEXT NOT NULL
);
```

新增能力：

- 文件 watcher 监听：
  - `~/.codex/sessions`
  - `~/.codex/history.jsonl`
  - `~/.codex/config.toml`
- 变更 debounce 500-1000ms。
- 增量扫描：文件 path + mtime + size 不变就跳过。
- SSE 或 WebSocket 推送 UI 更新。
- Windows 操作：
  - 打开项目目录。
  - 用 VS Code/Cursor/Windsurf 打开项目。
  - 复制 session 文件路径。

### 可能实现方法

增量扫描：

```text
1. 启动时扫描所有 session 文件。
2. 对每个文件记录 mtime 和 size。
3. 文件变化时只重扫变化文件。
4. 对变化 session 先删除旧派生数据，再重新写入 sessions/turns/tool_events。
```

实时刷新：

```text
server file watcher
  -> changed files
  -> incremental scan
  -> emit "scan-complete" event
  -> browser via SSE/WebSocket refreshes relevant API
```

Windows 操作：

```powershell
explorer.exe "<cwd>"
code "<cwd>"
cursor "<cwd>"
windsurf "<cwd>"
```

实现上要避免 shell 字符串拼接，使用 Node `spawn` 参数数组，防止路径里有空格或特殊字符。

### 验收标准

- 修改或新增 Codex session 后，页面能自动刷新。
- 大量历史 session 下，第二次启动明显快于首次全量扫描。
- 点击“打开目录”能打开 Explorer。
- 点击“打开编辑器”能打开已安装的 VS Code/Cursor/Windsurf。
- 未安装编辑器时 UI 给出清晰错误。
- 不因为 `~/.codex\.sandbox-secrets` 这类无权限目录崩溃。

### 暂不做

- 不精准聚焦 Windows Terminal tab。
- 不自动启动新 Codex 会话。
- 不修改 MCP 配置。

## 阶段 4：桌面化和后台体验

### 阶段目标

把 Web Dashboard 包成 Windows 桌面工具，让它像文章里的菜单栏工具一样能常驻。

### 要实现的内容

- Tauri 桌面壳。
- 系统托盘图标。
- 托盘菜单：

```text
Open Codex Monitor
Recent sessions
Running/recent count
Rescan
Quit
```

- Windows 通知：

```text
turn completed
tool failed
rate limit high
```

- 后台启动本地 server 或把 server 能力内嵌进 Tauri sidecar。

### 可能实现方法

优先 Tauri：

- 前端继续复用阶段 2/3 的 React。
- 后端有两种选择：
  - 保留 Node server，Tauri 启动时拉起 sidecar。
  - 把核心扫描逻辑逐步迁移到 Rust/Tauri command。

建议第一版桌面化采用 sidecar，避免重写扫描逻辑。

如果 Tauri 的 Windows tray、sidecar 或通知遇到问题，再评估 Electron：

- Electron 开发更直接。
- Node 文件系统和 tray 能力成熟。
- 代价是体积和资源占用更大。

### 验收标准

- 双击桌面应用能打开 Monitor。
- 关闭窗口后托盘仍可保留。
- 托盘能显示最近状态数量。
- Codex turn 完成时能弹通知。
- 工具失败时能弹通知。
- 退出托盘后后台进程结束干净。

### 暂不做

- 不上架应用商店。
- 不做自动更新。
- 不做远程访问。
- 不做复杂窗口管理。

## 阶段 5：增强能力和产品化

### 阶段目标

在核心监控稳定后，做真正提升效率的功能。

### 可选增强

全文搜索：

- 搜索 agent message。
- 搜索 tool output summary。
- 搜索用户 prompt 摘要。
- 注意 encrypted_content 不可搜索。

错误分析：

- 聚合失败命令。
- 按项目统计失败率。
- 找出最常失败的 MCP/tool。

用量分析：

- 日/周/月 token 趋势。
- 按项目、模型、工作目录排名。
- cached input 与 non-cached input 分开显示。
- reasoning output 单独显示。

恢复入口：

- 调研 Codex 是否有稳定 resume/reopen 命令。
- 如果没有，只提供 session path、cwd、最后消息、建议命令。

项目入口：

- 从 trusted projects 列表启动编辑器。
- 从最近 session 回到项目。
- 为项目生成“继续工作提示词”。

MCP/config 诊断：

- 检查 MCP command 是否存在。
- 检查 args 指向文件是否存在。
- 只显示 env key，提示缺失但不显示 value。
- stdio MCP 不做 HTTP ping。

### 可能实现方法

- 搜索可以先用 SQLite FTS5。
- 趋势图可以引入 Recharts 或 ECharts。
- 错误分析先基于 `function_call_output.exitCode` 和 output 中的结构化失败信息。
- 项目入口只做打开目录/编辑器，后续再做启动 Codex。

### 验收标准

- 能搜索最近会话。
- 能看到失败工具排行榜。
- 能看到最近 7 天 token 趋势。
- 能从项目列表快速打开常用项目。
- MCP 配置诊断不误报 stdio server 为 unreachable。

## 建议的里程碑版本

### v0.1 Probe

只包含阶段 0。

产物：

- `docs/probe-report.md`
- 证明 Codex 数据足够。

### v0.2 Parser

包含阶段 1。

产物：

- Codex JSONL scanner。
- Event normalizer。
- Config scanner。
- 单元测试。

### v0.3 Web MVP

包含阶段 2。

产物：

- 本地 Web Dashboard。
- Sessions/Usage/Tools/Config 页面。

### v0.4 Live Monitor

包含阶段 3。

产物：

- SQLite 增量缓存。
- 文件 watcher。
- 自动刷新。
- Windows open folder/editor。

### v0.5 Desktop

包含阶段 4。

产物：

- Tauri 桌面应用。
- 系统托盘。
- 通知。

### v0.6 Product Polish

包含阶段 5 的部分增强。

产物：

- 搜索。
- 错误分析。
- 更完整用量趋势。
- 项目快捷入口。

## 推荐立即执行的顺序

1. 先做 v0.1 Probe，确认真实 Codex 数据边界。
2. 再做 v0.2 Parser，稳定解析层。
3. 再做 v0.3 Web MVP，快速得到可用界面。
4. 使用几天后再决定 v0.4/v0.5 的投入比例。

这样做的原因：Codex Monitor 最大的不确定性不是前端，也不是 Windows 桌面壳，而是 Codex 本地日志字段是否稳定、能否可靠推导状态。先把数据层打穿，后面的 UI 和桌面化才不会反复返工。
