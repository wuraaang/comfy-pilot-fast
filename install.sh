#!/bin/bash
# Comfy Pilot Fast Install
# Installs comfy-pilot with bug fixes for cloud environments (RunPod, etc.)
# + multi-backend support (Claude Code + OpenCode)
set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Comfy Pilot Fast Install ===${NC}"

# Detect ComfyUI path
if [ -n "$1" ]; then
    COMFYUI_DIR="$1"
elif [ -d "/workspace/runpod-slim/ComfyUI" ]; then
    COMFYUI_DIR="/workspace/runpod-slim/ComfyUI"
elif [ -d "/workspace/ComfyUI" ]; then
    COMFYUI_DIR="/workspace/ComfyUI"
elif [ -d "$HOME/ComfyUI" ]; then
    COMFYUI_DIR="$HOME/ComfyUI"
else
    echo -e "${RED}ComfyUI not found. Usage: ./install.sh /path/to/ComfyUI${NC}"
    exit 1
fi

CUSTOM_NODES="$COMFYUI_DIR/custom_nodes"
PLUGIN_DIR="$CUSTOM_NODES/comfy-pilot"

echo -e "${GREEN}ComfyUI found at:${NC} $COMFYUI_DIR"

# Check if already installed
if [ -d "$PLUGIN_DIR" ]; then
    echo -e "${YELLOW}comfy-pilot already exists, updating...${NC}"
    cd "$PLUGIN_DIR"
    git pull origin main 2>/dev/null || true
else
    echo -e "${GREEN}Cloning comfy-pilot...${NC}"
    git clone https://github.com/ConstantineB6/comfy-pilot.git "$PLUGIN_DIR"
fi

# Apply bug fixes
echo -e "${GREEN}Applying fixes (terminal crash, permissions, nested sessions, session persistence, multi-backend)...${NC}"

cd "$PLUGIN_DIR"

# Fix 1: Remove CLAUDECODE env var from PTY to prevent nested session error
if ! grep -q 'env.pop("CLAUDECODE"' __init__.py; then
    sed -i '/env\["COLORTERM"\] = "truecolor"/a\            # Remove CLAUDECODE to prevent "nested session" detection\n            env.pop("CLAUDECODE", None)' __init__.py
    echo -e "  ${GREEN}[1/5]${NC} Fixed: CLAUDECODE nested session prevention"
else
    echo -e "  ${GREEN}[1/5]${NC} Already patched: CLAUDECODE fix"
fi

# Fix 2: Use --dangerously-skip-permissions + remove -c flag
if grep -q 'return f"{claude_path} -c"' __init__.py; then
    python3 - <<'PYFIX'
import re

with open("__init__.py", "r") as f:
    content = f.read()

old_func = '''def get_claude_command(working_dir=None):
    """Get the appropriate claude command based on whether a conversation exists.

    Returns the full path to claude if found via find_executable, otherwise just 'claude'.
    """
    # Try to get the full path to claude
    claude_path = find_executable("claude")
    if claude_path:
        if has_claude_conversation(working_dir):
            return f"{claude_path} -c"
        else:
            return claude_path
    else:
        # Fallback - let the shell try to find it
        if has_claude_conversation(working_dir):
            return "claude -c"
        else:
            return "claude"'''

new_func = '''def get_claude_command(working_dir=None):
    """Get the appropriate claude command for the embedded terminal.

    Returns the full path to claude with --dangerously-skip-permissions
    to avoid blocking permission prompts in the embedded terminal.
    Uses --continue to resume the last conversation across ComfyUI restarts.
    """
    # Try to get the full path to claude
    claude_path = find_executable("claude")
    if not claude_path:
        claude_path = "claude"

    # Always use --dangerously-skip-permissions for embedded terminal
    # (permission prompts don't work well in the xterm.js widget)
    # --continue resumes the last conversation so MCP context survives restarts
    return f"{claude_path} --dangerously-skip-permissions --continue"'''

content = content.replace(old_func, new_func)

with open("__init__.py", "w") as f:
    f.write(content)
PYFIX
    echo -e "  ${GREEN}[2/5]${NC} Fixed: permissions bypass + session resume"
