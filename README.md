# DevTools

Developer tools and AI workspace orchestrator for macOS. Combines LLM usage telemetry with multi-repository task workspace management for AI coding agents.

## Features

- **Workspaces Tab & `ws` CLI**:
  - Task-isolated multi-repo Git worktrees (`~/workspaces/<TICKET>`).
  - Shared bare clone mirror cache (`~/.cache/ws/repos/`) — instant zero-duplicate checkouts.
  - Automatic cross-repo AST code intelligence indexing via `codebase-memory-mcp`.
  - Auto-configures MCP server for Cursor, Claude Code, and OpenCode.
  - Auto-installs `post-commit` Git hooks to keep the graph fresh on code edits.
  - System Readiness Doctor: 1-click check and fix for `git`, `gh`, `node`, `python3`, `codebase-memory-mcp`, and AI agent CLIs.

- **LLM Usage Tab**:
  - Real-time spend, requests, and token telemetry from Multiplier's LiteLLM Gateway.
  - Rolling 7-day budget tracking with reset countdown.
  - Latency (p50/p95), error rates, and cache hit metrics.
  - Model pricing catalog and 1-click agent configuration model sync (`opencode`, `pi`, `codex`, `hermes`).

---

## Installation

### 1. Build and install locally
```bash
./bin/bundle.sh --install
```
This builds `DevTools.app`, installs it to `/Applications`, and links the CLI tool `ws` to `/usr/local/bin/ws`.

---

## CLI Usage (`ws`)

```bash
# Verify system prerequisites & agents
ws doctor

# Auto-fix missing prerequisites
ws doctor --fix

# Create multi-repo workspace for a JIRA ticket
ws create FINX-1234 multiplier-frontend billing-service

# List active workspaces and dirty git status
ws list

# Re-index semantic code graph via codebase-memory-mcp
ws reindex FINX-1234

# Safely prune workspace when done (checks for uncommitted code)
ws prune FINX-1234
```
