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
            self.config = WSConfig()
            if let data = try? JSONEncoder().encode(self.config) {
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
    
    /// Path to the ws binary shipped inside the app bundle, if we're running from one.
    /// Used as the install source when `ws` is missing from PATH.
    private var bundledWSPath: String? {
        let exe = CommandLine.arguments.first ?? ""
        let macosDir = (exe as NSString).deletingLastPathComponent   // .../Contents/MacOS
        let contents = (macosDir as NSString).deletingLastPathComponent  // .../Contents
        let candidate = (contents as NSString).appendingPathComponent("Resources/ws")
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }
    
    // MARK: - Repo Discovery
    
    private struct GHRow: Decodable {
        let name: String
        let isArchived: Bool
        let isFork: Bool
        let defaultBranchRef: DefaultBranch?
    }
    private struct DefaultBranch: Decodable { let name: String }
    
    /// Fetches every active, non-fork repo in the org via GitHub CLI.
    /// ponytail: gh repo list caps at 500; org is ~420 repos so one call is enough.
    /// Raise --limit if the org ever exceeds that.
    public func discoverRepos(org: String? = nil) -> [RepoDefinition] {
        let orgName = org ?? config.defaultOrg
        let cmd = "gh repo list \(orgName) --limit 500 --json name,isArchived,isFork,defaultBranchRef"
        let res = ProcessRunner.run(cmd)
        guard res.exitCode == 0,
              let data = res.stdout.data(using: .utf8),
              let rows = try? JSONDecoder().decode([GHRow].self, from: data)
        else { return [] }
        
        let repos = rows
            .filter { !$0.isArchived && !$0.isFork }
            .map {
                RepoDefinition(
                    name: $0.name,
                    // HTTPS + gh credential helper, not SSH. ponytail: SSH keys break
                    // silently and only surface as "Permission denied (publickey)" deep
                    // into a clone. gh's token already has repo scope for private orgs.
                    cloneUrl: "https://github.com/\(orgName)/\($0.name).git",
                    defaultBranch: $0.defaultBranchRef?.name ?? "main"
                )
            }
            .sorted { $0.name < $1.name }
        return repos
    }
    
    /// Replaces cached repo list with a fresh org scan.
    @discardableResult
    public func syncReposFromGitHub(org: String? = nil) -> Int {
        let found = discoverRepos(org: org)
        guard !found.isEmpty else { return 0 }
        config.repos = found
        saveConfig()
        return found.count
    }
    
    // MARK: - Personal Repo Usage
    
    public struct RepoUsage: Codable {
        public var login: String
        public var org: String
        public var fetchedAt: Date
        public var prCounts: [String: Int]
        public var commitCounts: [String: Int]
    }
    
    private var usageURL: URL {
        configURL.deletingLastPathComponent().appendingPathComponent("usage.json")
    }
    
    public func loadRepoUsage() -> RepoUsage? {
        guard let data = try? Data(contentsOf: usageURL) else { return nil }
        return try? JSONDecoder().decode(RepoUsage.self, from: data)
    }
    
    /// Counts PRs and commits the signed-in user authored per repo in the org.
    /// ponytail: GitHub search caps at 1000 results and each 100-item page costs ~1s,
    /// so this pages up to 10x only when total_count demands it. Cached to disk —
    /// refresh is explicit, never on launch.
    @discardableResult
    public func syncRepoUsage(org: String? = nil, sinceDays: Int = 365) -> RepoUsage? {
        let orgName = org ?? config.defaultOrg
        let loginRes = ProcessRunner.run("gh api /user --jq .login")
        guard loginRes.exitCode == 0 else { return nil }
        let login = loginRes.stdout
        
        let since = Date().addingTimeInterval(-Double(sinceDays) * 86400)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let cutoff = formatter.string(from: since)
        
        /// - Parameter repoExpr: a jq expression yielding the bare repo name per item.
///   issues: `.items[].repository_url | split("/") | .[-1]`
///     (search/items repository_url is truncated to .../repos/OWNER/REPO — no /pulls/N)
///   commits: `.items[].repository.name`
///   Endpoints and payload shapes differ — do not merge them.
func count(endpoint: String, query: String, repoExpr: String) -> [String: Int] {
            var result: [String: Int] = [:]
            
            // Head request tells us total_count so we never over-page.
            let head = ProcessRunner.run("gh api \"\(endpoint)?q=\(query)&per_page=100&page=1\" --jq '.total_count'")
            guard head.exitCode == 0, let total = Int(head.stdout) else { return result }
            let pages = max(1, min(10, Int(ceil(Double(total) / 100.0))))
            
            for p in 1...pages {
                // --jq extracts repo names server-of-the-client-side, so the pipe
                // carries ~40 bytes/line instead of the whole issue+body payload.
                let res = ProcessRunner.run("gh api \"\(endpoint)?q=\(query)&per_page=100&page=\(p)\" --jq '\(repoExpr)'")
                guard res.exitCode == 0 else { continue }
                
                for line in res.stdout.split(separator: "\n") {
                    let repo = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !repo.isEmpty else { continue }
                    result[repo, default: 0] += 1
                }
            }
            return result
        }
        
        let prs = count(endpoint: "search/issues",
                        query: "author:\(login)+type:pr+org:\(orgName)+created:>=\(cutoff)",
                        repoExpr: ".items[].repository_url | split(\"/\") | .[-1]")
        let commits = count(endpoint: "search/commits",
                            query: "author:\(login)+org:\(orgName)+author-date:>=\(cutoff)",
                            repoExpr: ".items[].repository.name")
        
        let usage = RepoUsage(
            login: login,
            org: orgName,
            fetchedAt: Date(),
            prCounts: prs,
            commitCounts: commits
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(usage) {
            try? data.write(to: usageURL)
        }
        return usage
    }
    
    /// Score used to rank "my repos". PRs weigh more than commits because a PR is a
    /// deliberate unit of delivered work; commits include noise and reverts.
    public func usageScore(for repo: String, usage: RepoUsage) -> Int {
        (usage.prCounts[repo] ?? 0) * 3 + (usage.commitCounts[repo] ?? 0)
    }
    
    // MARK: - Doctor
    public func checkDoctor() -> [DoctorItem] {
        var items: [DoctorItem] = []
        
        // 1. Git
        let gitRes = ProcessRunner.run("which git && git --version")
        items.append(DoctorItem(
            name: "git",
            required: true,
            installed: gitRes.exitCode == 0,
            version: gitRes.stdout.components(separatedBy: "\n").last,
            installCommand: "brew install git"
        ))
        
        // 2. GitHub CLI & Auth
        let ghRes = ProcessRunner.run("which gh && gh --version")
        let ghAuth = ProcessRunner.run("gh auth status")
        let ghInstalled = ghRes.exitCode == 0
        items.append(DoctorItem(
            name: "gh (GitHub CLI)",
            required: true,
            installed: ghInstalled,
            version: ghRes.stdout.components(separatedBy: "\n").first,
            details: ghAuth.exitCode == 0 ? "Authenticated" : "Not authenticated (run 'gh auth login')",
            installCommand: "brew install gh && gh auth login"
        ))
        
        // 3. Git clone auth. Verifies a real private repo is actually readable over
        // the transport we use, so broken SSH keys surface here instead of mid-clone.
        let probeRepo = config.repos.first?.name ?? ""
        if !probeRepo.isEmpty {
            let sshProbe = ProcessRunner.run("GIT_SSH_COMMAND='ssh -o BatchMode=yes' git ls-remote git@github.com:\(config.defaultOrg)/\(probeRepo).git HEAD", timeout: 20)
            let httpsProbe = ProcessRunner.run("git ls-remote https://github.com/\(config.defaultOrg)/\(probeRepo).git HEAD", timeout: 20)
            let sshOK = sshProbe.exitCode == 0
            let httpsOK = httpsProbe.exitCode == 0
            items.append(DoctorItem(
                name: "Git clone auth",
                required: true,
                installed: sshOK || httpsOK,
                version: nil,
                details: sshOK
                    ? "SSH key works"
                    : (httpsOK ? "SSH key missing; using HTTPS + gh token" : "No working transport"),
                installCommand: sshOK ? nil : "gh auth setup-git"
            ))
        }
        
        // 4. Node.js & npm
        let nodeRes = ProcessRunner.run("which node && node -v")
        items.append(DoctorItem(
            name: "node",
            required: true,
            installed: nodeRes.exitCode == 0,
            version: nodeRes.stdout.components(separatedBy: "\n").last,
            details: nodeRes.stdout.components(separatedBy: "\n").first,
            installCommand: "brew install node"
        ))
        
        // 4. Python 3
        let pyRes = ProcessRunner.run("which python3 && python3 --version")
        items.append(DoctorItem(
            name: "python3",
            required: true,
            installed: pyRes.exitCode == 0,
            version: pyRes.stdout.components(separatedBy: "\n").last,
            installCommand: "brew install python3"
        ))
        
        // 5. codebase-memory-mcp
        let cbmRes = ProcessRunner.run("which codebase-memory-mcp")
        let cbmInstalled = cbmRes.exitCode == 0
        items.append(DoctorItem(
            name: "codebase-memory-mcp",
            required: true,
            installed: cbmInstalled,
            version: cbmInstalled ? ProcessRunner.run("codebase-memory-mcp --version").stdout : nil,
            details: cbmInstalled ? "Ready for AST indexing" : "Required for AI agent cross-repo graph",
            installCommand: "npm install -g codebase-memory-mcp"
        ))
        
        // 6. Terminals. iTerm2 preferred when present; plain Terminal always exists.
        let iterm = ProcessRunner.run("test -d /Applications/iTerm.app")
        items.append(DoctorItem(
            name: "iTerm2",
            required: false,
            installed: iterm.exitCode == 0,
            version: nil,
            details: iterm.exitCode == 0 ? "Preferred terminal for 'Open in'" : "Not installed — falling back to Terminal.app",
            installCommand: "brew install --cask iterm2"
        ))
        
        // 7. Our own CLI. Self-check that the bundle's ws binary is still linked on PATH;
        // reinstalling or cleaning PATH breaks it silently.
        let wsRes = ProcessRunner.run("which ws")
        let wsFound = wsRes.exitCode == 0
        items.append(DoctorItem(
            name: "ws CLI",
            required: true,
            installed: wsFound,
            version: wsFound ? ProcessRunner.run("ws --help").stdout.components(separatedBy: "\n").first : nil,
            details: wsFound
                ? "Workspace orchestrator available in Terminal"
                : (bundledWSPath.map { "Bundled at \($0)" } ?? "Not linked on PATH"),
            installCommand: bundledWSPath.map { src in
                "mkdir -p \"$HOME/.local/bin\" && cp \"\(src)\" \"$HOME/.local/bin/ws\" && chmod +x \"$HOME/.local/bin/ws\""
            }
        ))
        
        // 6. Coding agents (optional — user installs only what they want).
        // ponytail: macOS filesystem is case-insensitive, so /Applications/OpenCode.app
        // and /Applications/opencode.app are the same app. Only check one.
        let agents: [(String, String, String?, String)] = [
            ("OpenCode", "opencode --version", "npm install -g opencode-ai", "CLI agent (TUI)"),
            ("OpenCode Desktop", "test -d /Applications/OpenCode.app", "brew install --cask opencode", "Desktop app"),
            ("Claude Code", "claude --version", "npm install -g @anthropic-ai/claude-code", "CLI agent"),
            ("Cursor", "test -d /Applications/Cursor.app", "brew install --cask cursor", "Desktop editor"),
            ("Codex", "codex --version", "npm install -g @openai/codex", "CLI agent")
        ]
        
        for (agentName, checkCmd, installCmd, note) in agents {
            let res = ProcessRunner.run(checkCmd, timeout: 15)
            let found = res.exitCode == 0
            items.append(DoctorItem(
                name: agentName,
                required: false,
                installed: found,
                version: found ? res.stdout.components(separatedBy: "\n").last : nil,
                details: found ? note : note,
                installCommand: installCmd,
                category: "agent"
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
            
            list.append(WorkspaceInfo(
                name: name,
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

/// Structured progress so the UI can render a live card instead of parsing log lines.
    public enum ProvisionEvent: Sendable {
        public enum RepoPhase: String, Sendable {
            case waiting = "Waiting"
            case mirror = "Fetching mirror"
            case worktree = "Adding worktree"
            case indexed = "Ready"
        }
        case repoStarted(String)
        case repoPhase(String, RepoPhase)
        case indexing
        case complete
    }
    
    public func createWorkspace(
        ticket: String,
        selectedRepoNames: [String],
        onProgress: @escaping (ProvisionEvent) -> Void
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
            onProgress(.repoStarted(repo.name))
            try provision(repo: repo, ticket: cleanTicket, into: wsPath, onProgress: onProgress)
        }
        
        writeContextFile(ticket: cleanTicket, repos: repoDefs.map { $0.name }, wsPath: wsPath)
        registerMcpClients(workspacePath: wsPath)
        
        onProgress(.indexing)
        _ = reindexWorkspace(workspacePath: wsPath)
        
        onProgress(.complete)
        return wsPath
    }
    
    // MARK: - Add Repos to Existing Workspace
    
    /// Adds repos to a live workspace. Same code path as creation so branch
    /// resolution, hooks and mirrors behave identically. Present repos are skipped.
    public func addRepos(
        toWorkspace workspaceName: String,
        repoNames: [String],
        onProgress: @escaping (ProvisionEvent) -> Void
    ) throws {
        let wsRoot = (config.rootDirectory as NSString).expandingTildeInPath
        let wsPath = (wsRoot as NSString).appendingPathComponent(workspaceName)
        guard FileManager.default.fileExists(atPath: wsPath) else {
            throw NSError(domain: "ws", code: 8, userInfo: [NSLocalizedDescriptionKey: "Workspace not found: \(workspaceName)"])
        }
        
        let repoDefs = config.repos.filter { repoNames.contains($0.name) }
        guard !repoDefs.isEmpty else {
            throw NSError(domain: "ws", code: 3, userInfo: [NSLocalizedDescriptionKey: "No valid repositories selected."])
        }
        
        var added: [String] = []
        for repo in repoDefs {
            let target = (wsPath as NSString).appendingPathComponent(repo.name)
            if FileManager.default.fileExists(atPath: target) {
                onProgress(.repoPhase(repo.name, .indexed))
                continue
            }
            onProgress(.repoStarted(repo.name))
            try provision(repo: repo, ticket: workspaceName, into: wsPath, onProgress: onProgress)
            added.append(repo.name)
        }
        
        guard !added.isEmpty else {
            onProgress(.complete)
            return
        }
        
        // Rewrite the context file so it lists the full current repo set.
        let present = (try? FileManager.default.contentsOfDirectory(atPath: wsPath))?
            .filter { sub in
                FileManager.default.fileExists(atPath: (wsPath as NSString).appendingPathComponent("\(sub)/.git"))
            } ?? added
        writeContextFile(ticket: workspaceName, repos: present.sorted(), wsPath: wsPath)
        registerMcpClients(workspacePath: wsPath)
        
        onProgress(.indexing)
        _ = reindexWorkspace(workspacePath: wsPath)
        onProgress(.complete)
    }
    
    // MARK: - Shared per-repo provisioning
    
    /// Mirror-sync + worktree-add + hook install for ONE repo. Shared by create and add.
    private func provision(
        repo: RepoDefinition,
        ticket: String,
        into wsPath: String,
        onProgress: (ProvisionEvent) -> Void
    ) throws {
        let cacheRoot = (config.cacheDirectory as NSString).expandingTildeInPath
        try FileManager.default.createDirectory(atPath: cacheRoot, withIntermediateDirectories: true)
        let barePath = (cacheRoot as NSString).appendingPathComponent("\(repo.name).git")
        
        if !FileManager.default.fileExists(atPath: barePath) {
            onProgress(.repoPhase(repo.name, .mirror))
            // --bare, NOT --mirror. --mirror sets remote.origin.fetch=+refs/*:refs/*, so a
            // fetch writes remote refs over local refs/heads and deletes anything the remote
            // lacks — i.e. every unpushed workspace branch.
            let cloneRes = ProcessRunner.run("git clone --bare \(repo.cloneUrl) \"\(barePath)\"")
            if cloneRes.exitCode != 0 {
                throw NSError(domain: "ws", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to mirror \(repo.name): \(cloneRes.stderr)"])
            }
        }
        
        onProgress(.repoPhase(repo.name, .mirror))
        // Harden the mirror against branch loss. Two independent things cause it and both
        // are neutralised here:
        //   1. --mirror's +refs/*:refs/* refspec, written by older versions.
        //   2. `fetch.prune=true` in the user's ~/.gitconfig, which makes EVERY git fetch
        //      prune by default. This was the actual cause: it silently deleted unpushed
        //      workspace branches on every `ws create` / `ws add`.
        // Verified: with prune active, a probe branch was deleted on fetch; with
        // -c fetch.prune=false it survives.
        _ = ProcessRunner.run("git --git-dir=\"\(barePath)\" config remote.origin.mirror false")
        _ = ProcessRunner.run("git --git-dir=\"\(barePath)\" config remote.origin.fetch '+refs/heads/*:refs/heads/*'")
        _ = ProcessRunner.run("git --git-dir=\"\(barePath)\" config fetch.prune false")
        _ = ProcessRunner.run("git -c fetch.prune=false --git-dir=\"\(barePath)\" fetch --all", timeout: 120)
        
        onProgress(.repoPhase(repo.name, .worktree))
        let targetRepoPath = (wsPath as NSString).appendingPathComponent(repo.name)
        
        // A --mirror clone stores every branch as refs/heads/*, NOT refs/remotes/origin/*.
        // ponytail: query refs/heads and branch off the local name. Using origin/* here
        // fails with "invalid reference" on every fresh workspace.
        let existing = ProcessRunner.run("git --git-dir=\"\(barePath)\" branch --list \"*\(ticket)*\"")
        let candidates = existing.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        var branchToUse = ticket
        var addCommand = ""
        
        if let matched = candidates.first {
            // Reuse an existing branch (exact ticket name wins over prefix matches).
            let chosen = candidates.first { $0 == ticket } ?? matched
            branchToUse = chosen
            addCommand = "git --git-dir=\"\(barePath)\" worktree add \"\(targetRepoPath)\" \"\(chosen)\""
        } else {
            // Brand new branch off the repo's default branch.
            let base = repo.defaultBranch
            let baseCheck = ProcessRunner.run("git --git-dir=\"\(barePath)\" rev-parse --verify --quiet \"\(base)\"")
            let startPoint = baseCheck.exitCode == 0 ? base : "HEAD"
            addCommand = "git --git-dir=\"\(barePath)\" worktree add -b \"\(ticket)\" \"\(targetRepoPath)\" \"\(startPoint)\""
        }
        

        let wtRes = ProcessRunner.run(addCommand, timeout: 180)
        if wtRes.exitCode != 0 {
            throw NSError(domain: "ws", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed worktree for \(repo.name): \(wtRes.stderr)"])
        }
        
        installGitHook(at: targetRepoPath)
        onProgress(.repoPhase(repo.name, .indexed))
    }
    
    // MARK: - Remove Repos from Workspace
    
    /// Removes repos from a live workspace.
    ///
    /// The worktree directory and its registration are removed, but the BRANCH stays in
    /// the mirror. That branch may hold unpushed commits; destroying it would throw away
    /// work the engineer cannot get back. It can always be re-added later with `ws add`.
    ///
    /// - Parameter force: required when a repo has uncommitted changes.
    public func removeRepos(
        fromWorkspace workspaceName: String,
        repoNames: [String],
        force: Bool = false
    ) throws {
        let wsRoot = (config.rootDirectory as NSString).expandingTildeInPath
        let wsPath = (wsRoot as NSString).appendingPathComponent(workspaceName)
        guard FileManager.default.fileExists(atPath: wsPath) else {
            throw NSError(domain: "ws", code: 8, userInfo: [NSLocalizedDescriptionKey: "Workspace not found: \(workspaceName)"])
        }
        
        for repo in repoNames {
            let repoPath = (wsPath as NSString).appendingPathComponent(repo)
            guard FileManager.default.fileExists(atPath: repoPath) else { continue }
            
            // Uncommitted work check — same rule as pruning a whole workspace.
            if !force {
                let status = ProcessRunner.run("git status --porcelain", currentDirectory: repoPath)
                if !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw NSError(domain: "ws", code: 9, userInfo: [
                        NSLocalizedDescriptionKey: "'\(repo)' has uncommitted changes. Commit or push them, or confirm to discard."
                    ])
                }
            }
            
            // Ask the worktree which mirror owns it so we prune the right git dir.
            let commonDir = ProcessRunner.run("git rev-parse --git-common-dir", currentDirectory: repoPath).stdout
            let mirrorGitDir = (commonDir as NSString).expandingTildeInPath
            
            _ = ProcessRunner.run("git worktree remove --force \"\(repoPath)\"", currentDirectory: repoPath)
            if !commonDir.isEmpty {
                _ = ProcessRunner.run("git --git-dir=\"\(mirrorGitDir)\" worktree prune")
            }
            // Belt and braces: the directory may survive if git refused.
            if FileManager.default.fileExists(atPath: repoPath) {
                try? FileManager.default.removeItem(atPath: repoPath)
            }
            // Note: the branch itself is intentionally left in the mirror.
        }
        
        // Rewrite the context file so it lists the remaining repos.
        let present = (try? FileManager.default.contentsOfDirectory(atPath: wsPath))?
            .filter { sub in
                FileManager.default.fileExists(atPath: (wsPath as NSString).appendingPathComponent("\(sub)/.git"))
            } ?? []
        writeContextFile(ticket: workspaceName, repos: present.sorted(), wsPath: wsPath)
        
        // Re-index so the graph drops the removed repos.
        _ = reindexWorkspace(workspacePath: wsPath)
    }
    
    private func writeContextFile(ticket: String, repos: [String], wsPath: String) {
        let contextMd = """
        # Workspace: \(ticket)
        Provisioned: \(Date())
        
        ## Repositories
        \(repos.map { "- **\($0)** (worktree)" }.joined(separator: "\n"))
        
        ## AI Agent Guidelines
        - Cross-repo symbols and definitions indexed via `codebase-memory-mcp`.
        - Use `search_graph` or `query_graph` to trace cross-service interactions.
        - Run tests and linters natively inside respective subdirectories.
        """
        try? contextMd.write(toFile: (wsPath as NSString).appendingPathComponent("workspace.md"), atomically: true, encoding: .utf8)
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
        
        // Remove worktrees properly, then clear the mirror's worktree registry. The mirror
        // is what actually stores the refs, so without this it keeps dangling entries
        // pointing at the deleted directory and `worktree add` fails next time.
        // Branches are deliberately left in the mirror: they may hold unpushed commits,
        // and removing the workspace must never destroy them.
        if let subEntries = try? FileManager.default.contentsOfDirectory(atPath: wsPath) {
            for sub in subEntries {
                let subPath = (wsPath as NSString).appendingPathComponent(sub)
                guard FileManager.default.fileExists(atPath: (subPath as NSString).appendingPathComponent(".git")) else { continue }
                // Ask the worktree which mirror owns it, then prune that mirror.
                let commonDir = ProcessRunner.run("git rev-parse --git-common-dir", currentDirectory: subPath).stdout
                _ = ProcessRunner.run("git worktree remove --force \"\(subPath)\"", currentDirectory: subPath)
                if !commonDir.isEmpty {
                    let mirrorGitDir = (commonDir as NSString).expandingTildeInPath
                    _ = ProcessRunner.run("git --git-dir=\"\(mirrorGitDir)\" worktree prune")
                }
            }
        }
        
        // Delete directory
        try FileManager.default.removeItem(atPath: wsPath)
    }
}
