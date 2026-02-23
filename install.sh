#!/bin/bash
# Comfy Pilot Fast Install
# Installs comfy-pilot with bug fixes for cloud environments (RunPod, etc.)
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
echo -e "${GREEN}Applying fixes (terminal crash, permissions, nested sessions)...${NC}"

cd "$PLUGIN_DIR"

# Fix 1: Remove CLAUDECODE env var from PTY to prevent nested session error
if ! grep -q 'env.pop("CLAUDECODE"' __init__.py; then
    sed -i '/env\["COLORTERM"\] = "truecolor"/a\            # Remove CLAUDECODE to prevent "nested session" detection\n            env.pop("CLAUDECODE", None)' __init__.py
    echo -e "  ${GREEN}[1/2]${NC} Fixed: CLAUDECODE nested session prevention"
else
    echo -e "  ${GREEN}[1/2]${NC} Already patched: CLAUDECODE fix"
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
    Always starts a fresh session to avoid conflicts with active conversations.
    """
    # Try to get the full path to claude
    claude_path = find_executable("claude")
    if not claude_path:
        claude_path = "claude"

    # Always use --dangerously-skip-permissions for embedded terminal
    # (permission prompts don't work well in the xterm.js widget)
    return f"{claude_path} --dangerously-skip-permissions"'''

content = content.replace(old_func, new_func)

with open("__init__.py", "w") as f:
    f.write(content)
PYFIX
    echo -e "  ${GREEN}[2/2]${NC} Fixed: permissions bypass + fresh sessions"
else
    echo -e "  ${GREEN}[2/2]${NC} Already patched: permissions fix"
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
echo -e "Open ComfyUI and look for the Claude Code button in the toolbar."
