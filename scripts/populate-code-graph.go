// Code Graph Populator for NornicDB
//
// Parses Go source files using the Go AST parser and creates a code structure
// graph in NornicDB for use by Claude Code.
//
// Usage:
//
//	go run scripts/populate-code-graph.go [--project PROJECT_NAME] [--path PATH]
//
// Example:
//
//	go run scripts/populate-code-graph.go --project TradingEngine --path .
package main

import (
	"context"
	"flag"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"

	"github.com/neo4j/neo4j-go-driver/v5/neo4j"
)

// Config holds the populator configuration
type Config struct {
	Project  string
	Path     string
	Neo4jURI string
	DryRun   bool
}

// FileNode represents a source file in the graph
type FileNode struct {
	Path     string
	Package  string
	Language string
	Imports  []string
}

// FunctionNode represents a function/method in the graph
type FunctionNode struct {
	Name      string
	File      string
	Signature string
	Receiver  string // empty for functions, type name for methods
	IsExport  bool
	LineStart int
	LineEnd   int
}

// StructNode represents a struct definition
type StructNode struct {
	Name     string
	File     string
	Fields   []string
	IsExport bool
}

// InterfaceNode represents an interface definition
type InterfaceNode struct {
	Name     string
	File     string
	Methods  []string
	IsExport bool
}

// PackageNode represents a Go package
type PackageNode struct {
	Name string
	Path string
}

// CodeGraph holds all parsed code elements
type CodeGraph struct {
	Files      []FileNode
	Functions  []FunctionNode
	Structs    []StructNode
	Interfaces []InterfaceNode
	Packages   []PackageNode
}

