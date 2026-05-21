# Codex Monitor for Windows Implementation Plan

> For agentic workers: implement task-by-task. This plan intentionally targets Codex first. Claude Code support is out of scope unless explicitly added later.

**Goal:** Build a Windows-first local dashboard that monitors Codex sessions, token usage, tool activity, rate-limit state, projects, and MCP/config health from local `~/.codex` data.

**Architecture:** Parse Codex rollout JSONL and `config.toml` into a normalized local SQLite store, expose it through a local API, and render a React dashboard. Start as a Web app; wrap with Tauri later for tray and notifications.

**Tech Stack:** Node.js + TypeScript, Vite + React, SQLite, TOML parser, file watcher, PowerShell-compatible Windows actions, optional Tauri in phase 2.

---

## Product Scope

第一版只做 Codex：

- 读取 `~/.codex/sessions/**/*.jsonl`。
- 读取 `~/.codex/history.jsonl`。
- 读取 `~/.codex/config.toml`。
- 展示 Codex 会话、轮次、token、rate limit、工具调用、MCP 配置。
- 支持打开项目目录、打开 VS Code/Cursor、复制 session 文件路径。

第一版不做：

- Claude Code hooks。
- 读取 `~/.claude`。
- 修改 `~/.codex/config.toml`。
- 自动安装/卸载 MCP、skills、plugins。
- 精准聚焦 Windows Terminal tab。
- 展示 encrypted reasoning content。
- 云同步或账号系统。

## Proposed File Structure

```text
D:\codex_tool\codex-monitor\
  package.json
  README.md
  apps\
    server\
      src\
        index.ts
        config.ts
        db.ts
        fs-paths.ts
        api\
          sessions.ts
          usage.ts
          tools.ts
          config.ts
          actions.ts
        codex\
          codex-jsonl-scanner.ts
          codex-event-normalizer.ts
          codex-config-scanner.ts
          codex-history-scanner.ts
          codex-status.ts
        domain\
          session.ts
          turn.ts
          usage.ts
          tool-event.ts
          codex-config.ts
        services\
          session-store.ts
          usage-store.ts
          scan-store.ts
          file-watcher.ts
          action-service.ts
        tests\
          codex-jsonl-scanner.test.ts
          codex-event-normalizer.test.ts
          codex-config-scanner.test.ts
          codex-status.test.ts
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
          Settings.tsx
        components\
          StatusBadge.tsx
          SessionTable.tsx
          TokenSummary.tsx
          RateLimitBar.tsx
          ToolEventTable.tsx
          McpServerTable.tsx
```

## Codex Data Model

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

type CodexTurn = {
  id: string;
  sessionId: string;
  startedAt: string;
  completedAt?: string;
  durationMs?: number;
  status: "running" | "completed" | "unknown";
  model?: string;
  cwd?: string;
  inputTokens: number;
  cachedInputTokens: number;
  outputTokens: number;
  reasoningOutputTokens: number;
  totalTokens: number;
};

type CodexToolEvent = {
  id: string;
  sessionId: string;
  turnId?: string;
  timestamp: string;
  kind: "function_call" | "function_call_output" | "web_search_call" | "shell_command" | "unknown";
  name?: string;
  status?: string;
  exitCode?: number;
  summary: string;
};

type CodexMcpServer = {
  name: string;
  command?: string;
  args: string[];
  envKeys: string[];
  tools: Array<{ name: string; approvalMode?: string }>;
  status: "configured" | "missing-command" | "invalid-config" | "unknown";
};
```

## Status Rules

第一版状态从日志推导：

```text
running:
  latest event_msg.payload.type is task_started for a turn
  and no task_complete exists for the same turn

completed:
  latest task_started turn has a matching task_complete

recent:
  file mtime is within 10 minutes
  but no clear running/completed conclusion exists

stale:
  file mtime is older than 10 minutes
  and no task_complete can be found for the latest turn

errored:
  latest relevant function_call_output has non-zero exit code
  or output contains a structured command failure

unknown:
  data is incomplete or parser cannot classify safely
