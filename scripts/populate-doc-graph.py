#!/usr/bin/env python3
"""
Documentation Graph Populator for NornicDB

Parses /docs/**/*.md and creates a knowledge graph in NornicDB.
Uses BGE embeddings via NornicDB's built-in vector support.

Usage:
    python scripts/populate-doc-graph.py [--project PROJECT_NAME] [--docs-path PATH]

Example:
    python scripts/populate-doc-graph.py --project trading-engine --docs-path ./docs
"""

import argparse
import os
import re
import sys
from pathlib import Path
from typing import Optional
from dataclasses import dataclass, field

try:
    from neo4j import GraphDatabase
except ImportError:
    print("ERROR: neo4j driver not installed. Run: pip install neo4j")
    sys.exit(1)

# NornicDB connection (no auth by default)
NEO4J_URI = os.getenv("NEO4J_URI", "bolt://localhost:7687")
NEO4J_USER = os.getenv("NEO4J_USER", "")
NEO4J_PASSWORD = os.getenv("NEO4J_PASSWORD", "")


@dataclass
class Document:
    """Represents a parsed markdown document."""
    path: str
    title: str
    doc_type: str  # overview, architecture, decision, implementation, operations
    headings: list[str] = field(default_factory=list)
    content: str = ""
    frontmatter: dict = field(default_factory=dict)
    references: list[str] = field(default_factory=list)  # other doc paths referenced
    components: list[str] = field(default_factory=list)  # components mentioned
    concepts: list[str] = field(default_factory=list)  # key concepts


@dataclass
class Decision:
    """Represents an ADR (Architecture Decision Record)."""
    id: str
    title: str
    status: str  # accepted, proposed, deprecated, superseded
    path: str
    context: str
    decision: str
    consequences: str


def parse_frontmatter(content: str) -> tuple[dict, str]:
    """Extract YAML frontmatter from markdown content."""
    if not content.startswith("---"):
        return {}, content

    parts = content.split("---", 2)
    if len(parts) < 3:
        return {}, content

    frontmatter = {}
    for line in parts[1].strip().split("\n"):
        if ":" in line:
            key, value = line.split(":", 1)
            frontmatter[key.strip()] = value.strip()

    return frontmatter, parts[2]


def extract_title(content: str, path: str) -> str:
    """Extract document title from first H1 heading or filename."""
    match = re.search(r'^#\s+(.+)$', content, re.MULTILINE)
    if match:
        return match.group(1).strip()
    return Path(path).stem.replace("-", " ").title()


def extract_headings(content: str) -> list[str]:
    """Extract all headings from markdown content."""
    return re.findall(r'^#{1,3}\s+(.+)$', content, re.MULTILINE)


def extract_references(content: str, base_path: Path) -> list[str]:
    """Extract references to other docs (relative links)."""
    refs = []
    # Match markdown links: [text](path.md) or [text](../path.md)
    for match in re.finditer(r'\[.+?\]\(([^)]+\.md)\)', content):
        ref_path = match.group(1)
        if not ref_path.startswith("http"):
            refs.append(ref_path)
    return refs


def extract_components(content: str) -> list[str]:
    """Extract component names mentioned in the document."""
    # Look for common component patterns in trading engine
    patterns = [
        r'\b(TokenScreener|Screener)\b',
        r'\b(RiskEngine|Risk Engine)\b',
        r'\b(ExitEngine|Exit Engine)\b',
        r'\b(TradeExecutor|Trade Executor|Executor)\b',
        r'\b(Keystore|Key Store)\b',
        r'\b(WebhookHandler|Webhook Handler)\b',
        r'\b(CopyTradeWorker|Copy Trade Worker)\b',
        r'\b(ExitCheckWorker|Exit Check Worker)\b',
        r'\b(PriceUpdateWorker|Price Update Worker)\b',
        r'\b(Jupiter|Helius|Birdeye)\b',
    ]

    components = set()
    for pattern in patterns:
        for match in re.finditer(pattern, content, re.IGNORECASE):
            # Normalize component name
            name = match.group(1).replace(" ", "")
            components.add(name)

    return list(components)