else
    echo -e "  ${GREEN}[2/5]${NC} Already patched: permissions fix"
fi

# Fix 3: Add WebSocket heartbeat to prevent proxy timeout disconnections
if ! grep -q 'heartbeat=' __init__.py; then
    sed -i 's/ws = web.WebSocketResponse()/ws = web.WebSocketResponse(heartbeat=20, autoping=True)/' __init__.py
    echo -e "  ${GREEN}[3/5]${NC} Fixed: WebSocket keepalive (heartbeat every 20s)"
else
    echo -e "  ${GREEN}[3/5]${NC} Already patched: WebSocket keepalive"
fi

# Fix 4: Add --continue flag for session persistence across restarts
if grep -q 'dangerously-skip-permissions"' __init__.py && ! grep -q '\-\-continue' __init__.py; then
    sed -i 's/--dangerously-skip-permissions"/--dangerously-skip-permissions --continue"/' __init__.py
    echo -e "  ${GREEN}[4/5]${NC} Fixed: session persistence (--continue)"
else
    echo -e "  ${GREEN}[4/5]${NC} Already patched: session persistence"
fi

# Fix 5: Multi-backend support (Claude Code + OpenCode)
if ! grep -q 'BACKEND_OPENCODE' __init__.py; then
    python3 - <<'PYFIX5'
import re

with open("__init__.py", "r") as f:
    content = f.read()

# --- A. Add backend constants + detect_backend() after the platform imports ---

backend_block = '''
# ---------------------------------------------------------------------------
# Backend detection: Claude Code vs OpenCode
# ---------------------------------------------------------------------------
BACKEND_OPENCODE = "opencode"
BACKEND_CLAUDE = "claude"


def detect_backend():
    """Detect which AI backend to use.
    Priority: COMFY_PILOT_BACKEND env var > opencode > claude > fallback claude.
    """
    env = os.environ.get("COMFY_PILOT_BACKEND", "").lower().strip()
    if env in (BACKEND_OPENCODE, BACKEND_CLAUDE):
        return env
    if find_executable("opencode"):
        return BACKEND_OPENCODE
    if find_executable("claude"):
        return BACKEND_CLAUDE
    return BACKEND_CLAUDE


ACTIVE_BACKEND = None  # resolved after find_executable is defined

'''

# Insert after the Windows stubs block
content = content.replace(
    'WEB_DIRECTORY = "./js"',
    backend_block + 'WEB_DIRECTORY = "./js"'
)

# --- B. Add Go/OpenCode paths to find_executable ---

content = content.replace(
    "        # Linux common paths\n"
    '        f"/usr/bin/{name}",',
    "        # Linux common paths\n"
    '        f"/usr/bin/{name}",\n'
    "        # Go / OpenCode\n"
    '        os.path.expanduser(f"~/go/bin/{name}"),\n'
    '        f"/usr/local/go/bin/{name}",\n'
    '        os.path.expanduser(f"~/.opencode/bin/{name}"),'
)

# --- C. Add OpenCode functions after get_claude_command ---

