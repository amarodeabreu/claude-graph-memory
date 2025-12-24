#!/bin/bash
# Global NornicDB Context Hook for Claude Code
#
# Works across ALL projects on this machine.
# Automatically derives project name from current directory.
#
# Usage:
#   ~/.claude/scripts/neo4j-context.sh session-start
#   ~/.claude/scripts/neo4j-context.sh post-edit
#   ~/.claude/scripts/neo4j-context.sh populate-docs
#   ~/.claude/scripts/neo4j-context.sh populate-code

set -euo pipefail

NEO4J_URI="${NEO4J_URI:-bolt://localhost:7687}"

# Auto-detect project name from current directory
# e.g., /Users/amaro/Projects/trading-engine -> TradingEngine
get_project_name() {
    local dir_name
    dir_name=$(basename "${CLAUDE_PROJECT_DIR:-$(pwd)}")
    # Convert kebab-case to PascalCase: trading-engine -> TradingEngine
    # Use perl since macOS sed doesn't support \U
    echo "$dir_name" | perl -pe 's/(^|-)(\w)/\U$2/g'
}

PROJECT=$(get_project_name)

# Check if NornicDB is accessible
check_connection() {
    # Try a quick TCP check
    if command -v nc &>/dev/null; then
        nc -z localhost 7687 2>/dev/null || return 1
    fi
    return 0
}

# Get node count for project (fast query)
get_doc_count() {
    python3 -c "
from neo4j import GraphDatabase
try:
    driver = GraphDatabase.driver('$NEO4J_URI')
    with driver.session() as session:
        result = session.run('MATCH (n) WHERE n:$PROJECT AND n:Document RETURN count(n) as c')
        print(result.single()['c'])
    driver.close()
except:
    print('0')
" 2>/dev/null
}

# Auto-populate if project has no docs in graph
auto_populate_if_needed() {
    local docs_path="${CLAUDE_PROJECT_DIR:-$(pwd)}/docs"

    # Skip if no docs folder
    [[ ! -d "$docs_path" ]] && return 0

    # Check if already populated
    local count
    count=$(get_doc_count)

    if [[ "$count" == "0" ]]; then
        echo "   ⏳ Auto-populating docs graph (first time)..."
        # Run populate in background, don't block session start
        nohup python3 ~/.claude/scripts/populate-doc-graph.py \
            --project "$PROJECT" \
            --docs-path "$docs_path" \
            > /tmp/nornicdb-populate-$PROJECT.log 2>&1 &
        echo "   📝 Running in background, check /tmp/nornicdb-populate-$PROJECT.log"
    else
        echo "   📄 $count documents indexed"
    fi
}

# Get project summary from graph
session_start() {
    if ! check_connection; then
        echo "⚠️  NornicDB not running (bolt://localhost:7687)"
        echo "   Start: docker start nornicdb"
        return 0
    fi

    echo "📊 NornicDB Knowledge Graph"
    echo "   Project: $PROJECT"

    # Check and auto-populate if needed
    auto_populate_if_needed

    echo ""
    echo "   Tools: neo4j-memory (learnings), neo4j-cypher (queries)"
    echo "   Manual: ~/.claude/scripts/neo4j-context.sh populate-docs"
}

# Populate documentation graph for current project
populate_docs() {
    local docs_path="${CLAUDE_PROJECT_DIR:-$(pwd)}/docs"

    if [[ ! -d "$docs_path" ]]; then
        echo "No docs/ directory found in current project"
        return 1
    fi

    echo "Populating documentation graph for $PROJECT..."
    python3 ~/.claude/scripts/populate-doc-graph.py \
        --project "$PROJECT" \
        --docs-path "$docs_path"
}

# Populate code graph for current project
populate_code() {
    local code_path="${CLAUDE_PROJECT_DIR:-$(pwd)}"

    echo "Populating code graph for $PROJECT..."

    # Check for Go files
    if find "$code_path" -name "*.go" -not -path "*/vendor/*" | head -1 | grep -q .; then
        echo "Found Go files, using Go AST parser..."
        cd "$code_path" && go run ~/.claude/scripts/populate-code-graph.go \
            --project "$PROJECT" \
            --path .
    else
        echo "No Go files found. Code graph populator currently supports Go only."
        echo "For other languages, use the Code Grapher MCP or add support."
    fi
}