def extract_concepts(content: str) -> list[str]:
    """Extract key concepts/terms from the document."""
    # Look for defined terms, code blocks, emphasis
    concepts = set()

    # Backtick terms
    for match in re.finditer(r'`([^`]+)`', content):
        term = match.group(1)
        if len(term) > 2 and len(term) < 50 and not term.startswith("/"):
            concepts.add(term)

    # Bold terms (likely definitions)
    for match in re.finditer(r'\*\*([^*]+)\*\*', content):
        term = match.group(1)
        if len(term) > 2 and len(term) < 50:
            concepts.add(term)

    return list(concepts)[:20]  # Limit to top 20


def determine_doc_type(path: str) -> str:
    """Determine document type from path."""
    path_lower = path.lower()
    if "overview" in path_lower or "00-" in path:
        return "overview"
    elif "architecture" in path_lower or "01-" in path:
        return "architecture"
    elif "decision" in path_lower or "02-" in path:
        return "decision"
    elif "implementation" in path_lower or "04-" in path:
        return "implementation"
    elif "operations" in path_lower or "05-" in path:
        return "operations"
    elif "plan" in path_lower or "06-" in path:
        return "plan"
    else:
        return "other"


def parse_document(file_path: Path, base_path: Path) -> Document:
    """Parse a markdown document into a Document object."""
    content = file_path.read_text(encoding="utf-8")
    rel_path = str(file_path.relative_to(base_path))

    frontmatter, body = parse_frontmatter(content)

    return Document(
        path=rel_path,
        title=extract_title(body, rel_path),
        doc_type=determine_doc_type(rel_path),
        headings=extract_headings(body),
        content=body[:5000],  # Truncate for embedding
        frontmatter=frontmatter,
        references=extract_references(body, file_path.parent),
        components=extract_components(body),
        concepts=extract_concepts(body),
    )


def parse_decision(file_path: Path, base_path: Path) -> Optional[Decision]:
    """Parse an ADR document into a Decision object."""
    content = file_path.read_text(encoding="utf-8")
    rel_path = str(file_path.relative_to(base_path))

    # Extract decision ID from filename (e.g., 001-go-for-trading-engine.md)
    filename = file_path.stem
    match = re.match(r'^(\d+)-(.+)$', filename)
    if not match:
        return None

    decision_id = match.group(1)

    # Extract title from H1
    title_match = re.search(r'^#\s+(.+)$', content, re.MULTILINE)
    title = title_match.group(1) if title_match else filename

    # Extract status (look for Status: in content)
    status_match = re.search(r'Status:\s*(\w+)', content, re.IGNORECASE)
    status = status_match.group(1).lower() if status_match else "accepted"

    # Extract sections
    context_match = re.search(r'## Context\s*\n(.*?)(?=\n##|\Z)', content, re.DOTALL | re.IGNORECASE)
    decision_match = re.search(r'## Decision\s*\n(.*?)(?=\n##|\Z)', content, re.DOTALL | re.IGNORECASE)
    consequences_match = re.search(r'## Consequences\s*\n(.*?)(?=\n##|\Z)', content, re.DOTALL | re.IGNORECASE)

    return Decision(
        id=decision_id,
        title=title,
        status=status,
        path=rel_path,
        context=context_match.group(1).strip()[:2000] if context_match else "",
        decision=decision_match.group(1).strip()[:2000] if decision_match else "",
        consequences=consequences_match.group(1).strip()[:2000] if consequences_match else "",
    )


def run_query(driver, query: str, **params):
    """Run a single query in its own session to avoid bookmark issues with NornicDB."""
    with driver.session() as session:
        return session.run(query, **params)


