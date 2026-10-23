import Foundation
import WorkspaceCore

@main
struct WSCli {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let engine = WorkspaceEngine.shared
        
        guard let command = args.first else {
            printUsage()
            exit(1)
        }
        
        switch command {
        case "doctor":
            handleDoctor(engine: engine, fix: args.contains("--fix"), json: args.contains("--json"))
            
        case "list", "ls":
            handleList(engine: engine, json: args.contains("--json"))
            
        case "create":
            guard args.count >= 2 else {
                print("Error: Ticket identifier required. e.g. 'ws create FINX-1234'")
                exit(1)
            }
            let ticket = args[1]
            let repos = Array(args.dropFirst(2)).filter { !$0.hasPrefix("-") }
            handleCreate(engine: engine, ticket: ticket, repos: repos)
            
        case "reindex":
            guard args.count >= 2 else {
                print("Error: Ticket/workspace name required. e.g. 'ws reindex FINX-1234'")
                exit(1)
            }
            let name = args[1]
            let wsRoot = (engine.config.rootDirectory as NSString).expandingTildeInPath
            let path = (wsRoot as NSString).appendingPathComponent(name)
            let res = engine.reindexWorkspace(workspacePath: path)
            print(res.message)
            exit(res.success ? 0 : 1)
            
        case "prune", "rm":
            guard args.count >= 2 else {
                print("Error: Workspace name required. e.g. 'ws prune FINX-1234'")
                exit(1)
            }
            let name = args[1]
            let force = args.contains("--force") || args.contains("-f")
            do {
                try engine.pruneWorkspace(name: name, force: force)
                print("Successfully pruned workspace \(name).")
            } catch {
                print("Error: \(error.localizedDescription)")
                exit(1)
            }
            
        case "repos":
            handleRepos(engine: engine, json: args.contains("--json"))
            
        default:
            printUsage()
            exit(1)
        }
    }
    
    static func printUsage() {
        print("""
        ws - AI Agent Workspace Orchestrator & Multi-Repo Manager

        Usage:
          ws doctor [--fix] [--json]       Check system prerequisites & AI agents
          ws list [--json]                 List active workspaces and git status
          ws create <ticket> [repos...]    Create worktrees and index with CMB
          ws reindex <name>                Re-run codebase-memory-mcp index
          ws prune <name> [--force]        Safely remove worktrees and workspace
          ws repos [--json]                List configured repositories
        """)
    }
    
    static func handleDoctor(engine: WorkspaceEngine, fix: Bool, json: Bool) {
        var items = engine.checkDoctor()
        
        if fix {
            print("Applying fixes for missing components...")
            for item in items where !item.installed {
                _ = engine.fixDoctor(item: item) { line in
                    print("  \(line)")
                }
            }
            items = engine.checkDoctor()
        }
        
        if json {
            let data = (try? JSONEncoder().encode(items)) ?? Data()
            print(String(data: data, encoding: .utf8) ?? "[]")
            return
        }
        
        print("\n=== System Readiness Doctor ===")
        for item in items {
            let icon = item.installed ? "PASS" : (item.required ? "FAIL" : "WARN")
            let ver = item.version ?? (item.installed ? "installed" : "missing")
            let details = item.details.map { " (\($0))" } ?? ""
            print("[\(icon)] \(item.name): \(ver)\(details)")
            if !item.installed, let fixCmd = item.installCommand {
                print("       Fix: \(fixCmd)")
            }
        }
        print("")
    }
    
    static func handleList(engine: WorkspaceEngine, json: Bool) {
        let workspaces = engine.listWorkspaces()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = (try? encoder.encode(workspaces)) ?? Data()
            print(String(data: data, encoding: .utf8) ?? "[]")
            return
        }
        
        if workspaces.isEmpty {
            print("No active workspaces in \(engine.config.rootDirectory)")
            return
        }
        
        print("\n=== Active Workspaces ===")
        for ws in workspaces {
            let mcpStatus = ws.hasMcpIndex ? "CMB Index: Ready" : "CMB Index: Missing"
            let staleStatus = ws.isStale ? " [STALE >14d]" : ""
            print("\n• \(ws.name)\(staleStatus) - \(ws.path)")
            print("  \(mcpStatus)")
            for repo in ws.repos {
                let br = ws.branches[repo] ?? "main"
                let dirty = ws.dirtyCounts[repo] ?? 0
                let dirtyLabel = dirty > 0 ? " (\(dirty) dirty files)" : " (clean)"
                print("  - \(repo): [\(br)]\(dirtyLabel)")
            }
        }
        print("")
    }
    
    static func handleCreate(engine: WorkspaceEngine, ticket: String, repos: [String]) {
        let repoSelection = repos.isEmpty ? engine.config.repos.map { $0.name } : repos
        print("Provisioning workspace for \(ticket) with repos: \(repoSelection.joined(separator: ", "))...")
        do {
            let path = try engine.createWorkspace(ticket: ticket, selectedRepoNames: repoSelection) { progress in
                print("  -> \(progress)")
            }
            print("\nDone. Workspace ready at:\ncd \(path)")
        } catch {
            print("\nError: \(error.localizedDescription)")
            exit(1)
        }
    }
    
    static func handleRepos(engine: WorkspaceEngine, json: Bool) {
        if json {
            let data = (try? JSONEncoder().encode(engine.config.repos)) ?? Data()
            print(String(data: data, encoding: .utf8) ?? "[]")
            return
        }
        print("\n=== Configured Repositories ===")
        for r in engine.config.repos {
            print("• \(r.name) (\(r.defaultBranch)) -> \(r.cloneUrl)")
        }
        print("")
    }
}
