# Contributing to Claude Graph Memory

First off, thanks for considering contributing! This project exists because of people like you.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [How to Contribute](#how-to-contribute)
- [Adding Language Support](#adding-language-support)
- [Pull Request Process](#pull-request-process)
- [Style Guide](#style-guide)

## Code of Conduct

Be kind. Be respectful. We're all here to make Claude Code better.

## Getting Started

### Prerequisites

- Docker
- Python 3.9+
- Bash (macOS/Linux)
- Claude Code (for testing)

### Fork and Clone

```bash
# Fork the repo on GitHub, then:
git clone https://github.com/YOUR_USERNAME/claude-graph-memory.git
cd claude-graph-memory
```

## Development Setup

### 1. Install in Development Mode

```bash
# Install without overwriting your existing setup
./install.sh

# Or manually copy scripts for testing
cp scripts/* ~/.claude/scripts/
```

### 2. Test Changes

```bash
# Run the verification
./verify.sh

# Test specific commands
~/.claude/scripts/neo4j-context.sh status
~/.claude/scripts/neo4j-context.sh help
```

### 3. Test with Real Projects

Navigate to a project with `/docs` and verify:
- Session start shows graph status
- Editing `.md` files triggers updates
- `claude-graph status` shows correct counts

## How to Contribute

### Reporting Bugs

Open an issue with:
- What you expected to happen
- What actually happened
- Steps to reproduce
- Your environment (OS, Docker version, Python version)

### Suggesting Features

Open an issue with:
- The problem you're trying to solve
- Your proposed solution
- Any alternatives you considered

### Submitting Changes

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Test thoroughly
5. Commit with clear messages
6. Push to your fork
7. Open a Pull Request

## Adding Language Support

Want to add support for a new language? Here's how:

### 1. Add Detection in `neo4j-context.sh`

Find the `post_edit()` function and add a new condition:

```bash
# Handle Rust files
if [[ "$file_path" == *.rs ]] && [[ "$file_path" != */target/* ]]; then
    update_rust_file_node "$file_path" "$project_dir" &
    return 0
fi
```

### 2. Create the Update Function

Add a new function like `update_rust_file_node`:

```bash
update_rust_file_node() {
    local file_path="$1"
    local project_dir="$2"
    local rel_path="${file_path#$project_dir/}"

    python3 - "$PROJECT" "$file_path" "$rel_path" << 'PYTHON_EOF'
import sys
import re
from pathlib import Path
from neo4j import GraphDatabase

project = sys.argv[1]
file_path = Path(sys.argv[2])
rel_path = sys.argv[3]

driver = GraphDatabase.driver('bolt://localhost:7687')
try:
    with driver.session() as session:
        if not file_path.exists():
            session.run(f'''
                MATCH (f:{project}:File {{path: $path}})
                OPTIONAL MATCH (f)-[:CONTAINS]->(child)
                DETACH DELETE f, child
            ''', path=rel_path)
            sys.exit(0)

        content = file_path.read_text(encoding='utf-8')

        # Extract Rust constructs
        functions = re.findall(r'^(?:pub\s+)?(?:async\s+)?fn\s+(\w+)', content, re.MULTILINE)
        structs = re.findall(r'^(?:pub\s+)?struct\s+(\w+)', content, re.MULTILINE)
        traits = re.findall(r'^(?:pub\s+)?trait\s+(\w+)', content, re.MULTILINE)
        impls = re.findall(r'^impl(?:<[^>]+>)?\s+(\w+)', content, re.MULTILINE)

        # Delete old and recreate
        session.run(f'''
            MATCH (f:{project}:File {{path: $path}})
            OPTIONAL MATCH (f)-[:CONTAINS]->(child)
            DETACH DELETE f, child
        ''', path=rel_path)

    # Create new nodes...
    with driver.session() as session:
        session.run(f'''
            CREATE (f:{project}:File {{
                path: $path,
                language: 'rust',
                updated_at: datetime()
            }})
        ''', path=rel_path)

    # Add functions, structs, traits...
    for func in functions:
        with driver.session() as session:
            session.run(f'''
                MATCH (f:{project}:File {{path: $path}})
                CREATE (fn:{project}:Function {{name: $name, file: $path}})
                CREATE (f)-[:CONTAINS]->(fn)
            ''', path=rel_path, name=func)

    # Similar for structs, traits, etc.

finally:
    driver.close()
PYTHON_EOF
}
```

### 3. Update Help Text

Update the help section in `neo4j-context.sh`:

```bash
echo "Supported Languages: Go, TypeScript, JavaScript, Python, Rust, Markdown"
```

### 4. Update README

Add the new language to the features table.

### 5. Test It

```bash
# Create a test file
echo 'fn main() { println!("Hello"); }' > /tmp/test.rs

# Test the extraction
~/.claude/scripts/neo4j-context.sh post-edit < <(echo "/tmp/test.rs")

# Verify in graph
claude-graph status
```

## Pull Request Process

1. **Update documentation** if you changed functionality
2. **Test on macOS** (primary target platform)
3. **Keep changes focused** - one feature per PR
4. **Write clear commit messages**

### Commit Message Format

```
type: short description

Longer explanation if needed.

Fixes #123
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation only
- `refactor`: Code change that neither fixes a bug nor adds a feature
- `test`: Adding tests
- `chore`: Maintenance tasks

### PR Template

When you open a PR, include:

```markdown
## What does this PR do?

Brief description.

## How to test

Steps to verify the changes work.

## Checklist

- [ ] I've tested on macOS
- [ ] I've updated the README if needed
- [ ] I've updated the help text if needed
```

## Style Guide

### Bash

- Use `set -euo pipefail` at the top
- Quote variables: `"$variable"` not `$variable`
- Use `[[` for conditionals, not `[`
- Functions should have comments explaining purpose

### Python

- Follow PEP 8
- Use type hints where helpful
- Keep embedded Python scripts focused and minimal

### Cypher

- Use parameterized queries: `$param` not string interpolation
- Use meaningful relationship names: `CONTAINS`, `DESCRIBES`, not `HAS`

## Questions?

Open a [Discussion](https://github.com/amarodeabreu/claude-graph-memory/discussions) or reach out in the issues.

---

Thanks for contributing! 🎉
