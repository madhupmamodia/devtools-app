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
            guard args.count >= 3 else {
                print("Error: Usage: ws create <ticket> <name> [repo...]")
                print("  e.g. ws create FINX-1234 credit-note-application billing-service")
                exit(1)
            }
            let ticket = args[1]
            let wsName = args[2]
            let repos = Array(args.dropFirst(3)).filter { !$0.hasPrefix("-") }
            let all = args.contains("--all")
            if repos.isEmpty && !all {
                print("Error: Name the repositories to mount, e.g. 'ws create \(ticket) \(wsName) billing-service'")
                print("       Or pass --all to mount every repository in the catalog (\(engine.config.repos.count)).")
                exit(1)
            }
            handleCreate(engine: engine, ticket: ticket, name: wsName, repos: repos, all: all)
            
        case "add":
            guard args.count >= 3 else {
                print("Error: Usage: ws add <workspace> <repo> [repo...]")
                exit(1)
            }
            let wsName = args[1]
            let repos = Array(args.dropFirst(2)).filter { !$0.hasPrefix("-") }
            do {
                try engine.addRepos(toWorkspace: wsName, repoNames: repos) { progress in
                    print("  -> \(progress)")
                }
                print("\nDone. Added to \(wsName): \(repos.joined(separator: ", "))")
            } catch {
                print("\nError: \(error.localizedDescription)")
                exit(1)
            }
            
        case "remove", "rm":
            guard args.count >= 3 else {
                print("Error: Usage: ws remove <workspace> <repo...> [--force]")
                exit(1)
            }
            let wsName = args[1]
            let repos = Array(args.dropFirst(2)).filter { !$0.hasPrefix("-") }
            do {
                try engine.removeRepos(fromWorkspace: wsName, repoNames: repos, force: args.contains("--force"))
                print("Removed from \(wsName): \(repos.joined(separator: ", "))")
                print("Branches kept in the mirror — re-add any time with: ws add \(wsName) <repo>")
            } catch {
                print("Error: \(error.localizedDescription)")
                exit(1)
            }
            
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
            handleRepos(engine: engine, json: args.contains("--json"), sync: args.contains("--sync"))

        case "usage":
            handleUsage(engine: engine, sync: args.contains("--sync"), days: daysArg(args))
            
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
          ws create <ticket> <name> <repo...>  Create worktrees and index with CMB
          (add --all to mount every repo in the catalog)
          ws add <ws> <repo...>      Add repos to an existing workspace
          ws remove <ws> <repo...>   Remove repos from a workspace (branches are kept)
          ws reindex <name>                Re-run codebase-memory-mcp index
          ws prune <name> [--force]        Safely remove worktrees and workspace
          ws repos [--json] [--sync]      List configured repositories, or refresh from GitHub org
          ws usage [--sync] [--days N]  Rank repos by your own PR/commit activity
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
    
    static func handleCreate(engine: WorkspaceEngine, ticket: String, name: String, repos: [String], all: Bool) {
        let repoSelection = all ? engine.config.repos.map { $0.name } : repos
        print("Provisioning workspace for \(ticket) with repos: \(repoSelection.joined(separator: ", "))...")
        do {
            let path = try engine.createWorkspace(ticket: ticket, name: name, selectedRepoNames: repoSelection) { ev in
                print("  -> \(describe(ev))")
            }
            print("\nDone. Workspace ready at:\ncd \(path)")
        } catch {
            print("\nError: \(error.localizedDescription)")
            exit(1)
        }
    }
    
    static func daysArg(_ args: [String]) -> Int {
        guard let i = args.firstIndex(of: "--days"), i + 1 < args.count, let n = Int(args[i + 1]) else {
            return 365
        }
        return n
    }
    
    static func handleUsage(engine: WorkspaceEngine, sync: Bool, days: Int) {
        if sync {
            guard let usage = engine.syncRepoUsage(sinceDays: days) else {
                print("Usage fetch failed. Check 'gh auth status'.")
                exit(1)
            }
            print("Ranked by PR/commit activity since \(days) days ago (\(usage.login)).\n")
            let ranked = engine.config.repos
                .map { ($0.name, engine.usageScore(for: $0.name, usage: usage)) }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
            guard !ranked.isEmpty else {
                print("No activity found.")
                return
            }
            for (i, entry) in ranked.enumerated() {
                let prs = usage.prCounts[entry.0] ?? 0
                let commits = usage.commitCounts[entry.0] ?? 0
                print(String(format: "%2d. %-40@  %4d PRs  %4d commits  (score %d)", i + 1, entry.0 as NSString, prs, commits, entry.1))
            }
            return
        }
        guard let usage = engine.loadRepoUsage() else {
            print("No cached usage. Run: ws usage --sync")
            return
        }
        print("Cached usage for \(usage.login) fetched \(usage.fetchedAt).")
        let ranked = usage.prCounts
            .map { ($0.key, $0.value) }
            .sorted { $0.1 > $1.1 }
        for (i, entry) in ranked.enumerated() {
            print(String(format: "%2d. %-40@  %4d PRs", i + 1, entry.0 as NSString, entry.1))
        }
    }
    
    static func describe(_ ev: WorkspaceEngine.ProvisionEvent) -> String {
        switch ev {
        case .repoStarted(let r): return "\(r): starting"
        case .repoPhase(let r, let p): return "\(r): \(p.rawValue)"
        case .repoSkipped(let r, let why): return "\(r): skipped (\(why))"
        case .indexing: return "indexing semantic graph"
        case .complete: return "ready"
        }
    }
    
    static func handleRepos(engine: WorkspaceEngine, json: Bool, sync: Bool) {
        if sync {
            let count = engine.syncReposFromGitHub()
            if count == 0 {
                print("Sync failed. Check 'gh auth status' and org access.")
                exit(1)
            }
            if json {
                let data = (try? JSONEncoder().encode(engine.config.repos)) ?? Data()
                print(String(data: data, encoding: .utf8) ?? "[]")
                return
            }
            print("Synced \(count) repos from \(engine.config.defaultOrg).")
            return
        }
        if json {
            let data = (try? JSONEncoder().encode(engine.config.repos)) ?? Data()
            print(String(data: data, encoding: .utf8) ?? "[]")
            return
        }
        print("\n=== Configured Repositories (\(engine.config.repos.count)) ===")
        for r in engine.config.repos {
            print("• \(r.name) (\(r.defaultBranch)) -> \(r.cloneUrl)")
        }
        if engine.config.repos.isEmpty {
            print("No repos cached. Run: ws repos --sync")
        }
        print("")
    }
}
