<p align="center">
  <img src="https://img.shields.io/badge/Claude_Code-Compatible-blueviolet?style=for-the-badge" alt="Claude Code Compatible">
  <img src="https://img.shields.io/badge/NornicDB-Neo4j_Compatible-008CC1?style=for-the-badge" alt="NornicDB">
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" alt="MIT License">
</p>

<h1 align="center">Claude Graph Memory</h1>

<p align="center">
  <strong>Persistent knowledge graph and RAG memory for Claude Code</strong><br>
  <em>Your AI coding assistant now remembers everything across sessions</em>
</p>

<p align="center">
  <a href="#-quick-start">Quick Start</a> •
  <a href="#-features">Features</a> •
  <a href="#-how-it-works">How It Works</a> •
  <a href="#-commands">Commands</a> •
  <a href="#-contributing">Contributing</a>
</p>

---

## The Problem

Every time you start a new Claude Code session, it starts fresh. It doesn't remember:
- What you discussed yesterday about the architecture
- The decisions you made about the codebase
- The patterns and conventions in your project
- The relationships between your documentation and code

**Claude Graph Memory fixes this.**

## The Solution

A local knowledge graph that runs alongside Claude Code, automatically indexing your documentation and code structure. Claude can query this graph to understand your project deeply, and store learnings that persist across sessions.

```
┌─────────────────────────────────────────────────────────────────┐
│  Your Project                                                    │
│  ├── docs/                     ──────────────────┐              │
│  │   ├── architecture.md                         │              │
│  │   ├── decisions/                              ▼              │
│  │   └── api-specs/            ┌─────────────────────────────┐  │
│  └── src/                      │      NornicDB Graph         │  │
│      ├── components/     ───── │  ┌─────┐    ┌──────────┐   │  │
│      ├── services/             │  │ Doc │───▶│Component │   │  │
│      └── utils/                │  └─────┘    └──────────┘   │  │
│                                │      │           │          │  │
│                                │      ▼           ▼          │  │
│  Claude Code ◀────────────────▶│  ┌──────┐  ┌────────┐     │  │
│  (queries & stores memories)   │  │Memory│  │Function│     │  │
│                                │  └──────┘  └────────┘     │  │
│                                └─────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## ✨ Features

### 🔄 Automatic Indexing
- **Session Start**: Detects new projects and auto-populates the graph
- **On Every Edit**: Incrementally updates when you modify files
- **Zero Config**: Works out of the box for any project with a `/docs` folder

### 📚 Documentation Graph
- Parses all Markdown files in `/docs`
- Extracts titles, headings, and content
- Identifies components, concepts, and cross-references
- Special handling for ADRs (Architecture Decision Records)

### 🔍 Code Structure Graph
- **Go**: Packages, functions, structs, interfaces, methods
- **TypeScript/JavaScript**: Functions, classes, interfaces, arrow functions
- **Python**: Functions, classes, methods
- Tracks file relationships and containment

### 🧠 Persistent Memory
- Store learnings that survive across sessions
- Query past decisions and context
- Build up project knowledge over time

### 🏷️ Multi-Project Support
- Each project is isolated by label (`:ProjectName:Document`)
- Work on multiple projects without data mixing
- Easy cleanup of old projects

## 🚀 Quick Start

### Prerequisites

- **Docker**: [Install Docker](https://docs.docker.com/get-docker/)
- **Python 3.9+**: For populate scripts
- **Claude Code**: [Anthropic's CLI tool](https://claude.ai/code)

### Installation

```bash
# Clone the repo
git clone https://github.com/amarodeabreu/claude-graph-memory.git
cd claude-graph-memory