```

UI 中文显示：

```text
running   -> 执行中
completed -> 本轮完成
recent    -> 最近活跃
stale     -> 已停滞
errored   -> 有错误
unknown   -> 未知
```

## Phase 0: Local Data Verification

- [ ] Confirm Codex session files exist.

Run:

```powershell
Get-ChildItem -Recurse -File -LiteralPath "$env:USERPROFILE\.codex\sessions" | Select-Object -First 5 FullName,Length,LastWriteTime
```

Expected: JSONL rollout files exist.

- [ ] Confirm Codex config exists.

Run:

```powershell
Get-Item -LiteralPath "$env:USERPROFILE\.codex\config.toml" | Select-Object FullName,Length,LastWriteTime
```

Expected: `config.toml` exists.

- [ ] Capture fixture samples.

Create test fixtures by copying a few representative lines into:

```text
apps/server/src/tests/fixtures/codex-session-basic.jsonl
apps/server/src/tests/fixtures/codex-session-token-count.jsonl
apps/server/src/tests/fixtures/codex-config-basic.toml
```

Fixture lines must include:

```text
session_meta
turn_context
event_msg.task_started
event_msg.token_count
event_msg.task_complete
response_item.function_call_output
```

## Phase 1: Scaffold Project

- [ ] Create `D:\codex_tool\codex-monitor`.
- [ ] Initialize Node + TypeScript workspace.
- [ ] Add `apps/server` and `apps/web`.
- [ ] Add scripts:

```json
{
  "scripts": {
    "dev": "concurrently \"npm:dev:server\" \"npm:dev:web\"",
    "dev:server": "tsx apps/server/src/index.ts",
    "dev:web": "vite --host 127.0.0.1",
    "test": "vitest run",
    "typecheck": "tsc --noEmit"
  }
}
```

- [ ] Implement health endpoint:

```text
GET /api/health -> { "ok": true, "app": "codex-monitor" }
```

Verification:

```powershell
npm run dev
```

Expected: server and web start locally.

## Phase 2: Codex JSONL Scanner

- [ ] Implement `codex-jsonl-scanner.ts`.

Responsibilities:

- Walk `~/.codex/sessions/**/*.jsonl`.
- Parse each line as JSON.
- Never fail a whole file because one line is malformed.
- Return raw normalized records with `timestamp`, `type`, `payload`, `filePath`, `lineNumber`.
- Track file `mtime` and `size`.

- [ ] Tests:

```text
parses session_meta
parses turn_context
parses event_msg.token_count
skips malformed lines
keeps line numbers
keeps source file path
```

Verification:

```powershell
npm test -- codex-jsonl-scanner
```

Expected: scanner tests pass.

## Phase 3: Event Normalizer

- [ ] Implement `codex-event-normalizer.ts`.

Normalize:

- `session_meta` -> session base fields.
- `turn_context` -> turn model/cwd/sandbox context.
- `event_msg.task_started` -> turn start.
- `event_msg.task_complete` -> turn completion and duration.
- `event_msg.token_count` -> usage event.
- `event_msg.agent_message` -> last agent message.
- `response_item.function_call` -> tool call.
- `response_item.function_call_output` -> tool result.
- `response_item.web_search_call` -> web search event.

- [ ] Tests:

```text
builds a session from session_meta
counts turns from task_started
marks turn complete from task_complete
extracts token_count.last_token_usage
extracts token_count.total_token_usage
extracts rate limit fields
extracts function_call_output exit code when present
does not expose encrypted_content
```

Verification:

```powershell
npm test -- codex-event-normalizer
```

Expected: normalizer tests pass.

## Phase 4: Status Inference

- [ ] Implement `codex-status.ts`.

Inputs:

```ts
{
  latestEventType?: string;
  latestTurnStartedAt?: string;
  latestTurnCompletedAt?: string;
  latestFileMtime: string;
  failedToolCalls: number;
  now: string;
}
```

Output:

```ts
CodexSessionStatus
```

- [ ] Tests:

```text
running when latest turn started and not completed
completed when latest turn completed
recent when mtime is fresh but no task state exists
stale when mtime is old and latest turn has not completed
errored when failedToolCalls > 0 and the failure is recent
unknown when insufficient data
```

Verification:

```powershell
npm test -- codex-status
```

Expected: status tests pass.

## Phase 5: Config Scanner

- [ ] Implement `codex-config-scanner.ts`.

Responsibilities:

- Parse `~/.codex/config.toml`.
- Extract default model.
- Extract `model_reasoning_effort`.
- Extract `[projects.<path>]` trust levels.
- Extract `[windows] sandbox`.
- Extract `[mcp_servers.<name>]` command and args.
- Extract env key names without exposing env values.
- Extract tool approval modes.

- [ ] MCP command status:

```text
configured       command exists or is shell-resolvable
missing-command  command is absent and not shell-resolvable
invalid-config   config cannot be parsed
unknown          not enough information
```

- [ ] Tests:

```text
parses model and effort
parses trusted projects
parses windows sandbox
parses MCP command and args
redacts MCP env values
parses MCP tool approval mode
marks missing command
```

Verification:

```powershell
npm test -- codex-config-scanner
```

Expected: config scanner tests pass.

## Phase 6: SQLite Store

- [ ] Add SQLite schema.

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
  originator TEXT,
  cli_version TEXT,
  model_provider TEXT,
  model TEXT,
  effort TEXT,
  started_at TEXT NOT NULL,
  last_updated_at TEXT NOT NULL,
  status TEXT NOT NULL,
  turns INTEGER NOT NULL DEFAULT 0,
  tool_calls INTEGER NOT NULL DEFAULT 0,
  failed_tool_calls INTEGER NOT NULL DEFAULT 0,
  total_input_tokens INTEGER NOT NULL DEFAULT 0,
  total_cached_input_tokens INTEGER NOT NULL DEFAULT 0,
  total_output_tokens INTEGER NOT NULL DEFAULT 0,
  total_reasoning_output_tokens INTEGER NOT NULL DEFAULT 0,
  total_tokens INTEGER NOT NULL DEFAULT 0,
  context_window INTEGER,
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
  cwd TEXT,
  input_tokens INTEGER NOT NULL DEFAULT 0,
  cached_input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  reasoning_output_tokens INTEGER NOT NULL DEFAULT 0,
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

- [ ] Implement incremental scan:

```text
skip unchanged file when path + mtime + size matches scan_files
rescan changed file
delete and rebuild derived rows for that session file
```

Verification:

```powershell
npm test -- session-store
```

Expected: store tests pass.

## Phase 7: Local API

- [ ] Implement endpoints:

```text
GET /api/sessions
GET /api/sessions/:id
GET /api/usage/summary
GET /api/usage/daily
GET /api/tools
GET /api/config
POST /api/actions/open-folder
POST /api/actions/open-editor
POST /api/actions/copy-path
POST /api/scan
```

- [ ] API behavior:

```text
/api/sessions supports status, project, date filters
/api/tools supports failedOnly filter
/api/config never returns secret env values
/api/scan triggers incremental rescan
```

Verification:

```powershell
npm run dev:server
```

Expected: endpoints return local Codex data.

## Phase 8: Web UI

- [ ] Dashboard page.

Show:

- Active/recent/completed/stale/error counts.
- Current model.
- Today's token total.
- 5h and 7d rate-limit bars.
- Recent sessions.
- Recent failed tool calls.

- [ ] Sessions page.

Columns:

```text
Status | Project | Model | Turns | Tokens | Tools | Updated | Actions
```

Actions:

```text
Open folder
Open editor
Copy session path
View details
```

- [ ] Session detail page.

Show:

- Session metadata.
- Turns.
- token_count events.
- tool events.
- final/last agent message.
- source JSONL path.

- [ ] Usage page.

Show:

- Daily tokens.
- Project ranking.
- Model breakdown.
- cached vs non-cached input.
- reasoning output tokens.

- [ ] Tools page.

Show:

- function calls.
- shell commands.
- web searches.
- failed outputs.

- [ ] Config page.

Show:

- model config.
- trusted projects.
- Windows sandbox.
- MCP servers.
- env key names only.

Verification:

```powershell
npm run dev
```

Expected: UI loads real Codex data and no secrets are shown.

## Phase 9: Windows Actions

- [ ] Implement open folder.

Command:

```powershell
explorer.exe "<cwd>"
```

- [ ] Implement open editor.

Preferred commands:

```powershell
code "<cwd>"
cursor "<cwd>"
windsurf "<cwd>"
```

Behavior:

- Try available editor in configured order.
- Return readable error if none exists.

- [ ] Implement copy session path.

Use clipboard API from server-side helper or browser fallback.

Verification:

- Known project opens in Explorer.
- Known project opens in installed editor.
- Missing editor reports an error in UI.

## Phase 10: File Watcher and Live Refresh

- [ ] Watch:

```text
~/.codex/sessions
~/.codex/history.jsonl
~/.codex/config.toml
```

- [ ] Debounce changes by 500-1000 ms.
- [ ] Trigger incremental scan.
- [ ] Push updates via SSE or WebSocket.

Verification:

- Start a Codex turn.
- JSONL file mtime changes.
- Dashboard updates without manual refresh.

## Phase 11: Desktop Wrapper

Only start after Web version is useful.

- [ ] Add Tauri.
- [ ] Add system tray.
- [ ] Tray menu:

```text
Open Codex Monitor
Recent sessions
Running/recent count
Rescan
Quit
```

- [ ] Windows notifications:

```text
turn completed
tool failed
rate-limit high
```

- [ ] Investigate window focus:

```text
match by cwd in terminal title if available
match by process tree if available
fallback to opening editor/folder
```

## Open Questions

- Codex 是否有官方稳定的 resume 命令或 session reopen 入口；第一版只复制 session path，不假设 resume。
- `state_5.sqlite` 和 `logs_2.sqlite` 是否有比 JSONL 更稳定的索引；第一版不依赖，后续调研。
- `history.jsonl` 与 sessions JSONL 如何关联；第一版用于补充用户 prompt 摘要，不能作为主数据。
- token_count 是否每轮都出现；若缺失，需要从相邻 total 做差值估算。
- Windows Terminal tab 精准聚焦的收益是否大于实现复杂度。
- 是否需要支持 WSL 路径和 Windows 路径互转。

## Success Criteria

第一版完成标准：

- 能在 Windows 浏览器打开 Codex Monitor。
- 能扫描 `~/.codex/sessions` 并列出真实会话。
- 能显示每个会话的项目、模型、turn 数、最后更新时间和状态。
- 能从 `token_count` 显示 token 和 rate-limit 使用情况。
- 能显示最近失败的工具调用。
- 能只读展示 `config.toml` 中的 model、projects、MCP servers。
- 不展示 API key 或其他 env 明文。
- 不修改 `~/.codex/config.toml`。
- 能打开项目目录或编辑器。

## Recommended First Implementation Order

1. Codex JSONL scanner。
2. Event normalizer。
3. Status inference。
4. Config TOML scanner。
5. SQLite store。
6. Local API。
7. Web dashboard。
8. Windows actions。
9. File watcher/live refresh。
10. Tauri tray。
