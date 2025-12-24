# Claude Graph Memory

Persistent knowledge graph and RAG memory for [Claude Code](https://claude.ai/code) using NornicDB (Neo4j-compatible graph database).

## What It Does

- **Automatic Documentation Indexing**: Parses `/docs/**/*.md` into a queryable graph
- **Code Structure Graph**: Indexes functions, classes, interfaces from Go/TypeScript/Python
- **Persistent Memory**: Store learnings across Claude Code sessions via MCP
- **Incremental Updates**: Graph updates automatically when you edit files
- **Multi-Project Support**: Each project is isolated by label (`:ProjectName:Document`)

## Quick Start

```bash
# Clone and install
git clone https://github.com/yourusername/claude-graph-memory.git
cd claude-graph-memory
./install.sh
```

That's it. The installer will:
1. Start NornicDB via Docker (auto-restarts on boot)
2. Install MCP servers for Claude Code
3. Configure global hooks for all projects
4. Set up the helper scripts

## Requirements

- **Docker**: For running NornicDB
- **Python 3.9+**: For populate scripts
- **Claude Code**: The CLI tool from Anthropic

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                     Claude Code                              │
├─────────────────────────────────────────────────────────────┤
│  Hooks (automatic):                                          │
│  ├─ SessionStart  → Check graph, auto-populate if empty     │
│  └─ PostToolUse   → Incremental update on file edits        │
│                                                              │
│  MCP Servers:                                                │
│  ├─ neo4j-memory  → Persistent memory across sessions       │
│  └─ neo4j-cypher  → Direct Cypher queries                   │
├─────────────────────────────────────────────────────────────┤
│                     NornicDB                                 │
│  ├─ :ProjectName:Document  → Indexed documentation          │
│  ├─ :ProjectName:File      → Code files                     │
│  ├─ :ProjectName:Function  → Functions/methods              │
│  ├─ :ProjectName:Class     → Classes                        │
│  └─ :ProjectName:Component → Extracted components           │
└─────────────────────────────────────────────────────────────┘
```

## Commands

After installation, you can use these commands from any project directory:

```bash
# Check current graph status
claude-graph status

# Full refresh (re-index everything)
claude-graph refresh

# Remove nodes for deleted files
claude-graph prune

# List all indexed projects
claude-graph list-projects

# Delete a project from graph
claude-graph drop-project OldProject
```

## Supported Languages

| Language | What's Indexed |
|----------|----------------|
| Markdown | Title, headings, content, references |
| Go | Packages, functions, structs, interfaces |
| TypeScript/JavaScript | Functions, classes, interfaces |
| Python | Functions, classes |

## Graph Schema

### Documentation Nodes
- `(:Document {path, title, type, headings, content})`
- `(:Decision {id, title, status, context, decision, consequences})`
- `(:Component {name})`
- `(:Concept {name})`

### Code Nodes
- `(:File {path, language, package})`
- `(:Function {name, file})`
- `(:Struct {name, file})`
- `(:Interface {name, file})`
- `(:Class {name, file})`

### Relationships
- `(Document)-[:DESCRIBES]->(Component)`
- `(Document)-[:MENTIONS]->(Concept)`
- `(Document)-[:REFERENCES]->(Document)`
- `(File)-[:CONTAINS]->(Function|Struct|Interface|Class)`

## Manual Population

If you want to manually trigger population:

```bash
# Index docs only
claude-graph populate-docs

# Index code only (Go/TS/Python)
claude-graph populate-code

# Both
claude-graph populate
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NEO4J_URI` | `bolt://localhost:7687` | NornicDB connection URI |
| `CLAUDE_PROJECT_DIR` | `$(pwd)` | Project root directory |

### Docker Ports

| Port | Service |
|------|---------|
| 7474 | NornicDB Browser (HTTP) |
| 7687 | NornicDB Bolt Protocol |

## Troubleshooting

### NornicDB not running
```bash
docker start nornicdb
# Or restart with compose
cd ~/.claude-graph-memory && docker-compose up -d
```

### Check connection
```bash
nc -z localhost 7687 && echo "Connected" || echo "Not running"
```

### View logs
```bash
docker logs nornicdb
```

### Reset everything
```bash
./uninstall.sh
./install.sh
```

## Uninstall

```bash
cd claude-graph-memory
./uninstall.sh
```

This removes:
- Docker container and volume
- MCP server configurations
- Global hooks
- Helper scripts

## How Projects Are Detected

Project names are derived from the directory name, converted to PascalCase:

| Directory | Project Label |
|-----------|---------------|
| `/Projects/trading-engine` | `TradingEngine` |
| `/Projects/my-awesome-app` | `MyAwesomeApp` |
| `/Projects/api` | `Api` |

## License

MIT

## Credits

- [NornicDB](https://github.com/orneryd/NornicDB) - Neo4j-compatible graph database
- [Claude Code](https://claude.ai/code) - Anthropic's CLI for Claude
- [mcp-neo4j](https://github.com/neo4j-contrib/mcp-neo4j) - MCP servers for Neo4j
