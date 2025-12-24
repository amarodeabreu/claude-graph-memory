#!/bin/bash
# Claude Graph Memory Uninstaller

set -euo pipefail

INSTALL_DIR="$HOME/.claude-graph-memory"
CLAUDE_DIR="$HOME/.claude"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          Claude Graph Memory Uninstaller                   ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

read -p "This will remove NornicDB and all graph data. Continue? (y/N) " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "Stopping NornicDB..."
if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    cd "$INSTALL_DIR"
    docker-compose down -v 2>/dev/null || true
    echo "  ✓ Container stopped and volume removed"
else
    docker stop nornicdb 2>/dev/null || true
    docker rm nornicdb 2>/dev/null || true
    docker volume rm nornicdb_data 2>/dev/null || true
    echo "  ✓ Container removed"
fi

echo ""
echo "Removing scripts..."
rm -f "$CLAUDE_DIR/scripts/neo4j-context.sh"
rm -f "$CLAUDE_DIR/scripts/populate-doc-graph.py"
rm -f "$CLAUDE_DIR/scripts/populate-code-graph.go"
rm -f "$HOME/.local/bin/claude-graph"
echo "  ✓ Scripts removed"

echo ""
echo "Cleaning up configurations..."

# Remove MCP servers from ~/.claude.json
if [ -f "$HOME/.claude.json" ]; then
    python3 << 'PYTHON_EOF'
import json
from pathlib import Path

config_path = Path.home() / '.claude.json'
config = json.loads(config_path.read_text())

if 'mcpServers' in config:
    config['mcpServers'].pop('neo4j-memory', None)
    config['mcpServers'].pop('neo4j-cypher', None)
    if not config['mcpServers']:
        del config['mcpServers']

config_path.write_text(json.dumps(config, indent=2))
PYTHON_EOF
    echo "  ✓ Removed MCP servers from ~/.claude.json"
fi

# Remove hooks from ~/.claude/settings.json
if [ -f "$CLAUDE_DIR/settings.json" ]; then
    python3 << 'PYTHON_EOF'
import json
from pathlib import Path

config_path = Path.home() / '.claude' / 'settings.json'
config = json.loads(config_path.read_text())

if 'hooks' in config:
    # Remove our hooks
    if 'SessionStart' in config['hooks']:
        config['hooks']['SessionStart'] = [
            h for h in config['hooks']['SessionStart']
            if not any('neo4j-context.sh' in hook.get('command', '')
                      for hook in h.get('hooks', []))
        ]
        if not config['hooks']['SessionStart']:
            del config['hooks']['SessionStart']

    if 'PostToolUse' in config['hooks']:
        config['hooks']['PostToolUse'] = [
            h for h in config['hooks']['PostToolUse']
            if not any('neo4j-context.sh' in hook.get('command', '')
                      for hook in h.get('hooks', []))
        ]
        if not config['hooks']['PostToolUse']:
            del config['hooks']['PostToolUse']

    if not config['hooks']:
        del config['hooks']

if 'permissions' in config and 'allow' in config['permissions']:
    config['permissions']['allow'] = [
        p for p in config['permissions']['allow']
        if not p.startswith('mcp__neo4j')
    ]

config_path.write_text(json.dumps(config, indent=2))
PYTHON_EOF
    echo "  ✓ Removed hooks from ~/.claude/settings.json"
fi

# Remove install directory
rm -rf "$INSTALL_DIR"
echo "  ✓ Removed $INSTALL_DIR"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                  Uninstall Complete!                       ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Claude Graph Memory has been removed."
echo "Restart Claude Code to complete the cleanup."
echo ""