opencode_funcs = '''

# ---------------------------------------------------------------------------
# OpenCode backend helpers
# ---------------------------------------------------------------------------

def install_opencode():
    """Attempt to install OpenCode CLI. Returns (success, message)."""
    import subprocess
    try:
        print("[Comfy Pilot] Installing OpenCode CLI...")
        result = subprocess.run(
            ["bash", "-c", "curl -fsSL https://opencode.ai/install | bash"],
            capture_output=True, text=True, timeout=120,
        )
        if result.returncode == 0:
            print("[Comfy Pilot] OpenCode CLI installed successfully!")
            return True, "OpenCode CLI installed successfully!"
        error_msg = result.stderr or result.stdout or "Unknown error"
        print(f"[Comfy Pilot] OpenCode installation failed: {error_msg}")
        return False, f"Installation failed: {error_msg}"
    except subprocess.TimeoutExpired:
        return False, "Installation timed out after 120 seconds"
    except Exception as e:
        return False, f"Installation error: {str(e)}"


def get_opencode_command(working_dir=None):
    """Get the opencode command. No --dangerously-skip-permissions needed (TUI handles it)."""
    path = find_executable("opencode") or "opencode"
    session_file = os.path.join(os.path.dirname(__file__), ".opencode_session")
    if os.path.exists(session_file):
        try:
            sid = open(session_file).read().strip()
            if sid:
                return f"{path} --session {sid}"
        except OSError:
            pass
    return path


def get_terminal_command(working_dir=None):
    """Dispatcher: return the shell command for the active backend."""
    if ACTIVE_BACKEND == BACKEND_OPENCODE:
        return get_opencode_command(working_dir)
    return get_claude_command(working_dir)


def setup_opencode_mcp_config():
    """Write (or merge) MCP config into opencode.json at ComfyUI root."""
    import json as _json
    plugin_dir = os.path.dirname(os.path.abspath(__file__))
    mcp_server_path = os.path.join(plugin_dir, "mcp_server.py")
    python_path = sys.executable
    comfyui_root = os.path.abspath(os.path.join(plugin_dir, "..", ".."))
    config_path = os.path.join(comfyui_root, "opencode.json")
    new_entry = {"comfyui": {"type": "local", "command": [python_path, mcp_server_path], "enabled": True, "timeout": 10000}}
    config = {}
    if os.path.exists(config_path):
        try:
            with open(config_path, "r") as f:
                config = _json.load(f)
        except Exception:
            pass
    mcp_section = config.get("mcp", {})
    if "comfyui" in mcp_section:
        print("[Comfy Pilot] OpenCode MCP 'comfyui' already configured")
        return
    mcp_section.update(new_entry)
    config["mcp"] = mcp_section
    try:
        with open(config_path, "w") as f:
            _json.dump(config, f, indent=2)
        print(f"[Comfy Pilot] OpenCode MCP config written to {config_path}")
    except OSError as e:
        print(f"[Comfy Pilot] Failed to write OpenCode config: {e}")


async def capture_opencode_session_id():
    """Capture the session ID from the most recent OpenCode session."""
    import subprocess as _sp
    import json as _json
    await asyncio.sleep(8)
    session_file = os.path.join(os.path.dirname(__file__), ".opencode_session")
    if os.path.exists(session_file):
        return
    opencode_path = find_executable("opencode") or "opencode"
    try:
        result = _sp.run(
            [opencode_path, "session", "list", "--format", "json", "-n", "1"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip():
            data = _json.loads(result.stdout)
            sid = ""
            if isinstance(data, list) and data:
                sid = data[0].get("id", "")
            elif isinstance(data, dict):
                sid = data.get("id", "")
            if sid:
                with open(session_file, "w") as f:
                    f.write(str(sid))
                print(f"[Comfy Pilot] OpenCode session ID captured: {sid}")
    except Exception as e:
        print(f"[Comfy Pilot] Could not capture OpenCode session ID: {e}")

'''

# Insert after get_claude_command function (find the class WebSocketTerminal)
content = content.replace(
    '\nclass WebSocketTerminal:',
    opencode_funcs + '\nclass WebSocketTerminal:'
)

# --- D. Update websocket_handler to use dispatchers ---

# Replace get_claude_command() call with get_terminal_command()
content = content.replace(
    'command = get_claude_command()',
    'command = get_terminal_command()'
)

# Replace install fallback
content = content.replace(
    'success, message = install_claude_code()',
    'success, message = install_opencode() if ACTIVE_BACKEND == BACKEND_OPENCODE else install_claude_code()'
)

# Replace session capture dispatch
content = content.replace(
    'asyncio.create_task(capture_session_id())',
    'asyncio.create_task(capture_opencode_session_id() if ACTIVE_BACKEND == BACKEND_OPENCODE else capture_session_id())'
)

# --- E. Update setup_mcp_config to dispatch ---

old_mcp_start = 'def setup_mcp_config():\n    """Set up MCP server configuration for Claude Code using claude mcp add."""'
new_mcp_start = '''def setup_mcp_config():
    """Set up MCP server configuration for the active backend."""
    if ACTIVE_BACKEND == BACKEND_OPENCODE:
        setup_opencode_mcp_config()
        return
    # --- Claude Code path ---'''