func main() {
	cfg := Config{
		Neo4jURI: getEnvOrDefault("NEO4J_URI", "bolt://localhost:7687"),
	}

	flag.StringVar(&cfg.Project, "project", "TradingEngine", "Project label for graph nodes")
	flag.StringVar(&cfg.Path, "path", ".", "Path to Go source code")
	flag.BoolVar(&cfg.DryRun, "dry-run", false, "Parse code without writing to DB")
	flag.Parse()

	fmt.Printf("Code Graph Populator\n")
	fmt.Printf("  Project: %s\n", cfg.Project)
	fmt.Printf("  Path: %s\n", cfg.Path)
	fmt.Printf("  Neo4j: %s\n", cfg.Neo4jURI)
	fmt.Println()

	// Parse the codebase
	graph, err := parseCodebase(cfg.Path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error parsing codebase: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Parsed:\n")
	fmt.Printf("  Files: %d\n", len(graph.Files))
	fmt.Printf("  Packages: %d\n", len(graph.Packages))
	fmt.Printf("  Functions: %d\n", len(graph.Functions))
	fmt.Printf("  Structs: %d\n", len(graph.Structs))
	fmt.Printf("  Interfaces: %d\n", len(graph.Interfaces))
	fmt.Println()

	if cfg.DryRun {
		fmt.Println("Dry run - not writing to database")
		printSample(graph)
		return
	}

	// Connect to NornicDB
	ctx := context.Background()
	driver, err := neo4j.NewDriverWithContext(cfg.Neo4jURI, neo4j.NoAuth())
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error connecting to Neo4j: %v\n", err)
		os.Exit(1)
	}
	defer driver.Close(ctx)

	// Verify connection
	if err := driver.VerifyConnectivity(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "Cannot connect to Neo4j: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("Connected to NornicDB!")

	// Create the graph
	if err := createGraph(ctx, driver, cfg.Project, graph); err != nil {
		fmt.Fprintf(os.Stderr, "Error creating graph: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("\nDone! Code graph populated successfully.")
	fmt.Println("View in browser: http://localhost:7474")
}

func getEnvOrDefault(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func parseCodebase(root string) (*CodeGraph, error) {
	graph := &CodeGraph{}
	fset := token.NewFileSet()
	seenPackages := make(map[string]bool)

	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		// Skip hidden directories and common non-source directories
		if info.IsDir() {
			name := info.Name()
			if strings.HasPrefix(name, ".") || name == "vendor" || name == "node_modules" {
				return filepath.SkipDir
			}
			return nil
		}

		// Only process .go files (not test files for now)
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}

		// Parse the file
		file, err := parser.ParseFile(fset, path, nil, parser.ParseComments)
		if err != nil {
			fmt.Printf("  Warning: Failed to parse %s: %v\n", path, err)
			return nil
		}

		relPath, _ := filepath.Rel(root, path)

		// Extract file info
		fileNode := FileNode{
			Path:     relPath,
			Package:  file.Name.Name,
			Language: "go",
			Imports:  extractImports(file),
		}
		graph.Files = append(graph.Files, fileNode)

		// Track packages
		pkgPath := filepath.Dir(relPath)
		if !seenPackages[pkgPath] {
			seenPackages[pkgPath] = true
			graph.Packages = append(graph.Packages, PackageNode{
				Name: file.Name.Name,
				Path: pkgPath,
			})
		}

		// Extract declarations
		for _, decl := range file.Decls {
			switch d := decl.(type) {
			case *ast.FuncDecl:
				fn := extractFunction(d, relPath, fset)
				graph.Functions = append(graph.Functions, fn)

			case *ast.GenDecl:
				for _, spec := range d.Specs {
					switch s := spec.(type) {
					case *ast.TypeSpec:
						switch t := s.Type.(type) {
						case *ast.StructType:
							st := extractStruct(s, t, relPath)
							graph.Structs = append(graph.Structs, st)
						case *ast.InterfaceType:
							iface := extractInterface(s, t, relPath)
							graph.Interfaces = append(graph.Interfaces, iface)
						}
					}
				}
			}
		}

		return nil
	})

	return graph, err
}

func extractImports(file *ast.File) []string {
	var imports []string
	for _, imp := range file.Imports {
		path := strings.Trim(imp.Path.Value, `"`)
		imports = append(imports, path)
	}
	return imports
}

func extractFunction(fn *ast.FuncDecl, file string, fset *token.FileSet) FunctionNode {
	node := FunctionNode{
		Name:      fn.Name.Name,
		File:      file,
		IsExport:  ast.IsExported(fn.Name.Name),
		LineStart: fset.Position(fn.Pos()).Line,
		LineEnd:   fset.Position(fn.End()).Line,
	}

	// Build signature
	var sig strings.Builder
	sig.WriteString("func ")

	// Check for receiver (method)
	if fn.Recv != nil && len(fn.Recv.List) > 0 {
		recv := fn.Recv.List[0]
		recvType := exprToString(recv.Type)
		node.Receiver = recvType
		sig.WriteString("(" + recvType + ") ")
	}

	sig.WriteString(fn.Name.Name)
	sig.WriteString(formatParams(fn.Type.Params))

	if fn.Type.Results != nil && len(fn.Type.Results.List) > 0 {
		sig.WriteString(" ")
		sig.WriteString(formatParams(fn.Type.Results))
	}

	node.Signature = sig.String()
	return node
}

func extractStruct(spec *ast.TypeSpec, st *ast.StructType, file string) StructNode {
	node := StructNode{
		Name:     spec.Name.Name,
		File:     file,
		IsExport: ast.IsExported(spec.Name.Name),
	}

	for _, field := range st.Fields.List {
		fieldType := exprToString(field.Type)
		for _, name := range field.Names {
			node.Fields = append(node.Fields, name.Name+" "+fieldType)
		}
		if len(field.Names) == 0 {
			// Embedded field
			node.Fields = append(node.Fields, fieldType)
		}
	}

	return node
}

func extractInterface(spec *ast.TypeSpec, iface *ast.InterfaceType, file string) InterfaceNode {
	node := InterfaceNode{
		Name:     spec.Name.Name,
		File:     file,
		IsExport: ast.IsExported(spec.Name.Name),
	}

	for _, method := range iface.Methods.List {
		for _, name := range method.Names {
			if fn, ok := method.Type.(*ast.FuncType); ok {
				sig := name.Name + formatParams(fn.Params)
				if fn.Results != nil {
					sig += " " + formatParams(fn.Results)
				}
				node.Methods = append(node.Methods, sig)
			}
		}
	}

	return node
}

func exprToString(expr ast.Expr) string {
	switch e := expr.(type) {
	case *ast.Ident:
		return e.Name
	case *ast.StarExpr:
		return "*" + exprToString(e.X)
	case *ast.SelectorExpr:
		return exprToString(e.X) + "." + e.Sel.Name
	case *ast.ArrayType:
		return "[]" + exprToString(e.Elt)
	case *ast.MapType:
		return "map[" + exprToString(e.Key) + "]" + exprToString(e.Value)
	case *ast.InterfaceType:
		return "interface{}"
	case *ast.FuncType:
		return "func" + formatParams(e.Params)
	default:
		return "..."
	}
}

func formatParams(fields *ast.FieldList) string {
	if fields == nil {
		return "()"
	}

	var parts []string
	for _, field := range fields.List {
		fieldType := exprToString(field.Type)
		if len(field.Names) > 0 {
			for _, name := range field.Names {
				parts = append(parts, name.Name+" "+fieldType)
			}
		} else {
			parts = append(parts, fieldType)
		}
	}
	return "(" + strings.Join(parts, ", ") + ")"
}

func createGraph(ctx context.Context, driver neo4j.DriverWithContext, project string, graph *CodeGraph) error {
	session := driver.NewSession(ctx, neo4j.SessionConfig{})
	defer session.Close(ctx)

	fmt.Println("Creating graph nodes...")

	// Clear existing project nodes
	fmt.Printf("  Clearing existing %s:Code nodes...\n", project)
	_, err := session.Run(ctx, fmt.Sprintf(`
		MATCH (n:%s) WHERE n:File OR n:Package OR n:Function OR n:Struct OR n:Interface
		DETACH DELETE n
	`, project), nil)
	if err != nil {
		return fmt.Errorf("clearing nodes: %w", err)
	}

	// Create Package nodes
	fmt.Printf("  Creating %d Package nodes...\n", len(graph.Packages))
	for _, pkg := range graph.Packages {
		_, err := session.Run(ctx, fmt.Sprintf(`
			CREATE (p:%s:Package {name: $name, path: $path})
		`, project), map[string]any{
			"name": pkg.Name,
			"path": pkg.Path,
		})
		if err != nil {
			return fmt.Errorf("creating package %s: %w", pkg.Name, err)
		}
	}

	// Create File nodes with BELONGS_TO package relationship
	fmt.Printf("  Creating %d File nodes...\n", len(graph.Files))
	for _, file := range graph.Files {
		pkgPath := filepath.Dir(file.Path)
		_, err := session.Run(ctx, fmt.Sprintf(`
			CREATE (f:%s:File {path: $path, package: $package, language: $language, imports: $imports})
			WITH f
			MATCH (p:%s:Package {path: $pkgPath})
			MERGE (f)-[:BELONGS_TO]->(p)
		`, project, project), map[string]any{
			"path":     file.Path,
			"package":  file.Package,
			"language": file.Language,
			"imports":  file.Imports,
			"pkgPath":  pkgPath,
		})
		if err != nil {
			return fmt.Errorf("creating file %s: %w", file.Path, err)
		}
	}

	// Create Function nodes
	fmt.Printf("  Creating %d Function nodes...\n", len(graph.Functions))
	for _, fn := range graph.Functions {
		label := "Function"
		if fn.Receiver != "" {
			label = "Method"
		}
		_, err := session.Run(ctx, fmt.Sprintf(`
			CREATE (fn:%s:%s {
				name: $name,
				file: $file,
				signature: $signature,
				receiver: $receiver,
				isExport: $isExport,
				lineStart: $lineStart,
				lineEnd: $lineEnd
			})
			WITH fn
			MATCH (f:%s:File {path: $file})
			MERGE (f)-[:CONTAINS]->(fn)
		`, project, label, project), map[string]any{
			"name":      fn.Name,
			"file":      fn.File,
			"signature": fn.Signature,
			"receiver":  fn.Receiver,
			"isExport":  fn.IsExport,
			"lineStart": fn.LineStart,
			"lineEnd":   fn.LineEnd,
		})
		if err != nil {
			return fmt.Errorf("creating function %s: %w", fn.Name, err)
		}
	}

	// Create Struct nodes
	fmt.Printf("  Creating %d Struct nodes...\n", len(graph.Structs))
	for _, st := range graph.Structs {
		_, err := session.Run(ctx, fmt.Sprintf(`
			CREATE (s:%s:Struct {name: $name, file: $file, fields: $fields, isExport: $isExport})
			WITH s
			MATCH (f:%s:File {path: $file})
			MERGE (f)-[:CONTAINS]->(s)
		`, project, project), map[string]any{
			"name":     st.Name,
			"file":     st.File,
			"fields":   st.Fields,
			"isExport": st.IsExport,
		})
		if err != nil {
			return fmt.Errorf("creating struct %s: %w", st.Name, err)
		}
	}

	// Create Interface nodes
	fmt.Printf("  Creating %d Interface nodes...\n", len(graph.Interfaces))
	for _, iface := range graph.Interfaces {
		_, err := session.Run(ctx, fmt.Sprintf(`
			CREATE (i:%s:Interface {name: $name, file: $file, methods: $methods, isExport: $isExport})
			WITH i
			MATCH (f:%s:File {path: $file})
			MERGE (f)-[:CONTAINS]->(i)
		`, project, project), map[string]any{
			"name":     iface.Name,
			"file":     iface.File,
			"methods":  iface.Methods,
			"isExport": iface.IsExport,
		})
		if err != nil {
			return fmt.Errorf("creating interface %s: %w", iface.Name, err)
		}
	}

	// Create IMPORTS relationships between files and packages
	fmt.Println("  Creating IMPORTS relationships...")
	for _, file := range graph.Files {
		for _, imp := range file.Imports {
			// Try to find the imported package in our codebase
			_, err := session.Run(ctx, fmt.Sprintf(`
				MATCH (f:%s:File {path: $filePath})
				MATCH (p:%s:Package) WHERE $import ENDS WITH p.path
				MERGE (f)-[:IMPORTS]->(p)
			`, project, project), map[string]any{
				"filePath": file.Path,
				"import":   imp,
			})
			if err != nil {
				// Non-fatal - external imports won't match
				continue
			}
		}
	}

	// Print summary
	result, err := session.Run(ctx, fmt.Sprintf(`
		MATCH (n:%s)
		RETURN labels(n) as labels, count(*) as count
	`, project), nil)
	if err != nil {
		return fmt.Errorf("getting summary: %w", err)
	}

	fmt.Println("\n  Graph summary:")
	for result.Next(ctx) {
		record := result.Record()
		labels, _ := record.Get("labels")
		count, _ := record.Get("count")
		fmt.Printf("    %v: %v\n", labels, count)
	}

	return nil
}

func printSample(graph *CodeGraph) {
	fmt.Println("\nSample data:")

	fmt.Println("\nPackages:")
	for i, pkg := range graph.Packages {
		if i >= 5 {
			fmt.Printf("  ... and %d more\n", len(graph.Packages)-5)
			break
		}
		fmt.Printf("  - %s (%s)\n", pkg.Name, pkg.Path)
	}

	fmt.Println("\nFiles:")
	for i, file := range graph.Files {
		if i >= 5 {
			fmt.Printf("  ... and %d more\n", len(graph.Files)-5)
			break
		}
		fmt.Printf("  - %s (imports: %d)\n", file.Path, len(file.Imports))
	}

	fmt.Println("\nFunctions:")
	for i, fn := range graph.Functions {
		if i >= 10 {
			fmt.Printf("  ... and %d more\n", len(graph.Functions)-10)
			break
		}
		fmt.Printf("  - %s\n", fn.Signature)
	}

	fmt.Println("\nStructs:")
	for i, st := range graph.Structs {
		if i >= 5 {
			fmt.Printf("  ... and %d more\n", len(graph.Structs)-5)
			break
		}
		fmt.Printf("  - %s (fields: %d)\n", st.Name, len(st.Fields))
	}

	fmt.Println("\nInterfaces:")
	for i, iface := range graph.Interfaces {
		if i >= 5 {
			fmt.Printf("  ... and %d more\n", len(graph.Interfaces)-5)
			break
		}
		fmt.Printf("  - %s (methods: %d)\n", iface.Name, len(iface.Methods))
	}
}