# Post-edit hook - incremental graph update for doc and code changes
post_edit() {
    # Read the edited file path from stdin (provided by Claude Code hook)
    local file_path
    read -r file_path 2>/dev/null || return 0

    [[ -z "$file_path" ]] && return 0

    # Check connection silently
    check_connection || return 0

    local project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"

    # Handle markdown files in docs/
    if [[ "$file_path" == *"/docs/"*.md ]]; then
        update_doc_node "$file_path" "$project_dir" &
        return 0
    fi

    # Handle Go files (not in vendor/)
    if [[ "$file_path" == *.go ]] && [[ "$file_path" != */vendor/* ]]; then
        update_go_file_node "$file_path" "$project_dir" &
        return 0
    fi

    # Handle TypeScript/JavaScript files (not in node_modules/)
    if [[ "$file_path" == *.ts || "$file_path" == *.tsx || "$file_path" == *.js || "$file_path" == *.jsx ]] && [[ "$file_path" != */node_modules/* ]]; then
        update_ts_file_node "$file_path" "$project_dir" &
        return 0
    fi

    # Handle Python files (not in venv/, .venv/, __pycache__/)
    if [[ "$file_path" == *.py ]] && [[ "$file_path" != */venv/* ]] && [[ "$file_path" != */.venv/* ]] && [[ "$file_path" != */__pycache__/* ]]; then
        update_py_file_node "$file_path" "$project_dir" &
        return 0
    fi

    return 0
}

# Update a single document node
update_doc_node() {
    local file_path="$1"
    local project_dir="$2"
    local rel_path="${file_path#$project_dir/docs/}"

    python3 - "$PROJECT" "$file_path" "$rel_path" << 'PYTHON_EOF'
import sys
from pathlib import Path
from neo4j import GraphDatabase
import re

project = sys.argv[1]
file_path = Path(sys.argv[2])
rel_path = sys.argv[3]

driver = GraphDatabase.driver('bolt://localhost:7687')
try:
    with driver.session() as session:
        # Handle deletion
        if not file_path.exists():
            session.run(f'''
                MATCH (d:{project}:Document {{path: $path}})
                DETACH DELETE d
            ''', path=rel_path)
            sys.exit(0)

        content = file_path.read_text(encoding='utf-8')

        # Extract title
        title_match = re.search(r'^#\s+(.+)$', content, re.MULTILINE)
        title = title_match.group(1).strip() if title_match else file_path.stem.replace('-', ' ').title()

        # Extract headings
        headings = re.findall(r'^#{1,3}\s+(.+)$', content, re.MULTILINE)

        # Determine doc type
        path_lower = rel_path.lower()
        if 'overview' in path_lower or '00-' in rel_path:
            doc_type = 'overview'
        elif 'architecture' in path_lower or '01-' in rel_path:
            doc_type = 'architecture'
        elif 'decision' in path_lower or '02-' in rel_path:
            doc_type = 'decision'
        elif 'implementation' in path_lower or '04-' in rel_path:
            doc_type = 'implementation'
        elif 'operations' in path_lower or '05-' in rel_path:
            doc_type = 'operations'
        elif 'plan' in path_lower or '06-' in rel_path:
            doc_type = 'plan'
        else:
            doc_type = 'other'

        # Upsert the document node
        session.run(f'''
            MERGE (d:{project}:Document {{path: $path}})
            SET d.title = $title,
                d.type = $type,
                d.headings = $headings,
                d.content = $content,
                d.updated_at = datetime()
        ''', path=rel_path, title=title, type=doc_type,
            headings=headings, content=content[:2000])
finally:
    driver.close()
PYTHON_EOF
}

# Update a single Go file's nodes (functions, structs, etc.)
update_go_file_node() {
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
        # Handle deletion - remove file and all its children
        if not file_path.exists():
            session.run(f'''
                MATCH (f:{project}:File {{path: $path}})
                OPTIONAL MATCH (f)-[:CONTAINS]->(child)
                DETACH DELETE f, child
            ''', path=rel_path)
            sys.exit(0)

        content = file_path.read_text(encoding='utf-8')

        # Extract package name
        pkg_match = re.search(r'^package\s+(\w+)', content, re.MULTILINE)
        package = pkg_match.group(1) if pkg_match else 'unknown'

        # Extract function names (simple regex, not full AST)
        functions = re.findall(r'^func\s+(?:\([^)]+\)\s+)?(\w+)\s*\(', content, re.MULTILINE)

        # Extract struct names
        structs = re.findall(r'^type\s+(\w+)\s+struct\s*\{', content, re.MULTILINE)

        # Extract interface names
        interfaces = re.findall(r'^type\s+(\w+)\s+interface\s*\{', content, re.MULTILINE)

        # Delete old file node and children, then recreate
        session.run(f'''
            MATCH (f:{project}:File {{path: $path}})
            OPTIONAL MATCH (f)-[:CONTAINS]->(child)
            DETACH DELETE f, child
        ''', path=rel_path)

    # Create new nodes in separate sessions (NornicDB bookmark workaround)
    with driver.session() as session:
        session.run(f'''
            CREATE (f:{project}:File {{
                path: $path,
                package: $package,
                updated_at: datetime()
            }})
        ''', path=rel_path, package=package)

    for func in functions:
        with driver.session() as session:
            session.run(f'''
                MATCH (f:{project}:File {{path: $path}})
                CREATE (fn:{project}:Function {{name: $name, file: $path}})
                CREATE (f)-[:CONTAINS]->(fn)
            ''', path=rel_path, name=func)

    for struct in structs:
        with driver.session() as session:
            session.run(f'''
                MATCH (f:{project}:File {{path: $path}})
                CREATE (s:{project}:Struct {{name: $name, file: $path}})
                CREATE (f)-[:CONTAINS]->(s)
            ''', path=rel_path, name=struct)

    for iface in interfaces:
        with driver.session() as session:
            session.run(f'''
                MATCH (f:{project}:File {{path: $path}})
                CREATE (i:{project}:Interface {{name: $name, file: $path}})
                CREATE (f)-[:CONTAINS]->(i)
            ''', path=rel_path, name=iface)

finally:
    driver.close()
PYTHON_EOF
}

# Update a single TypeScript/JavaScript file's nodes
update_ts_file_node() {
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

        # Extract functions (function declarations, arrow functions, methods)
        functions = []
        functions += re.findall(r'(?:export\s+)?(?:async\s+)?function\s+(\w+)', content)
        functions += re.findall(r'(?:export\s+)?const\s+(\w+)\s*=\s*(?:async\s+)?\([^)]*\)\s*=>', content)
        functions += re.findall(r'^\s+(?:async\s+)?(\w+)\s*\([^)]*\)\s*[:{]', content, re.MULTILINE)

        # Extract classes/interfaces/types
        classes = re.findall(r'(?:export\s+)?class\s+(\w+)', content)
        interfaces = re.findall(r'(?:export\s+)?interface\s+(\w+)', content)
        types = re.findall(r'(?:export\s+)?type\s+(\w+)\s*=', content)

        # Delete old and recreate
        session.run(f'''
            MATCH (f:{project}:File {{path: $path}})
            OPTIONAL MATCH (f)-[:CONTAINS]->(child)
            DETACH DELETE f, child
        ''', path=rel_path)

    with driver.session() as session:
        session.run(f'''
            CREATE (f:{project}:File {{
                path: $path,
                language: 'typescript',
                updated_at: datetime()
            }})
        ''', path=rel_path)

    for func in set(functions):
        with driver.session() as session:
            session.run(f'''
                MATCH (f:{project}:File {{path: $path}})
                CREATE (fn:{project}:Function {{name: $name, file: $path}})
                CREATE (f)-[:CONTAINS]->(fn)
            ''', path=rel_path, name=func)

    for cls in classes:
        with driver.session() as session:
            session.run(f'''
                MATCH (f:{project}:File {{path: $path}})
                CREATE (c:{project}:Class {{name: $name, file: $path}})
                CREATE (f)-[:CONTAINS]->(c)
            ''', path=rel_path, name=cls)

    for iface in interfaces:
        with driver.session() as session:
            session.run(f'''
                MATCH (f:{project}:File {{path: $path}})
                CREATE (i:{project}:Interface {{name: $name, file: $path}})
                CREATE (f)-[:CONTAINS]->(i)
            ''', path=rel_path, name=iface)

finally:
    driver.close()
PYTHON_EOF
}

# Update a single Python file's nodes
update_py_file_node() {
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

        # Extract functions and classes
        functions = re.findall(r'^def\s+(\w+)\s*\(', content, re.MULTILINE)
        classes = re.findall(r'^class\s+(\w+)', content, re.MULTILINE)
        methods = re.findall(r'^\s+def\s+(\w+)\s*\(', content, re.MULTILINE)

        # Delete old and recreate
        session.run(f'''
            MATCH (f:{project}:File {{path: $path}})
            OPTIONAL MATCH (f)-[:CONTAINS]->(child)
            DETACH DELETE f, child
        ''', path=rel_path)

    with driver.session() as session:
        session.run(f'''
            CREATE (f:{project}:File {{
                path: $path,
                language: 'python',
                updated_at: datetime()
            }})
        ''', path=rel_path)

    for func in functions:
        with driver.session() as session:
            session.run(f'''
                MATCH (f:{project}:File {{path: $path}})
                CREATE (fn:{project}:Function {{name: $name, file: $path}})
                CREATE (f)-[:CONTAINS]->(fn)
            ''', path=rel_path, name=func)

    for cls in classes:
        with driver.session() as session:
            session.run(f'''
                MATCH (f:{project}:File {{path: $path}})
                CREATE (c:{project}:Class {{name: $name, file: $path}})
                CREATE (f)-[:CONTAINS]->(c)
            ''', path=rel_path, name=cls)

finally:
    driver.close()
PYTHON_EOF
}

# Show current graph statistics
status() {
    if ! check_connection; then
        echo "⚠️  NornicDB not running (bolt://localhost:7687)"
        return 1
    fi

    python3 - "$PROJECT" << 'PYTHON_EOF'
import sys
from neo4j import GraphDatabase

project = sys.argv[1]
driver = GraphDatabase.driver('bolt://localhost:7687')

try:
    with driver.session() as session:
        result = session.run(f'''
            MATCH (n) WHERE n:{project}
            RETURN labels(n) as labels, count(*) as count
            ORDER BY count DESC
        ''')
        print(f"📊 {project} Graph Statistics:")
        total = 0
        for record in result:
            labels = [l for l in record['labels'] if l != project]
            label = labels[0] if labels else 'Unknown'
            count = record['count']
            total += count
            print(f"   {label}: {count}")
        print(f"   ─────────")
        print(f"   Total: {total}")
finally:
    driver.close()
PYTHON_EOF
}

# Remove nodes for files that no longer exist on disk
prune_stale_nodes() {
    if ! check_connection; then
        echo "⚠️  NornicDB not running"
        return 1
    fi

    local project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
    echo "🧹 Pruning stale nodes for $PROJECT..."

    python3 - "$PROJECT" "$project_dir" << 'PYTHON_EOF'
import sys
from pathlib import Path
from neo4j import GraphDatabase

project = sys.argv[1]
project_dir = Path(sys.argv[2])

driver = GraphDatabase.driver('bolt://localhost:7687')
pruned = 0

try:
    # Get all File nodes
    with driver.session() as session:
        result = session.run(f'''
            MATCH (f:{project}:File)
            RETURN f.path as path
        ''')
        files = [r['path'] for r in result]

    for file_path in files:
        full_path = project_dir / file_path
        if not full_path.exists():
            with driver.session() as session:
                session.run(f'''
                    MATCH (f:{project}:File {{path: $path}})
                    OPTIONAL MATCH (f)-[:CONTAINS]->(child)
                    DETACH DELETE f, child
                ''', path=file_path)
                pruned += 1
                print(f"   Removed: {file_path}")

    # Get all Document nodes
    with driver.session() as session:
        result = session.run(f'''
            MATCH (d:{project}:Document)
            RETURN d.path as path
        ''')
        docs = [r['path'] for r in result]

    docs_dir = project_dir / 'docs'
    for doc_path in docs:
        full_path = docs_dir / doc_path
        if not full_path.exists():
            with driver.session() as session:
                session.run(f'''
                    MATCH (d:{project}:Document {{path: $path}})
                    DETACH DELETE d
                ''', path=doc_path)
                pruned += 1
                print(f"   Removed: docs/{doc_path}")

    print(f"\n   Pruned {pruned} stale nodes")

finally:
    driver.close()
PYTHON_EOF
}

# List all projects in the graph
list_projects() {
    if ! check_connection; then
        echo "⚠️  NornicDB not running"
        return 1
    fi

    python3 << 'PYTHON_EOF'
from neo4j import GraphDatabase

driver = GraphDatabase.driver('bolt://localhost:7687')
node_types = {'Document', 'File', 'Function', 'Struct', 'Interface', 'Class', 'Component', 'Concept', 'Decision', 'Entity', 'Observation'}

try:
    with driver.session() as session:
        result = session.run('''
            MATCH (n)
            RETURN labels(n) as labels
        ''')

        projects = {}
        for record in result:
            labels = record['labels']
            # Find project label (the one that's not a node type)
            for lbl in labels:
                if lbl not in node_types:
                    projects[lbl] = projects.get(lbl, 0) + 1

        print("📊 All Projects in NornicDB:")
        for project, count in sorted(projects.items(), key=lambda x: -x[1]):
            print(f"   {project}: {count} nodes")

        if not projects:
            print("   (no projects found)")

finally:
    driver.close()
PYTHON_EOF
}

# Drop all nodes for a project
drop_project() {
    local target_project="$1"

    if [[ -z "$target_project" ]]; then
        echo "Usage: $0 drop-project <ProjectName>"
        echo "Example: $0 drop-project OldProject"
        return 1
    fi

    if ! check_connection; then
        echo "⚠️  NornicDB not running"
        return 1
    fi

    echo "⚠️  This will delete ALL nodes for project: $target_project"
    read -p "   Are you sure? (y/N) " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "   Cancelled"
        return 0
    fi

    python3 - "$target_project" << 'PYTHON_EOF'
import sys
from neo4j import GraphDatabase

project = sys.argv[1]
driver = GraphDatabase.driver('bolt://localhost:7687')

try:
    with driver.session() as session:
        result = session.run(f'''
            MATCH (n:{project})
            WITH count(n) as total
            RETURN total
        ''')
        total = result.single()['total']

    with driver.session() as session:
        session.run(f'''
            MATCH (n:{project})
            DETACH DELETE n
        ''')

    print(f"   ✅ Deleted {total} nodes for {project}")

finally:
    driver.close()
PYTHON_EOF
}

# Main dispatch
case "${1:-help}" in
    session-start)
        session_start
        ;;
    post-edit)
        post_edit
        ;;
    populate-docs)
        populate_docs
        ;;
    populate-code)
        populate_code
        ;;
    populate|refresh)
        echo "🔄 Full refresh for $PROJECT..."
        populate_docs
        populate_code
        echo "✅ Refresh complete"
        ;;
    status)
        status
        ;;
    prune)
        prune_stale_nodes
        ;;
    list-projects)
        list_projects
        ;;
    drop-project)
        drop_project "${2:-}"
        ;;
    help|*)
        echo "NornicDB Context Helper"
        echo ""
        echo "Usage: $0 <command>"
        echo ""
        echo "Commands:"
        echo "  session-start    Show graph status (called by hook)"
        echo "  post-edit        Incremental update (called by hook on Edit/Write)"
        echo "  status           Show current graph statistics"
        echo "  populate-docs    Index current project's /docs into graph"
        echo "  populate-code    Index current project's code into graph"
        echo "  populate|refresh Full re-sync (docs + code)"
        echo "  prune            Remove nodes for deleted files"
        echo "  list-projects    Show all projects in graph"
        echo "  drop-project X   Delete all nodes for project X"
        echo ""
        echo "Current project: $PROJECT"
        echo ""
        echo "Automatic Updates:"
        echo "  • Session start: Auto-populates if docs/ exists but graph is empty"
        echo "  • Post-edit: Incrementally updates .md, .go, .ts, .tsx, .js, .jsx, .py files"
        echo ""
        echo "Supported Languages: Go, TypeScript, JavaScript, Python, Markdown"
        ;;
esac
