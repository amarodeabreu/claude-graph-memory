#!/bin/bash
# Verify Claude Graph Memory installation

set -euo pipefail

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          Claude Graph Memory Verification                  ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

PASS=0
FAIL=0

check() {
    local name="$1"
    local cmd="$2"

    if eval "$cmd" &>/dev/null; then
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name"
        FAIL=$((FAIL + 1))
    fi
}

echo "Checking components..."
echo ""

check "Docker installed" "command -v docker"
check "Python 3 installed" "command -v python3"
check "neo4j driver installed" "python3 -c 'import neo4j'"
check "NornicDB container exists" "docker ps -a --format '{{.Names}}' | grep -q nornicdb"
check "NornicDB is running" "docker ps --format '{{.Names}}' | grep -q nornicdb"
check "NornicDB port 7687 open" "nc -z localhost 7687"
check "MCP neo4j-memory configured" "grep -q neo4j-memory ~/.claude.json 2>/dev/null"
check "MCP neo4j-cypher configured" "grep -q neo4j-cypher ~/.claude.json 2>/dev/null"
check "Global hooks configured" "grep -q neo4j-context ~/.claude/settings.json 2>/dev/null"
check "neo4j-context.sh exists" "[ -f ~/.claude/scripts/neo4j-context.sh ]"
check "populate-doc-graph.py exists" "[ -f ~/.claude/scripts/populate-doc-graph.py ]"
check "claude-graph command exists" "command -v claude-graph"

echo ""
echo "───────────────────────────────────────────────────────────────"
echo "  Results: $PASS passed, $FAIL failed"
echo "───────────────────────────────────────────────────────────────"

if [ $FAIL -eq 0 ]; then
    echo ""
    echo "  All checks passed! Installation is complete."
    echo ""

    # Show graph stats if available
    if command -v claude-graph &>/dev/null && nc -z localhost 7687 2>/dev/null; then
        echo "  Current graph status:"
        claude-graph list-projects 2>/dev/null | sed 's/^/    /'
    fi
else
    echo ""
    echo "  Some checks failed. Run ./install.sh to fix."
fi

echo ""