# Run the installer
./install.sh
```

That's it! The installer will:

1. ✅ Start NornicDB via Docker (auto-restarts on boot)
2. ✅ Install the `neo4j` Python driver
3. ✅ Configure MCP servers for Claude Code
4. ✅ Set up global hooks for all projects
5. ✅ Create the `claude-graph` CLI command

### Verify Installation

```bash
./verify.sh
```

### Restart Claude Code

After installation, restart Claude Code to load the MCP servers. Then navigate to any project with a `/docs` folder—it will auto-populate on session start.

## 📖 How It Works

### Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                        Claude Code                                │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  Hooks (in ~/.claude/settings.json)                        │  │
│  │  ├─ SessionStart  → Check graph, auto-populate if empty    │  │
│  │  └─ PostToolUse   → Incremental update on file edits       │  │
│  └────────────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  MCP Servers (in ~/.claude.json)                           │  │
│  │  ├─ neo4j-memory  → Store/retrieve persistent memories     │  │
│  │  └─ neo4j-cypher  → Run Cypher queries against the graph   │  │
│  └────────────────────────────────────────────────────────────┘  │
├──────────────────────────────────────────────────────────────────┤
│                     NornicDB (Docker)                             │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  Graph Schema                                               │  │
│  │  ├─ (:ProjectName:Document)  → Indexed documentation       │  │
│  │  ├─ (:ProjectName:Decision)  → ADRs and decisions          │  │
│  │  ├─ (:ProjectName:Component) → Extracted components        │  │
│  │  ├─ (:ProjectName:File)      → Code files                  │  │
│  │  ├─ (:ProjectName:Function)  → Functions and methods       │  │
│  │  └─ (:ProjectName:Class)     → Classes and structs         │  │
│  └────────────────────────────────────────────────────────────┘  │
│  Ports: 7474 (Browser UI) | 7687 (Bolt Protocol)                 │
└──────────────────────────────────────────────────────────────────┘
```

### Project Detection

Projects are automatically detected from the directory name and converted to PascalCase:

| Directory | Graph Label |
|-----------|-------------|
| `/Projects/trading-engine` | `:TradingEngine` |
| `/Projects/my-awesome-app` | `:MyAwesomeApp` |
| `/Projects/api` | `:Api` |

### What Gets Indexed

#### Documentation (Markdown)

| Extracted | Example |
|-----------|---------|
| Title | First `# Heading` |
| Headings | All `##` and `###` |
| Content | First 2000 chars |
| Type | overview, architecture, decision, implementation |
| References | Links to other docs |
| Components | Mentioned system components |
| Concepts | Terms in backticks or bold |

#### Code (Go/TypeScript/Python)

| Language | What's Extracted |
|----------|------------------|
| **Go** | `package`, `func`, `type struct`, `type interface` |
| **TypeScript** | `function`, `const fn = () =>`, `class`, `interface` |
| **Python** | `def`, `class` |

### Incremental Updates

When you edit a file in Claude Code:

1. The `PostToolUse` hook fires
2. Script checks if it's a `.md`, `.go`, `.ts`, `.tsx`, `.js`, `.jsx`, or `.py` file
3. Updates just that file's nodes in the graph (background, non-blocking)
4. Handles deletions automatically

## 🛠️ Commands

After installation, use `claude-graph` from any project directory:

```bash
# Show current graph statistics
claude-graph status

# Full re-index (docs + code)
claude-graph refresh

# Index only documentation
claude-graph populate-docs

# Index only code
claude-graph populate-code

# Remove nodes for deleted files
claude-graph prune

# List all indexed projects
claude-graph list-projects

# Delete a project from the graph
claude-graph drop-project OldProjectName

# Show help
claude-graph help
```

## 📊 Graph Schema

### Node Types

```cypher
// Documentation
(:Document {path, title, type, headings, content, updated_at})
(:Decision {id, title, status, path, context, decision, consequences})
(:Component {name})
(:Concept {name})

// Code
(:File {path, language, package, updated_at})
(:Function {name, file})
(:Struct {name, file})      // Go
(:Interface {name, file})   // Go, TypeScript
(:Class {name, file})       // TypeScript, Python
```

### Relationships

```cypher
(Document)-[:DESCRIBES]->(Component)
(Document)-[:MENTIONS]->(Concept)
(Document)-[:REFERENCES]->(Document)
(File)-[:CONTAINS]->(Function|Struct|Interface|Class)
```

### Example Queries

