#!/bin/bash
# Claude Graph Memory Installer
# Sets up NornicDB and Claude Code integration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.claude-graph-memory"
CLAUDE_DIR="$HOME/.claude"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║           Claude Graph Memory Installer                    ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check dependencies
echo "Checking dependencies..."

if ! command -v docker &>/dev/null; then
    echo "❌ Docker not found. Please install Docker first."
    echo "   https://docs.docker.com/get-docker/"
    exit 1
fi
echo "  ✓ Docker"

if ! command -v python3 &>/dev/null; then
    echo "❌ Python 3 not found. Please install Python 3.9+."
    exit 1
fi
echo "  ✓ Python 3"

# Check for uv/uvx (for MCP servers)
if ! command -v uvx &>/dev/null; then
    echo "  Installing uv (Python package manager)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi
echo "  ✓ uv/uvx"

# Install neo4j Python driver
echo "  Installing neo4j Python driver..."
pip3 install --quiet neo4j 2>/dev/null || pip3 install neo4j

echo ""
echo "Setting up NornicDB..."

# Create install directory
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/docker-compose.yml" "$INSTALL_DIR/"

# Start NornicDB
cd "$INSTALL_DIR"
docker-compose up -d

# Wait for NornicDB to be ready
echo "  Waiting for NornicDB to start..."
for i in {1..30}; do
    if nc -z localhost 7687 2>/dev/null; then
        echo "  ✓ NornicDB is running"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "  ⚠ NornicDB taking longer than expected. Check: docker logs nornicdb"
    fi
    sleep 1
done

echo ""
echo "Installing scripts..."

# Create Claude scripts directory
mkdir -p "$CLAUDE_DIR/scripts"

# Copy scripts
cp "$SCRIPT_DIR/scripts/neo4j-context.sh" "$CLAUDE_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/populate-doc-graph.py" "$CLAUDE_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/populate-code-graph.go" "$CLAUDE_DIR/scripts/" 2>/dev/null || true

# Make executable
chmod +x "$CLAUDE_DIR/scripts/neo4j-context.sh"
chmod +x "$CLAUDE_DIR/scripts/populate-doc-graph.py"

echo "  ✓ Scripts installed to $CLAUDE_DIR/scripts/"

echo ""
echo "Configuring Claude Code..."

# Backup existing configs
[ -f "$CLAUDE_DIR/settings.json" ] && cp "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.json.backup"
[ -f "$HOME/.claude.json" ] && cp "$HOME/.claude.json" "$HOME/.claude.json.backup"

# Get uvx path
UVX_PATH=$(command -v uvx)

# Add MCP servers to ~/.claude.json
if [ -f "$HOME/.claude.json" ]; then
    # Merge with existing config using Python
    python3 << PYTHON_EOF
import json
from pathlib import Path

config_path = Path.home() / '.claude.json'
config = json.loads(config_path.read_text())

if 'mcpServers' not in config:
    config['mcpServers'] = {}

config['mcpServers']['neo4j-memory'] = {
    "type": "stdio",
    "command": "$UVX_PATH",
    "args": ["mcp-neo4j-memory", "--db-url", "bolt://localhost:7687"],
    "env": {}
}

config['mcpServers']['neo4j-cypher'] = {
    "type": "stdio",
    "command": "$UVX_PATH",
    "args": ["mcp-neo4j-cypher", "--transport", "stdio"],
    "env": {"NEO4J_URI": "bolt://localhost:7687"}
}

config_path.write_text(json.dumps(config, indent=2))
print("  ✓ MCP servers added to ~/.claude.json")
PYTHON_EOF
else
    # Create new config
    cat > "$HOME/.claude.json" << EOF
{
  "mcpServers": {
    "neo4j-memory": {
      "type": "stdio",
      "command": "$UVX_PATH",
      "args": ["mcp-neo4j-memory", "--db-url", "bolt://localhost:7687"],
      "env": {}
    },
    "neo4j-cypher": {
      "type": "stdio",
      "command": "$UVX_PATH",
      "args": ["mcp-neo4j-cypher", "--transport", "stdio"],
      "env": {"NEO4J_URI": "bolt://localhost:7687"}
    }
  }
}
EOF
    echo "  ✓ Created ~/.claude.json with MCP servers"
fi

# Add global hooks to ~/.claude/settings.json
if [ -f "$CLAUDE_DIR/settings.json" ]; then
    python3 << PYTHON_EOF
import json
from pathlib import Path

config_path = Path.home() / '.claude' / 'settings.json'
config = json.loads(config_path.read_text())

if 'hooks' not in config:
    config['hooks'] = {}

config['hooks']['SessionStart'] = [{
    "hooks": [{
        "type": "command",
        "command": "~/.claude/scripts/neo4j-context.sh session-start",
        "timeout": 5
    }]
}]

config['hooks']['PostToolUse'] = [{
    "matcher": "Edit|Write",
    "hooks": [{
        "type": "command",
        "command": "~/.claude/scripts/neo4j-context.sh post-edit",
        "timeout": 5
    }]
}]

if 'permissions' not in config:
    config['permissions'] = {}
if 'allow' not in config['permissions']:
    config['permissions']['allow'] = []

for perm in ['mcp__neo4j-memory__*', 'mcp__neo4j-cypher__*']:
    if perm not in config['permissions']['allow']:
        config['permissions']['allow'].append(perm)

config_path.write_text(json.dumps(config, indent=2))
print("  ✓ Hooks added to ~/.claude/settings.json")
PYTHON_EOF
else
    cat > "$CLAUDE_DIR/settings.json" << 'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/scripts/neo4j-context.sh session-start",
            "timeout": 5
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/scripts/neo4j-context.sh post-edit",
            "timeout": 5
          }
        ]
      }
    ]
  },
  "permissions": {
    "allow": [
      "mcp__neo4j-memory__*",
      "mcp__neo4j-cypher__*"
    ]
  }
}
EOF
    echo "  ✓ Created ~/.claude/settings.json with hooks"
fi

# Create symlink for easy CLI access
echo ""
echo "Creating CLI shortcut..."
mkdir -p "$HOME/.local/bin"
ln -sf "$CLAUDE_DIR/scripts/neo4j-context.sh" "$HOME/.local/bin/claude-graph"
echo "  ✓ Created 'claude-graph' command"

# Check if ~/.local/bin is in PATH
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    echo ""
    echo "⚠ Add ~/.local/bin to your PATH:"
    echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
    echo "  source ~/.zshrc"
fi

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                    Installation Complete!                  ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "NornicDB is running at:"
echo "  • Browser: http://localhost:7474"
echo "  • Bolt:    bolt://localhost:7687"
echo ""
echo "Commands:"
echo "  claude-graph status        - Show graph statistics"
echo "  claude-graph refresh       - Full re-index"
echo "  claude-graph list-projects - List all indexed projects"
echo "  claude-graph help          - Show all commands"
echo ""
echo "Next steps:"
echo "  1. Restart Claude Code to load MCP servers"
echo "  2. Navigate to any project with a /docs folder"
echo "  3. The graph will auto-populate on session start"
echo ""
