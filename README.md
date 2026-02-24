# comfy-pilot-fast

Fast install script for [Comfy Pilot](https://github.com/ConstantineB6/comfy-pilot) with critical bug fixes for cloud environments (RunPod, etc.) and **multi-backend support** (Claude Code + OpenCode).

Comfy Pilot adds an AI coding agent terminal directly inside ComfyUI with an MCP server that gives the agent full access to your workflow (create/delete/connect nodes, execute, view images).

## What this fixes

The original plugin has bugs that cause the embedded terminal to crash or disconnect on cloud setups:

| Bug | Symptom | Fix |
|-----|---------|-----|
| `CLAUDECODE` env var leaks into PTY | `Error: Claude Code cannot be launched inside another Claude Code session` | Strip the variable from child process env |
| No `--dangerously-skip-permissions` | Terminal hangs on permission prompts (can't click Accept/Reject in xterm.js) | Auto-add the flag |
| `claude -c` resumes active sessions | Immediate crash when another Claude session exists in the same directory | Always start fresh sessions |
| No WebSocket heartbeat | Terminal disconnects after ~30-60s of inactivity (proxy timeout) | Add `heartbeat=20` keepalive ping |
| No session persistence | Lose all context on ComfyUI restart | `--continue` flag + resume prompt + auto-reconnect |
| Claude Code only | No way to use other AI backends | Multi-backend: auto-detect Claude Code or OpenCode |

These fixes are proposed upstream via [PR](https://github.com/ConstantineB6/comfy-pilot/pulls) and relate to [issue #9](https://github.com/ConstantineB6/comfy-pilot/issues/9).

## Multi-Backend Support

The install script patches Comfy Pilot to support **both Claude Code and OpenCode** as backends. The plugin auto-detects which one is installed and adapts automatically.

| | Claude Code | OpenCode |
|---|---|---|
| **MCP config** | `claude mcp add` (automatic) | `opencode.json` written automatically |
| **Permissions** | `--dangerously-skip-permissions` | Native TUI (a/A/d keys) |
| **Session resume** | `--resume <uuid>` | `--session <id>` |
| **Install** | `curl -fsSL https://claude.ai/install.sh \| bash` | `curl -fsSL https://opencode.ai/install \| bash` |

**Detection order:** `COMFY_PILOT_BACKEND` env var > `opencode` on PATH > `claude` on PATH > fallback to Claude Code.

```bash
# Force a specific backend
export COMFY_PILOT_BACKEND=opencode   # or claude
```

## Install (one command)

```bash
curl -fsSL https://raw.githubusercontent.com/wuraaang/comfy-pilot-fast/main/install.sh | bash
```

Or with a custom ComfyUI path:

```bash
curl -fsSL https://raw.githubusercontent.com/wuraaang/comfy-pilot-fast/main/install.sh | bash -s /path/to/ComfyUI
```

## Manual install

```bash
# 1. Clone into custom_nodes
cd /path/to/ComfyUI/custom_nodes
git clone https://github.com/ConstantineB6/comfy-pilot.git comfy-pilot

# 2. Apply fixes
cd comfy-pilot
# Download and run the patch
curl -fsSL https://raw.githubusercontent.com/wuraaang/comfy-pilot-fast/main/install.sh | bash -s /path/to/ComfyUI

# 3. Restart ComfyUI (important: unset CLAUDECODE)
cd /path/to/ComfyUI
env -u CLAUDECODE python3 main.py --listen 0.0.0.0 --port 8188
```

## Usage

1. Open ComfyUI in your browser
2. Click the **Comfy Pilot** button in the toolbar (or right-click canvas > "Open Comfy Pilot")
3. A floating terminal opens with your AI agent connected via MCP
4. The green MCP indicator confirms the connection
5. Ask the agent to manipulate your workflow: *"add a KSampler connected to a checkpoint loader"*

The window title shows which backend is active (Claude Code or OpenCode).

## What it does

```
ComfyUI Browser UI
    │
    ├── Comfy Pilot button (toolbar)
    │       │
    │       └── Floating xterm.js terminal
    │               │
    │               └── Claude Code CLI  or  OpenCode TUI
    │                       │
    │                       └── MCP Server (15 tools)
    │                               │
    │                               ├── get_workflow / sync_workflow
    │                               ├── create_node / delete_node / connect_nodes
    │                               ├── set_node_property / move_node
    │                               ├── queue_prompt / interrupt
    │                               ├── get_images / get_history
    │                               └── ...
    │
    └── WebSocket /ws/claude-terminal
    └── REST API /claude-code/*
```

## Endpoints registered

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/ws/claude-terminal` | WS | Terminal PTY over WebSocket |
| `/claude-code/workflow` | GET/POST | Read/sync current workflow |
| `/claude-code/graph-command` | GET/POST | Graph manipulation commands |
| `/claude-code/run-node` | POST | Execute workflow up to a node |
| `/claude-code/mcp-status` | GET | MCP connection status |
| `/claude-code/memory` | GET | Plugin memory stats |
| `/claude-code/platform` | GET | Platform info + active backend |

## Requirements

- ComfyUI (any recent version)
- **Claude Code CLI** or **OpenCode CLI** (auto-installed if missing)
- Linux (PTY required for the terminal; Windows not supported)

## Troubleshooting

### Terminal disconnects immediately
This is what the fixes in this repo solve. Make sure you ran the install script and restarted ComfyUI.

### Terminal disconnects after inactivity
The install script adds a WebSocket heartbeat (ping every 20s) that keeps the connection alive through proxies (RunPod, Cloudflare, etc.). If you still have issues, it may be your browser's network settings.

### Backend not detected
Check the ComfyUI console for which backend was picked:
```
[Comfy Pilot] Plugin loaded successfully — backend: OpenCode (Memory: 32.3MB)
```
Force a backend with `COMFY_PILOT_BACKEND=opencode` or `COMFY_PILOT_BACKEND=claude`.

### "Command 'claude' not found"
The plugin auto-installs Claude Code CLI. If that fails:
```bash
curl -fsSL https://claude.ai/install.sh | bash
```

### "Command 'opencode' not found"
```bash
curl -fsSL https://opencode.ai/install | bash
```

### MCP indicator stays red

**Claude Code:**
```bash
claude mcp list
# Should show comfyui: ✓ Connected. If not:
claude mcp add comfyui python3 /path/to/ComfyUI/custom_nodes/comfy-pilot/mcp_server.py
```

**OpenCode:** Check that `opencode.json` exists at ComfyUI root:
```bash
cat /path/to/ComfyUI/opencode.json
# Should contain mcp.comfyui config. The plugin creates it automatically.
```

### ComfyUI started from Claude Code session
Always start ComfyUI with `env -u CLAUDECODE` to prevent the nested session error:
```bash
env -u CLAUDECODE python3 main.py --listen 0.0.0.0 --port 8188
```
