# comfy-pilot-fast

Fast install script for [Comfy Pilot](https://github.com/ConstantineB6/comfy-pilot) with critical bug fixes for cloud environments (RunPod, etc.).

Comfy Pilot adds a Claude Code terminal directly inside ComfyUI with an MCP server that gives Claude full access to your workflow (create/delete/connect nodes, execute, view images).

## What this fixes

The original plugin has bugs that cause the embedded terminal to crash or disconnect on cloud setups:

| Bug | Symptom | Fix |
|-----|---------|-----|
| `CLAUDECODE` env var leaks into PTY | `Error: Claude Code cannot be launched inside another Claude Code session` | Strip the variable from child process env |
| No `--dangerously-skip-permissions` | Terminal hangs on permission prompts (can't click Accept/Reject in xterm.js) | Auto-add the flag |
| `claude -c` resumes active sessions | Immediate crash when another Claude session exists in the same directory | Always start fresh sessions |
| No WebSocket heartbeat | Terminal disconnects after ~30-60s of inactivity (proxy timeout) | Add `heartbeat=20` keepalive ping |

These fixes are proposed upstream via [PR](https://github.com/ConstantineB6/comfy-pilot/pulls) and relate to [issue #9](https://github.com/ConstantineB6/comfy-pilot/issues/9).

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
2. Click the **Claude Code** button in the toolbar (or right-click canvas)
3. A floating terminal opens with Claude Code connected via MCP
4. The green MCP indicator confirms the connection
5. Ask Claude to manipulate your workflow: *"add a KSampler connected to a checkpoint loader"*

## What it does

```
ComfyUI Browser UI
    │
    ├── Claude Code button (toolbar)
    │       │
    │       └── Floating xterm.js terminal
    │               │
    │               └── Claude Code CLI (--dangerously-skip-permissions)
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
| `/claude-code/platform` | GET | Platform info |

## Requirements

- ComfyUI (any recent version)
- Claude Code CLI (`npm install -g @anthropic-ai/claude-code` or auto-installed)
- Linux (PTY required for the terminal; Windows not supported)
- Active Claude subscription

## Troubleshooting

### Terminal disconnects immediately
This is what the fixes in this repo solve. Make sure you ran the install script and restarted ComfyUI.

### Terminal disconnects after inactivity
The install script adds a WebSocket heartbeat (ping every 20s) that keeps the connection alive through proxies (RunPod, Cloudflare, etc.). If you still have issues, it may be your browser's network settings.

### "Command 'claude' not found"
The plugin auto-installs Claude Code CLI. If that fails:
```bash
npm install -g @anthropic-ai/claude-code
```

### MCP indicator stays red
Check that the MCP server was registered:
```bash
claude mcp list
```
You should see `comfyui: ✓ Connected`. If not:
```bash
claude mcp add comfyui python3 /path/to/ComfyUI/custom_nodes/comfy-pilot/mcp_server.py
```

### ComfyUI started from Claude Code session
Always start ComfyUI with `env -u CLAUDECODE` to prevent the nested session error:
```bash
env -u CLAUDECODE python3 main.py --listen 0.0.0.0 --port 8188
```