def create_graph(driver, project: str, docs: list[Document], decisions: list[Decision]):
    """Create the knowledge graph in NornicDB."""

    print(f"Creating graph for project: {project}")

    # Clear existing project nodes (optional - comment out to preserve)
    print("  Clearing existing nodes...")
    run_query(driver, f"""
        MATCH (n:{project})
        DETACH DELETE n
    """)

    # Create Document nodes
    print(f"  Creating {len(docs)} Document nodes...")
    for i, doc in enumerate(docs):
        run_query(driver, f"""
            CREATE (d:{project}:Document {{
                path: $path,
                title: $title,
                type: $type,
                headings: $headings,
                content: $content
            }})
        """,
            path=doc.path,
            title=doc.title,
            type=doc.doc_type,
            headings=doc.headings,
            content=doc.content[:2000]
        )

        # Create Component relationships
        for comp in doc.components:
            run_query(driver, f"""
                MERGE (c:{project}:Component {{name: $name}})
                WITH c
                MATCH (d:{project}:Document {{path: $path}})
                MERGE (d)-[:DESCRIBES]->(c)
            """, name=comp, path=doc.path)

        # Create Concept nodes and relationships
        for concept in doc.concepts[:10]:  # Limit per doc
            run_query(driver, f"""
                MERGE (c:{project}:Concept {{name: $name}})
                WITH c
                MATCH (d:{project}:Document {{path: $path}})
                MERGE (d)-[:MENTIONS]->(c)
            """, name=concept, path=doc.path)

        # Progress indicator
        if (i + 1) % 10 == 0:
            print(f"    Processed {i + 1}/{len(docs)} documents...")

    # Create Decision nodes
    print(f"  Creating {len(decisions)} Decision nodes...")
    for dec in decisions:
        run_query(driver, f"""
            CREATE (d:{project}:Decision {{
                id: $id,
                title: $title,
                status: $status,
                path: $path,
                context: $context,
                decision: $decision,
                consequences: $consequences
            }})
        """,
            id=dec.id,
            title=dec.title,
            status=dec.status,
            path=dec.path,
            context=dec.context,
            decision=dec.decision,
            consequences=dec.consequences
        )

    # Create Document-to-Document references
    print("  Creating document references...")
    for doc in docs:
        for ref in doc.references:
            run_query(driver, f"""
                MATCH (d1:{project}:Document {{path: $from_path}})
                MATCH (d2:{project}:Document {{path: $to_path}})
                MERGE (d1)-[:REFERENCES]->(d2)
            """, from_path=doc.path, to_path=ref)

    # Summary
    with driver.session() as session:
        result = session.run(f"""
            MATCH (n:{project})
            RETURN labels(n) as labels, count(*) as count
        """)

        print("\n  Graph summary:")
        for record in result:
            print(f"    {record['labels']}: {record['count']}")


def main():
    parser = argparse.ArgumentParser(description="Populate NornicDB with documentation graph")
    parser.add_argument("--project", default="TradingEngine", help="Project label (e.g., TradingEngine)")
    parser.add_argument("--docs-path", default="./docs", help="Path to docs directory")
    parser.add_argument("--dry-run", action="store_true", help="Parse docs without writing to DB")
    args = parser.parse_args()

    docs_path = Path(args.docs_path).resolve()
    if not docs_path.exists():
        print(f"ERROR: Docs path not found: {docs_path}")
        sys.exit(1)

    print(f"Scanning docs in: {docs_path}")

    # Find all markdown files
    md_files = list(docs_path.rglob("*.md"))
    print(f"Found {len(md_files)} markdown files")

    # Parse documents
    docs = []
    decisions = []

    for md_file in md_files:
        try:
            # Skip README files at root
            if md_file.name.upper() == "README.MD" and md_file.parent == docs_path:
                continue

            doc = parse_document(md_file, docs_path)
            docs.append(doc)

            # Check if it's a decision doc
            if "decision" in md_file.parent.name.lower() or "02-" in str(md_file):
                dec = parse_decision(md_file, docs_path)
                if dec:
                    decisions.append(dec)

        except Exception as e:
            print(f"  Warning: Failed to parse {md_file}: {e}")

    print(f"Parsed {len(docs)} documents, {len(decisions)} decisions")

    if args.dry_run:
        print("\nDry run - not writing to database")
        print("\nSample documents:")
        for doc in docs[:5]:
            print(f"  - {doc.path}: {doc.title} ({doc.doc_type})")
            print(f"    Components: {doc.components}")
            print(f"    Concepts: {doc.concepts[:5]}")
        return

    # Connect to NornicDB
    print(f"\nConnecting to NornicDB at {NEO4J_URI}...")
    auth = (NEO4J_USER, NEO4J_PASSWORD) if NEO4J_USER else None
    driver = GraphDatabase.driver(NEO4J_URI, auth=auth)

    try:
        # Verify connection
        driver.verify_connectivity()
        print("Connected!")

        # Create the graph
        create_graph(driver, args.project, docs, decisions)

        print("\nDone! Graph populated successfully.")
        print(f"View in browser: http://localhost:7474")

    finally:
        driver.close()


if __name__ == "__main__":
    main()