```cypher
// Find docs about a component
MATCH (d:MyProject:Document)-[:DESCRIBES]->(c:Component {name: 'AuthService'})
RETURN d.path, d.title

// What functions are in a file?
MATCH (f:MyProject:File {path: 'src/auth.ts'})-[:CONTAINS]->(fn:Function)
RETURN fn.name

// Find all decisions
MATCH (d:MyProject:Decision)
RETURN d.id, d.title, d.status
```

## ⚙️ Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NEO4J_URI` | `bolt://localhost:7687` | NornicDB connection |
| `CLAUDE_PROJECT_DIR` | Current directory | Project root |

### Docker Ports

| Port | Service |
|------|---------|
| `7474` | NornicDB Browser UI |
| `7687` | Bolt protocol (queries) |

### Files Installed

```
~/.claude.json                      # MCP server config (modified)
~/.claude/settings.json             # Global hooks (modified)
~/.claude/scripts/
├── neo4j-context.sh                # Main CLI script
├── populate-doc-graph.py           # Documentation indexer
└── populate-code-graph.go          # Go code indexer
~/.claude-graph-memory/
└── docker-compose.yml              # NornicDB container config
~/.local/bin/claude-graph           # CLI symlink
```

## 🔧 Troubleshooting

### NornicDB not running

```bash
# Check status
docker ps | grep nornicdb

# Start it
docker start nornicdb

# Or use docker-compose
cd ~/.claude-graph-memory && docker-compose up -d

# View logs
docker logs nornicdb
```

### Connection refused

```bash
# Check if port is open
nc -z localhost 7687 && echo "OK" || echo "Not running"

# Restart the container
docker restart nornicdb
```

### Graph not updating

```bash
# Force a full refresh
claude-graph refresh

# Check for errors in the hook
~/.claude/scripts/neo4j-context.sh session-start
```

### MCP servers not loading

1. Restart Claude Code completely
2. Check `~/.claude.json` has the `neo4j-memory` and `neo4j-cypher` entries
3. Verify uvx is installed: `which uvx`

### Reset everything

```bash
./uninstall.sh
./install.sh
```

## ❓ FAQ

### Does this send my code to the cloud?

**No.** Everything runs locally:
- NornicDB runs in a local Docker container
- Data is stored in a Docker volume on your machine
- MCP servers communicate via stdio, not network

### How much disk space does it use?

Minimal. The graph database is very efficient:
- ~1MB per 100 documents indexed
- Code nodes are just metadata (no source code stored)

### Can I use this with multiple machines?

Currently designed for single-machine use. For multi-machine sync, you'd need to:
- Export/import the Docker volume
- Or mount a shared volume

### Does it work with private repos?

Yes! It only indexes local files. Nothing leaves your machine.

### What about large monorepos?

Works fine, but initial population may take a minute. Incremental updates are always fast.

### Can I add support for other languages?

Yes! See [CONTRIBUTING.md](CONTRIBUTING.md) for how to add language support.

## 🗺️ Roadmap

- [ ] **Semantic search**: Vector embeddings for natural language queries
- [ ] **Rust support**: Add Rust language parsing
- [ ] **Import graph**: Track dependencies between files
- [ ] **Git integration**: Index commit history and blame
- [ ] **Web UI**: Visual graph explorer
- [ ] **Team sync**: Share graph across team members

## 🤝 Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

### Quick Links

- [Report a Bug](https://github.com/amarodeabreu/claude-graph-memory/issues/new?template=bug_report.md)
- [Request a Feature](https://github.com/amarodeabreu/claude-graph-memory/issues/new?template=feature_request.md)
- [Ask a Question](https://github.com/amarodeabreu/claude-graph-memory/discussions)

## 📜 License

MIT License - see [LICENSE](LICENSE) for details.

## 🙏 Credits

- [NornicDB](https://github.com/orneryd/NornicDB) - Neo4j-compatible graph database
- [Claude Code](https://claude.ai/code) - Anthropic's CLI for Claude
- [mcp-neo4j](https://github.com/neo4j-contrib/mcp-neo4j) - MCP servers for Neo4j

---

<p align="center">
  <strong>Built with ❤️ for the Claude Code community</strong><br>
  <sub>If this helps you, give it a ⭐</sub>
</p>