content = content.replace(old_mcp_start, new_mcp_start)

# --- F. Add backend to platform endpoint ---

content = content.replace(
    '        "comfyui_url": get_comfyui_url_cached()\n    })',
    '        "comfyui_url": get_comfyui_url_cached(),\n        "backend": ACTIVE_BACKEND,\n    })'
)

# --- G. Resolve ACTIVE_BACKEND before server setup ---

content = content.replace(
    '# Hook into ComfyUI\'s server setup',
    '# Resolve active backend\nACTIVE_BACKEND = detect_backend()\n\n# Hook into ComfyUI\'s server setup'
)

# --- H. Update logs ---

content = content.replace('[Claude Code]', '[Comfy Pilot]')

# --- I. Update JS cosmetics ---

js_path = "js/claude-code.js"
with open(js_path, "r") as f:
    js = f.read()

# Add backendLabel variable
js = js.replace(
    'let claudeRunning = false;',
    'let claudeRunning = false;\n\n// Active backend label (resolved from /claude-code/platform)\nlet backendLabel = "Comfy Pilot";'
)

# Fetch backend on setup
js = js.replace(
    'console.log("Claude Code extension loading...");',
    'console.log("[Comfy Pilot] Extension loading...");\n\n'
    '        // Fetch backend info\n'
    '        try {\n'
    '            const resp = await fetch("/claude-code/platform");\n'
    '            if (resp.ok) {\n'
    '                const info = await resp.json();\n'
    '                backendLabel = info.backend === "opencode" ? "OpenCode" : "Claude Code";\n'
    '            }\n'
    '        } catch (_) { /* non-fatal */ }'
)

js = js.replace('console.log("Claude Code extension loaded");', 'console.log("[Comfy Pilot] Extension loaded");')
js = js.replace('<span class="claude-title">Claude Code</span>', '<span class="claude-title">${backendLabel}</span>')
js = js.replace('btn.textContent = "Claude Code";', 'btn.textContent = "Comfy Pilot";')
js = js.replace('content: "Open Claude Code"', 'content: "Open Comfy Pilot"')
js = js.replace('[Claude Code]', '[Comfy Pilot]')

with open(js_path, "w") as f:
    f.write(js)

with open("__init__.py", "w") as f:
    f.write(content)

PYFIX5
    echo -e "  ${GREEN}[5/5]${NC} Patched: multi-backend support (Claude Code + OpenCode)"
else
    echo -e "  ${GREEN}[5/5]${NC} Already patched: multi-backend support"
fi

# Restart ComfyUI if running
echo ""
COMFY_PID=$(pgrep -f "python.*main.py.*--port" 2>/dev/null | head -1)
if [ -n "$COMFY_PID" ]; then
    echo -e "${YELLOW}ComfyUI is running (PID $COMFY_PID). Restart required.${NC}"
    read -p "Restart now? [Y/n] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        kill "$COMFY_PID" 2>/dev/null
        sleep 3
        cd "$COMFYUI_DIR"
        PYTHON=$(command -v python3 || command -v python)
        env -u CLAUDECODE nohup "$PYTHON" main.py --listen 0.0.0.0 --port 8188 > "$(dirname "$COMFYUI_DIR")/comfyui.log" 2>&1 &
        echo -e "${GREEN}ComfyUI restarted (PID $!)${NC}"
        sleep 10
        echo -e "${GREEN}Ready!${NC} Open http://0.0.0.0:8188 in your browser"
    else
        echo -e "${YELLOW}Remember to restart ComfyUI manually.${NC}"
    fi
else
    echo -e "${YELLOW}ComfyUI is not running. Start it with:${NC}"
    echo "  cd $COMFYUI_DIR && env -u CLAUDECODE python3 main.py --listen 0.0.0.0 --port 8188"
fi

echo ""
echo -e "${GREEN}=== Installation complete ===${NC}"
echo -e "Open ComfyUI and look for the Comfy Pilot button in the toolbar."
echo -e "Backend auto-detected: set COMFY_PILOT_BACKEND=opencode or COMFY_PILOT_BACKEND=claude to force."
