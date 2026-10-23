import Foundation

public final class WorkspaceEngine: @unchecked Sendable {
    public static let shared = WorkspaceEngine()
    
    public var config: WSConfig
    private let configURL: URL
    
    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configDir = home.appendingPathComponent(".config/ws")
        self.configURL = configDir.appendingPathComponent("config.json")
        
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        
        if let data = try? Data(contentsOf: configURL),
           let loaded = try? JSONDecoder().decode(WSConfig.self, from: data) {
            self.config = loaded
        } else {
            // Default Multiplier Repos
            var cfg = WSConfig()
            cfg.repos = [
                RepoDefinition(name: "multiplier-frontend", cloneUrl: "git@github.com:Multiplier-Core/multiplier-frontend.git", defaultBranch: "main"),
                RepoDefinition(name: "billing-service", cloneUrl: "git@github.com:Multiplier-Core/billing-service.git", defaultBranch: "main"),
                RepoDefinition(name: "payable-service", cloneUrl: "git@github.com:Multiplier-Core/payable-service.git", defaultBranch: "main"),
                RepoDefinition(name: "contract-service", cloneUrl: "git@github.com:Multiplier-Core/contract-service.git", defaultBranch: "main"),
                RepoDefinition(name: "user-service", cloneUrl: "git@github.com:Multiplier-Core/user-service.git", defaultBranch: "main"),
                RepoDefinition(name: "company-service", cloneUrl: "git@github.com:Multiplier-Core/company-service.git", defaultBranch: "main")
            ]
            self.config = cfg
            if let data = try? JSONEncoder().encode(cfg) {
                try? data.write(to: configURL)
            }
        }
    }
    
    public func saveConfig() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(config) {
            try? data.write(to: configURL)
        }
    }
    
    // MARK: - Doctor
    public func checkDoctor() -> [DoctorItem] {
        var items: [DoctorItem] = []
        
        // 1. Git
        let gitRes = ProcessRunner.run("which git && git --version")
        items.append(DoctorItem(
            name: "git",
            command: "git",
            required: true,
            installed: gitRes.exitCode == 0,
            version: gitRes.stdout.components(separatedBy: "\n").last,
            path: gitRes.stdout.components(separatedBy: "\n").first,
            installCommand: "brew install git"
        ))
        
        // 2. GitHub CLI & Auth
        let ghRes = ProcessRunner.run("which gh && gh --version")
        let ghAuth = ProcessRunner.run("gh auth status")
        let ghInstalled = ghRes.exitCode == 0
        items.append(DoctorItem(
            name: "gh (GitHub CLI)",
            command: "gh",
            required: true,
            installed: ghInstalled,
            version: ghRes.stdout.components(separatedBy: "\n").first,
            details: ghAuth.exitCode == 0 ? "Authenticated" : "Not authenticated (run 'gh auth login')",
            installCommand: "brew install gh && gh auth login"
        ))
        
        // 3. Node.js & npm
        let nodeRes = ProcessRunner.run("which node && node -v")
        items.append(DoctorItem(
            name: "node",
            command: "node",
            required: true,
            installed: nodeRes.exitCode == 0,
            version: nodeRes.stdout.components(separatedBy: "\n").last,
            path: nodeRes.stdout.components(separatedBy: "\n").first,
            installCommand: "brew install node"
        ))
        
        // 4. Python 3
        let pyRes = ProcessRunner.run("which python3 && python3 --version")
        items.append(DoctorItem(
            name: "python3",
            command: "python3",
            required: true,
            installed: pyRes.exitCode == 0,
            version: pyRes.stdout.components(separatedBy: "\n").last,
            path: pyRes.stdout.components(separatedBy: "\n").first,
            installCommand: "brew install python3"
        ))
        
        // 5. codebase-memory-mcp
        let cbmRes = ProcessRunner.run("which codebase-memory-mcp")
        let cbmInstalled = cbmRes.exitCode == 0
        items.append(DoctorItem(
            name: "codebase-memory-mcp",
            command: "codebase-memory-mcp",
            required: true,
            installed: cbmInstalled,
            version: cbmInstalled ? ProcessRunner.run("codebase-memory-mcp --version").stdout : nil,
            path: cbmInstalled ? cbmRes.stdout : nil,
            details: cbmInstalled ? "Ready for AST indexing" : "Required for AI agent cross-repo graph",
            installCommand: "npm install -g codebase-memory-mcp"
        ))
        
        // 6. Agents
        let agents = [
            ("opencode", "which opencode", "npm install -g opencode-ai"),
            ("claude", "which claude", "npm install -g @anthropic-ai/claude-code"),
            ("cursor", "test -d /Applications/Cursor.app || which cursor", "brew install --cask cursor"),
            ("codex", "which codex", "brew install codex")
        ]
        
        for (agentName, checkCmd, installCmd) in agents {
            let res = ProcessRunner.run(checkCmd)
            items.append(DoctorItem(
                name: agentName,
                command: agentName,
                required: false,
                installed: res.exitCode == 0,
                version: nil,
                path: res.exitCode == 0 ? res.stdout : nil,
                installCommand: installCmd
            ))
        }
        
        return items
    }
    
    public func fixDoctor(item: DoctorItem, onOutput: ((String) -> Void)? = nil) -> Bool {
        guard let installCmd = item.installCommand else { return false }
        onOutput?("Running: \(installCmd)...")
        let res = ProcessRunner.run(installCmd)
        if res.exitCode == 0 {
            onOutput?("Successfully installed \(item.name)")
            return true
        } else {
            onOutput?("Failed to install \(item.name): \(res.stderr)")
            return false
        }
    }
    
    // MARK: - Workspaces
    public func listWorkspaces() -> [WorkspaceInfo] {
        let wsRoot = (config.rootDirectory as NSString).expandingTildeInPath
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: wsRoot) else {
            return []
        }
        
        var list: [WorkspaceInfo] = []
        let now = Date()
        
        for name in entries.sorted() {
            if name.hasPrefix(".") { continue }
            let wsPath = (wsRoot as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: wsPath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            
            // Repos inside
            guard let subEntries = try? FileManager.default.contentsOfDirectory(atPath: wsPath) else {
                continue
            }
            
            var repos: [String] = []
            var branches: [String: String] = [:]
            var dirtyCounts: [String: Int] = [:]
            var maxModDate = (try? FileManager.default.attributesOfItem(atPath: wsPath)[.modificationDate] as? Date) ?? now
            
            for sub in subEntries {
                let subPath = (wsPath as NSString).appendingPathComponent(sub)
                let gitPath = (subPath as NSString).appendingPathComponent(".git")
                if FileManager.default.fileExists(atPath: gitPath) {
                    repos.append(sub)
                    
                    // branch
                    let brRes = ProcessRunner.run("git branch --show-current", currentDirectory: subPath)
                    branches[sub] = brRes.stdout.isEmpty ? "HEAD" : brRes.stdout
                    
                    // dirty count
                    let statusRes = ProcessRunner.run("git status --porcelain", currentDirectory: subPath)
                    let count = statusRes.stdout.split(separator: "\n").filter { !$0.isEmpty }.count
                    dirtyCounts[sub] = count
                    
                    // last commit date
                    let dateRes = ProcessRunner.run("git log -1 --format=%ct", currentDirectory: subPath)
                    if let ts = Double(dateRes.stdout) {
                        let commitDate = Date(timeIntervalSince1970: ts)
                        if commitDate > maxModDate {
                            maxModDate = commitDate
                        }
                    }
                }
            }
            
            // CMB index check
            let cbmPath = (wsPath as NSString).appendingPathComponent(".codebase-memory")
            let hasMcp = FileManager.default.fileExists(atPath: cbmPath)
            
            let daysOld = now.timeIntervalSince(maxModDate) / 86400.0
            let isStale = daysOld > 14.0
            
            let ticket = name.split(separator: "-").first.map(String.init) ?? name
            
            list.append(WorkspaceInfo(
                name: name,
                ticket: ticket,
                path: wsPath,
                repos: repos,
                branches: branches,
                dirtyCounts: dirtyCounts,
                hasMcpIndex: hasMcp,
                isStale: isStale,
                lastModified: maxModDate
            ))
        }
        
        return list
    }
    
    // MARK: - Provisioning
    public func createWorkspace(
        ticket: String,
        selectedRepoNames: [String],
        onProgress: @escaping (String) -> Void
    ) throws -> String {
        let cleanTicket = ticket.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanTicket.isEmpty else {
            throw NSError(domain: "ws", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ticket name cannot be empty."])
        }
        
        let wsRoot = (config.rootDirectory as NSString).expandingTildeInPath
        let cacheRoot = (config.cacheDirectory as NSString).expandingTildeInPath
        let wsPath = (wsRoot as NSString).appendingPathComponent(cleanTicket)
        
        try FileManager.default.createDirectory(atPath: wsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: cacheRoot, withIntermediateDirectories: true)
        
        if FileManager.default.fileExists(atPath: wsPath) {
            throw NSError(domain: "ws", code: 2, userInfo: [NSLocalizedDescriptionKey: "Workspace \(cleanTicket) already exists at \(wsPath)"])
        }
        
        try FileManager.default.createDirectory(atPath: wsPath, withIntermediateDirectories: true)
        
        let repoDefs = config.repos.filter { selectedRepoNames.contains($0.name) }
        guard !repoDefs.isEmpty else {
            throw NSError(domain: "ws", code: 3, userInfo: [NSLocalizedDescriptionKey: "No valid repositories selected."])
        }
        
        for repo in repoDefs {
            onProgress("Syncing mirror for \(repo.name)...")
            let barePath = (cacheRoot as NSString).appendingPathComponent("\(repo.name).git")
            
            if !FileManager.default.fileExists(atPath: barePath) {
                onProgress("Initial mirror clone for \(repo.name)...")
                let cloneRes = ProcessRunner.run("git clone --mirror \(repo.cloneUrl) \"\(barePath)\"")
                if cloneRes.exitCode != 0 {
                    throw NSError(domain: "ws", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to mirror \(repo.name): \(cloneRes.stderr)"])
                }
            } else {
                onProgress("Updating mirror cache for \(repo.name)...")
                _ = ProcessRunner.run("git --git-dir=\"\(barePath)\" fetch --all --prune")
            }
            
            onProgress("Resolving branch for \(repo.name)...")
            let targetRepoPath = (wsPath as NSString).appendingPathComponent(repo.name)
            
            // Check if branch exists on remote or local
            let checkRemote = ProcessRunner.run("git --git-dir=\"\(barePath)\" branch -r --list \"origin/*\(cleanTicket)*\"")
            let checkLocal = ProcessRunner.run("git --git-dir=\"\(barePath)\" branch --list \"*\(cleanTicket)*\"")
            
            var branchToUse = cleanTicket
            var addCommand = ""
            
            if let matchedRemote = checkRemote.stdout.split(separator: "\n").first?.trimmingCharacters(in: .whitespaces) {
                // e.g. origin/FINX-1234 or origin/feat/FINX-1234
                let branchName = matchedRemote.replacingOccurrences(of: "origin/", with: "")
                branchToUse = branchName
                addCommand = "git --git-dir=\"\(barePath)\" worktree add \"\(targetRepoPath)\" \"\(branchName)\""
            } else if let matchedLocal = checkLocal.stdout.split(separator: "\n").first?.trimmingCharacters(in: .whitespaces) {
                branchToUse = matchedLocal
                addCommand = "git --git-dir=\"\(barePath)\" worktree add \"\(targetRepoPath)\" \"\(matchedLocal)\""
            } else {
                // Brand new branch from origin/main (or defaultBranch)
                let baseBranch = repo.defaultBranch
                addCommand = "git --git-dir=\"\(barePath)\" worktree add -b \"\(cleanTicket)\" \"\(targetRepoPath)\" \"origin/\(baseBranch)\""
            }
            
            onProgress("Adding worktree for \(repo.name) [branch: \(branchToUse)]...")
            let wtRes = ProcessRunner.run(addCommand)
            if wtRes.exitCode != 0 {
                throw NSError(domain: "ws", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed worktree for \(repo.name): \(wtRes.stderr)"])
            }
            
            // Auto install post-commit hook for incremental index
            installGitHook(at: targetRepoPath)
        }
        
        // Write workspace.md context file
        onProgress("Writing workspace context summary...")
        let contextMd = """
        # Workspace: \(cleanTicket)
        Provisioned: \(Date())
        
        ## Repositories
        \(repoDefs.map { "- **\($0.name)** (worktree)" }.joined(separator: "\n"))
        
        ## AI Agent Guidelines
        - Cross-repo symbols and definitions indexed via `codebase-memory-mcp`.
        - Use `search_graph` or `query_graph` to trace cross-service interactions.
        - Run tests and linters natively inside respective subdirectories.
        """
        try? contextMd.write(toFile: (wsPath as NSString).appendingPathComponent("workspace.md"), atomically: true, encoding: .utf8)
        
        // Auto register MCP configs
        onProgress("Registering MCP config for AI agents...")
        registerMcpClients(workspacePath: wsPath)
        
        // Auto index via codebase-memory-mcp
        onProgress("Building semantic code graph (codebase-memory-mcp)...")
        _ = reindexWorkspace(workspacePath: wsPath)
        
        onProgress("Workspace \(cleanTicket) ready.")
        return wsPath
    }
    
    public func reindexWorkspace(workspacePath: String) -> (success: Bool, message: String) {
        // Run codebase-memory-mcp index
        let res = ProcessRunner.run("codebase-memory-mcp cli index_repository --repo-path \"\(workspacePath)\" --mode fast --persistence true")
        if res.exitCode == 0 {
            return (true, "Semantic graph successfully indexed.")
        } else {
            return (false, "Index warning: \(res.stderr.isEmpty ? res.stdout : res.stderr)")
        }
    }
    
    private func installGitHook(at repoPath: String) {
        let hookDir = (repoPath as NSString).appendingPathComponent(".git/hooks")
        try? FileManager.default.createDirectory(atPath: hookDir, withIntermediateDirectories: true)
        
        let postCommitScript = """
        #!/bin/sh
        # Auto-update codebase-memory-mcp graph incrementally on commit
        if which codebase-memory-mcp >/dev/null 2>&1; then
            WORKSPACE_DIR="$(git rev-parse --show-toplevel)/.."
            codebase-memory-mcp cli index_repository --repo-path "$WORKSPACE_DIR" --mode fast --persistence true >/dev/null 2>&1 &
        fi
        """
        let hookFile = (hookDir as NSString).appendingPathComponent("post-commit")
        try? postCommitScript.write(toFile: hookFile, atomically: true, encoding: .utf8)
        _ = ProcessRunner.run("chmod +x \"\(hookFile)\"")
    }
    
    private func registerMcpClients(workspacePath: String) {
        // 1. Cursor: <workspace>/.cursor/mcp.json
        let cursorDir = (workspacePath as NSString).appendingPathComponent(".cursor")
        try? FileManager.default.createDirectory(atPath: cursorDir, withIntermediateDirectories: true)
        let cursorMcp = """
        {
          "mcpServers": {
            "codebase-memory": {
              "command": "codebase-memory-mcp",
              "args": []
            }
          }
        }
        """
        try? cursorMcp.write(toFile: (cursorDir as NSString).appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
        
        // 2. OpenCode: <workspace>/.opencode/mcp.json
        let opencodeDir = (workspacePath as NSString).appendingPathComponent(".opencode")
        try? FileManager.default.createDirectory(atPath: opencodeDir, withIntermediateDirectories: true)
        let opencodeMcp = """
        {
          "mcpServers": {
            "codebase-memory": {
              "command": "codebase-memory-mcp"
            }
          }
        }
        """
        try? opencodeMcp.write(toFile: (opencodeDir as NSString).appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
    }
    
    // MARK: - Teardown
    public func pruneWorkspace(name: String, force: Bool = false) throws {
        let wsRoot = (config.rootDirectory as NSString).expandingTildeInPath
        let wsPath = (wsRoot as NSString).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: wsPath) else {
            throw NSError(domain: "ws", code: 6, userInfo: [NSLocalizedDescriptionKey: "Workspace not found at \(wsPath)"])
        }
        
        // Safety check uncommitted changes
        if !force {
            if let subEntries = try? FileManager.default.contentsOfDirectory(atPath: wsPath) {
                for sub in subEntries {
                    let subPath = (wsPath as NSString).appendingPathComponent(sub)
                    if FileManager.default.fileExists(atPath: (subPath as NSString).appendingPathComponent(".git")) {
                        let statusRes = ProcessRunner.run("git status --porcelain", currentDirectory: subPath)
                        if !statusRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            throw NSError(domain: "ws", code: 7, userInfo: [NSLocalizedDescriptionKey: "Repo '\(sub)' has uncommitted changes. Use force to prune."])
                        }
                    }
                }
            }
        }
        
        // Remove worktrees properly
        if let subEntries = try? FileManager.default.contentsOfDirectory(atPath: wsPath) {
            for sub in subEntries {
                let subPath = (wsPath as NSString).appendingPathComponent(sub)
                if FileManager.default.fileExists(atPath: (subPath as NSString).appendingPathComponent(".git")) {
                    _ = ProcessRunner.run("git worktree remove --force \"\(subPath)\"", currentDirectory: subPath)
                }
            }
        }
        
        // Delete directory
        try FileManager.default.removeItem(atPath: wsPath)
    }
}
