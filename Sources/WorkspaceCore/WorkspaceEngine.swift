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
        return try? CacheCoders.decoder().decode(RepoUsage.self, from: data)
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
        if let data = try? CacheCoders.encoder().encode(usage) {
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
    
    /// Cached Doctor result. The tab paints instantly with the last known state and
    /// refreshes in the background, instead of showing a spinner for seconds.
    public struct DoctorSnapshot: Codable {
        public var items: [DoctorItem]
        public var checkedAt: Date
    }
    
    /// Runs every probe at once and returns the items in a stable order.
    /// ponytail: sequential probes cost 4.4s (16 processes, two of them network).
    /// Concurrent, the wall time is the slowest single probe.
    private func runDoctorChecks(_ checks: [() -> DoctorItem]) -> [DoctorItem] {
        final class Slot: @unchecked Sendable { var item: DoctorItem? }
        let slots = checks.map { _ in Slot() }
        let group = DispatchGroup()
        for (i, check) in checks.enumerated() {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                slots[i].item = check()
            }
        }
        group.wait()
        return slots.compactMap { $0.item }
    }
    
    public func checkDoctor() -> [DoctorItem] {
        // Resolve binaries once. `which` walks the PATH on disk — no process spawn.
        let gitPath = ProcessRunner.which("git")
        let ghPath = ProcessRunner.which("gh")
        let nodePath = ProcessRunner.which("node")
        let pythonPath = ProcessRunner.which("python3")
        let cbmPath = ProcessRunner.which("codebase-memory-mcp")
        let wsPath = ProcessRunner.which("ws")
        let opencodePath = ProcessRunner.which("opencode")
        let claudePath = ProcessRunner.which("claude")
        let codexPath = ProcessRunner.which("codex")
        
        func version(of path: String?, args: [String]) -> String? {
            guard let path else { return nil }
            let res = ProcessRunner.exec(path, args)
            guard res.exitCode == 0 else { return nil }
            return res.stdout.components(separatedBy: "\n").last
        }
        
        func firstLine(of path: String?, args: [String]) -> String? {
            guard let path else { return nil }
            let res = ProcessRunner.exec(path, args)
            guard res.exitCode == 0 else { return nil }
            return res.stdout.components(separatedBy: "\n").first
        }
        
        var checks: [() -> DoctorItem] = []
        
        // 1. Git
        checks.append {
            DoctorItem(
                name: "git",
                required: true,
                installed: gitPath != nil,
                version: version(of: gitPath, args: ["--version"]),
                details: gitPath,
                installCommand: "brew install git"
            )
        }
        
        // 2. GitHub CLI & auth. `gh auth token` reads local config; `gh auth status`
        // contacts the API and costs 600ms.
        checks.append {
            let authed = ghPath.map { ProcessRunner.exec($0, ["auth", "token"]).exitCode == 0 } ?? false
            return DoctorItem(
                name: "gh (GitHub CLI)",
                required: true,
                installed: ghPath != nil,
                version: version(of: ghPath, args: ["--version"]),
                details: authed ? "Authenticated" : "Not authenticated (run 'gh auth login')",
                installCommand: "brew install gh && gh auth login"
            )
        }
        
        // 3. Git clone transport. HTTPS first: it is the transport we actually use,
        // and it works without a key. SSH is only probed when HTTPS fails, which
        // saves a network round trip on every check.
        checks.append {
            let probeRepo = self.config.repos.first?.name ?? ""
            guard !probeRepo.isEmpty, let gitPath else {
                return DoctorItem(name: "Git clone auth", required: true, installed: false, installCommand: "gh auth setup-git")
            }
            let remote = "\(self.config.defaultOrg)/\(probeRepo)"
            let https = ProcessRunner.exec(gitPath, ["ls-remote", "https://github.com/\(remote).git", "HEAD"], timeout: 20)
            if https.exitCode == 0 {
                return DoctorItem(
                    name: "Git clone auth",
                    required: true,
                    installed: true,
                    details: "HTTPS + gh token"
                )
            }
            // HTTPS failed — check whether SSH can pick up the slack.
            // core.sshCommand instead of GIT_SSH_COMMAND: setting a per-spawn
            // environment is not thread-safe (see ProcessRunner).
            let ssh = ProcessRunner.exec(
                gitPath,
                ["-c", "core.sshCommand=ssh -o BatchMode=yes", "ls-remote", "git@github.com:\(remote).git", "HEAD"],
                timeout: 20
            )
            return DoctorItem(
                name: "Git clone auth",
                required: true,
                installed: ssh.exitCode == 0,
                details: ssh.exitCode == 0 ? "SSH key works" : "No working transport",
                installCommand: ssh.exitCode == 0 ? nil : "gh auth setup-git"
            )
        }
        
        // 4. Node.js
        checks.append {
            DoctorItem(
                name: "node",
                required: true,
                installed: nodePath != nil,
                version: version(of: nodePath, args: ["-v"]),
                details: nodePath,
                installCommand: "brew install node"
            )
        }
        
        // 5. Python 3
        checks.append {
            DoctorItem(
                name: "python3",
                required: true,
                installed: pythonPath != nil,
                version: version(of: pythonPath, args: ["--version"]),
                details: pythonPath,
                installCommand: "brew install python3"
            )
        }
        
        // 6. codebase-memory-mcp
        checks.append {
            DoctorItem(
                name: "codebase-memory-mcp",
                required: true,
                installed: cbmPath != nil,
                version: version(of: cbmPath, args: ["--version"]),
                details: cbmPath != nil ? "Ready for AST indexing" : "Required for AI agent cross-repo graph",
                installCommand: "npm install -g codebase-memory-mcp"
            )
        }
        
        // 7. Terminals. iTerm2 preferred when present; plain Terminal always exists.
        checks.append {
            let hasITerm = FileManager.default.fileExists(atPath: "/Applications/iTerm.app")
            return DoctorItem(
                name: "iTerm2",
                required: false,
                installed: hasITerm,
                details: hasITerm ? "Preferred terminal for 'Open in'" : "Not installed — falling back to Terminal.app",
                installCommand: "brew install --cask iterm2"
            )
        }
        
        // 8. Our own CLI. Self-check that the bundle's ws binary is still linked on PATH;
        // reinstalling or cleaning PATH breaks it silently.
        checks.append {
            DoctorItem(
                name: "ws CLI",
                required: true,
                installed: wsPath != nil,
                version: firstLine(of: wsPath, args: ["--help"]),
                details: wsPath != nil
                    ? "Workspace orchestrator available in Terminal"
                    : (self.bundledWSPath.map { "Bundled at \($0)" } ?? "Not linked on PATH"),
                installCommand: self.bundledWSPath.map { src in
                    "mkdir -p \"$HOME/.local/bin\" && cp \"\(src)\" \"$HOME/.local/bin/ws\" && chmod +x \"$HOME/.local/bin/ws\""
                }
            )
        }
        
        // 9. Coding agents (optional — user installs only what they want).
        // ponytail: macOS filesystem is case-insensitive, so /Applications/OpenCode.app
        // and /Applications/opencode.app are the same app. Only check one.
        let agentChecks: [(String, String?, [String], String?, String)] = [
            ("OpenCode", opencodePath, ["--version"], "npm install -g opencode-ai", "CLI agent (TUI)"),
            ("OpenCode Desktop", nil, [], "brew install --cask opencode", "Desktop app"),
            ("Claude Code", claudePath, ["--version"], "npm install -g @anthropic-ai/claude-code", "CLI agent"),
            ("Codex", codexPath, ["--version"], "npm install -g @openai/codex", "CLI agent")
        ]
        for (name, path, args, installCmd, note) in agentChecks {
            checks.append {
                // Desktop apps are a filesystem check, not a process spawn.
                if name == "OpenCode Desktop" {
                    let hasApp = FileManager.default.fileExists(atPath: "/Applications/OpenCode.app")
                    return DoctorItem(
                        name: name, required: false, installed: hasApp,
                        details: hasApp ? note : "Not installed", installCommand: installCmd, category: "agent"
                    )
                }
                let ver = version(of: path, args: args)
                return DoctorItem(
                    name: name, required: false, installed: path != nil,
                    version: ver, details: note, installCommand: installCmd, category: "agent"
                )
            }
        }
        // Cursor is a desktop app too.
        checks.append {
            let hasCursor = FileManager.default.fileExists(atPath: "/Applications/Cursor.app")
            return DoctorItem(
                name: "Cursor",
                required: false,
                installed: hasCursor,
                details: hasCursor ? "Desktop editor" : "Not installed",
                installCommand: "brew install --cask cursor",
                category: "agent"
            )
        }
        
        return runDoctorChecks(checks)
    }
    
    // MARK: - Doctor cache
    
    private var doctorSnapshotURL: URL {
        // Keep it beside the rest of the ws state.
        let configDir = (NSHomeDirectory() as NSString).appendingPathComponent(".config/ws")
        return URL(fileURLWithPath: (configDir as NSString).appendingPathComponent("doctor.json"))
    }
    
    public func loadDoctorSnapshot() -> DoctorSnapshot? {
        guard let data = try? Data(contentsOf: doctorSnapshotURL) else { return nil }
        return try? CacheCoders.decoder().decode(DoctorSnapshot.self, from: data)
    }
    
    public func saveDoctorSnapshot(items: [DoctorItem]) {
        guard let data = try? CacheCoders.encoder().encode(DoctorSnapshot(items: items, checkedAt: Date())) else { return }
        try? FileManager.default.createDirectory(
            atPath: (doctorSnapshotURL.deletingLastPathComponent().path),
            withIntermediateDirectories: true
        )
        try? data.write(to: doctorSnapshotURL)
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
            
            let gitRepos = subEntries.filter { sub in
                FileManager.default.fileExists(atPath: (wsPath as NSString).appendingPathComponent("\(sub)/.git"))
            }
            repos = gitRepos
            
            // One git call per repo instead of three, and all repos in parallel.
            // `git status --porcelain -b` prints "## <branch>" as the first line and
            // one line per dirty path after it, so branch and dirty count come from a
            // single invocation. The old code paid three process spawns per repo.
            let repoPaths = gitRepos.map { (wsPath as NSString).appendingPathComponent($0) }
            let statuses = ProcessRunner.runConcurrent(repoPaths.map { path in
                "git status --porcelain -b"
            }, currentDirectories: repoPaths)
            
            for (idx, sub) in gitRepos.enumerated() {
                let out = idx < statuses.count ? statuses[idx] : ""
                var lines = out.split(separator: "\n").map(String.init)
                
                // First line: "## branch...tracking [ahead 1]"
                if let header = lines.first, header.hasPrefix("## ") {
                    let branch = header.dropFirst(3)
                        .components(separatedBy: "...").first ?? ""
                        .trimmingCharacters(in: .whitespaces)
                    branches[sub] = branch.isEmpty ? "HEAD" : branch
                    lines.removeFirst()
                } else {
                    branches[sub] = "HEAD"
                }
                
                dirtyCounts[sub] = lines.filter { !$0.isEmpty }.count
                
                // Staleness from filesystem mtime. The old code ran `git log -1` for
                // this, which is another process spawn per repo for a badge.
                let mod = (try? FileManager.default.attributesOfItem(atPath: repoPaths[idx])[.modificationDate] as? Date) ?? now
                if mod > maxModDate { maxModDate = mod }
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
    
    // MARK: - Naming
    
    /// Max characters of the hyphenated name part, excluding the ticket prefix.
    public static let maxNameLength = 50
    
    /// Turns free text into a lowercase hyphenated slug, capped at maxNameLength.
    /// "Credit Note Application" -> "credit-note-application"
    public static func normalizeName(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var slug = ""
        var lastWasHyphen = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                slug.append(ch)
                lastWasHyphen = false
            } else if !lastWasHyphen && !slug.isEmpty {
                slug.append("-")
                lastWasHyphen = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > Self.maxNameLength {
            slug = String(slug.prefix(Self.maxNameLength))
            // Cut at a word boundary so we do not end mid-word.
            if let lastHyphen = slug.lastIndex(of: "-") {
                slug = String(slug[...lastHyphen])
            }
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return slug
    }
    
    /// Directory name for a workspace: <TICKET>-<name>.
    public static func workspaceDirName(ticket: String, name: String) -> String {
        "\(ticket)-\(name)"
    }
    
    /// Recovers the ticket from a workspace directory name, for workspaces created
    /// before names existed. Matches a leading ALPHA-DIGITS token.
    static func ticketFromDirName(_ dirName: String) -> String {
        let pattern = "^([A-Za-z]+-[0-9]+)"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: dirName, range: NSRange(dirName.startIndex..., in: dirName)),
           let range = Range(match.range(at: 1), in: dirName) {
            return String(dirName[range]).uppercased()
        }
        return dirName
    }
    
    private func metaURL(wsPath: String) -> URL {
        URL(fileURLWithPath: (wsPath as NSString).appendingPathComponent(".ws.json"))
    }
    
    public func readMeta(wsPath: String) -> WorkspaceMeta? {
        guard let data = try? Data(contentsOf: metaURL(wsPath: wsPath)) else { return nil }
        return try? CacheCoders.decoder().decode(WorkspaceMeta.self, from: data)
    }
    
    private func writeMeta(ticket: String, name: String, wsPath: String) {
        if let data = try? CacheCoders.encoder().encode(WorkspaceMeta(ticket: ticket, name: name)) {
            try? data.write(to: metaURL(wsPath: wsPath))
        }
    }
    
    /// Ticket for a workspace: from .ws.json when present, else derived from the
    /// directory name. Used for branch naming so it stays stable either way.
    public func resolveTicket(workspaceName: String) -> String {
        let wsRoot = (config.rootDirectory as NSString).expandingTildeInPath
        let wsPath = (wsRoot as NSString).appendingPathComponent(workspaceName)
        if let meta = readMeta(wsPath: wsPath) { return meta.ticket }
        return Self.ticketFromDirName(workspaceName)
    }
    
    // MARK: - Provisioning

/// Structured progress so the UI can render a live card instead of parsing log lines.
    public enum ProvisionEvent: Sendable {
        public enum RepoPhase: String, Sendable {
            case waiting = "Waiting"
            case mirror = "Fetching mirror"
            case worktree = "Adding worktree"
            case indexed = "Ready"
            case skipped = "Skipped"
        }
        case repoStarted(String)
        case repoPhase(String, RepoPhase)
        /// Repo could not be provisioned (e.g. an empty repo with no commits).
        case repoSkipped(String, String)
        case indexing
        case complete
    }
    
    public func createWorkspace(
        ticket: String,
        name: String,
        selectedRepoNames: [String],
        onProgress: @escaping (ProvisionEvent) -> Void
    ) throws -> String {
        let cleanTicket = ticket.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanTicket.isEmpty else {
            throw NSError(domain: "ws", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ticket name cannot be empty."])
        }
        let cleanName = Self.normalizeName(name)
        guard !cleanName.isEmpty else {
            throw NSError(domain: "ws", code: 10, userInfo: [NSLocalizedDescriptionKey: "Workspace name cannot be empty."])
        }
        
        let wsRoot = (config.rootDirectory as NSString).expandingTildeInPath
        let cacheRoot = (config.cacheDirectory as NSString).expandingTildeInPath
        let wsDirName = Self.workspaceDirName(ticket: cleanTicket, name: cleanName)
        let wsPath = (wsRoot as NSString).appendingPathComponent(wsDirName)
        
        try FileManager.default.createDirectory(atPath: wsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: cacheRoot, withIntermediateDirectories: true)
        
        if FileManager.default.fileExists(atPath: wsPath) {
            throw NSError(domain: "ws", code: 2, userInfo: [NSLocalizedDescriptionKey: "Workspace \(wsDirName) already exists at \(wsPath)"])
        }
        
        try FileManager.default.createDirectory(atPath: wsPath, withIntermediateDirectories: true)
        writeMeta(ticket: cleanTicket, name: cleanName, wsPath: wsPath)
        
        let repoDefs = config.repos.filter { selectedRepoNames.contains($0.name) }
        guard !repoDefs.isEmpty else {
            throw NSError(domain: "ws", code: 3, userInfo: [NSLocalizedDescriptionKey: "No valid repositories selected."])
        }
        
        var provisioned: [String] = []
        var skipped: [(String, String)] = []
        for repo in repoDefs {
            onProgress(.repoStarted(repo.name))
            let ok = try provision(repo: repo, ticket: cleanTicket, into: wsPath, onProgress: onProgress)
            if ok { provisioned.append(repo.name) } else { skipped.append((repo.name, "empty repository")) }
        }
        if provisioned.isEmpty {
            throw NSError(domain: "ws", code: 11, userInfo: [NSLocalizedDescriptionKey: "None of the selected repositories could be provisioned. They may all be empty."])
        }
        
        writeContextFile(ticket: wsDirName, repos: provisioned, wsPath: wsPath)
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
            let ok = try provision(repo: repo, ticket: resolveTicket(workspaceName: workspaceName), into: wsPath, onProgress: onProgress)
            if ok { added.append(repo.name) }
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
    /// Provisions one repo. Returns false when the repo cannot be worked on
    /// (empty repo with no commits), which is skipped rather than failing the
    /// whole workspace — the catalog contains a few of those.
    @discardableResult
    private func provision(
        repo: RepoDefinition,
        ticket: String,
        into wsPath: String,
        onProgress: (ProvisionEvent) -> Void
    ) throws -> Bool {
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
        // Git's untracked cache makes `git status` ~5x faster on repos with many
        // files (it reuses cached directory listings instead of re-walking).
        // Measured: 100ms -> 20ms per call on a 6,300-file repo.
        _ = ProcessRunner.run("git --git-dir=\"\(barePath)\" config core.untrackedCache true")
        _ = ProcessRunner.run("git --git-dir=\"\(barePath)\" update-index --untracked-cache")
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
        
        // `git branch --list` prefixes the current branch with "* " and any branch
        // checked out in another worktree with "+ ". Strip those markers, and treat a
        // "+ " branch as unusable (git will refuse to add it twice).
        var candidates: [String] = []
        var checkedOutElsewhere: Set<String> = []
        for line in existing.stdout.split(separator: "\n") {
            var name = line.trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("+ ") {
                name.removeFirst(2)
                checkedOutElsewhere.insert(name)
            } else if name.hasPrefix("* ") {
                name.removeFirst(2)
            }
            if !name.isEmpty { candidates.append(name) }
        }
        
        var addCommand = ""
        
        if let matched = candidates.first {
            // Reuse an existing branch (exact ticket name wins over prefix matches).
            let chosen = candidates.first { $0 == ticket } ?? matched
            if checkedOutElsewhere.contains(chosen) {
                onProgress(.repoSkipped(repo.name, "branch '\(chosen)' is checked out in another worktree"))
                return false
            }
            addCommand = "git --git-dir=\"\(barePath)\" worktree add \"\(targetRepoPath)\" \"\(chosen)\""
        } else {
            // Brand new branch off the repo's default branch.
            let base = repo.defaultBranch
            let baseCheck = ProcessRunner.run("git --git-dir=\"\(barePath)\" rev-parse --verify --quiet \"\(base)\"")
            if baseCheck.exitCode == 0 {
                addCommand = "git --git-dir=\"\(barePath)\" worktree add -b \"\(ticket)\" \"\(targetRepoPath)\" \"\(base)\""
            } else {
                // No default branch. Fall back to HEAD only if the repo has commits.
                let headCheck = ProcessRunner.run("git --git-dir=\"\(barePath)\" rev-parse --verify --quiet HEAD")
                if headCheck.exitCode != 0 {
                    onProgress(.repoSkipped(repo.name, "empty repository, no commits"))
                    return false
                }
                addCommand = "git --git-dir=\"\(barePath)\" worktree add -b \"\(ticket)\" \"\(targetRepoPath)\" HEAD"
            }
        }
        

        let wtRes = ProcessRunner.run(addCommand, timeout: 180)
        if wtRes.exitCode != 0 {
            throw NSError(domain: "ws", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed worktree for \(repo.name): \(wtRes.stderr)"])
        }
        
        installGitHook(at: targetRepoPath)
        onProgress(.repoPhase(repo.name, .indexed))
        return true
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
    
    /// Absolute path to the codebase-memory-mcp entrypoint, plus the node binary
    /// that runs it.
    ///
    /// Desktop apps (opencode, Cursor) are launched by launchd and inherit a minimal
    /// PATH of /usr/bin:/bin:/usr/sbin:/sbin. nvm installs are not on it, so a bare
    /// "codebase-memory-mcp" fails with "command not found" and even an absolute
    /// path to the script fails because its shebang is #!/usr/bin/env node.
    /// Resolving both paths up front removes the dependency on PATH entirely.
    private func codebaseMemoryPaths() -> (command: [String], env: [String: String])? {
        let searchDirs = ProcessRunner.nvmBinPaths()
        var nodePath: String?
        var scriptPath: String?
        
        for dir in searchDirs {
            let node = (dir as NSString).appendingPathComponent("node")
            if nodePath == nil, FileManager.default.isExecutableFile(atPath: node) {
                nodePath = node
            }
            let script = (dir as NSString).appendingPathComponent("../lib/node_modules/codebase-memory-mcp/bin.js")
            let resolved = (script as NSString).standardizingPath
            if scriptPath == nil, FileManager.default.fileExists(atPath: resolved) {
                scriptPath = resolved
            }
        }
        
        // Fall back to whatever is on PATH (homebrew, npm global elsewhere).
        if nodePath == nil {
            let res = ProcessRunner.run("which node")
            if res.exitCode == 0 { nodePath = res.stdout }
        }
        if scriptPath == nil {
            let res = ProcessRunner.run("which codebase-memory-mcp")
            if res.exitCode == 0 { scriptPath = res.stdout }
        }
        
        guard let nodePath, let scriptPath else { return nil }
        
        var env: [String: String] = [:]
        if !searchDirs.isEmpty {
            env["PATH"] = (searchDirs + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        }
        return (command: [nodePath, scriptPath], env: env)
    }
    
    /// Writes the codebase-memory MCP server config for each agent.
    ///
    /// Built with JSONSerialization, not string templates. A hand-built template
    /// silently produced invalid JSON (missing comma, trailing comma) that these
    /// agents could not parse.
    private func registerMcpClients(workspacePath: String) {
        guard let paths = codebaseMemoryPaths() else { return }
        
        // A trimmed PATH: the preferred node plus system and homebrew. The full nvm
        // list is noisy and picks up versions the engineer did not ask for.
        let nodeDir = (paths.command[0] as NSString).deletingLastPathComponent
        let pathValue = ([nodeDir, "/opt/homebrew/bin", "/usr/local/bin",
                          "/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        
        func writeJSON(_ object: Any, to path: String) {
            guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                  let out = String(data: data, encoding: .utf8) else { return }
            try? out.write(toFile: path, atomically: true, encoding: .utf8)
        }
        
        let env = ["PATH": pathValue]
        
        // 1. OpenCode: <workspace>/opencode.json
        //    OpenCode merges project-level opencode.json over the global one and reads
        //    MCP servers from the "mcp" key. A .opencode/mcp.json file is NOT read.
        writeJSON([
            "$schema": "https://opencode.ai/config.json",
            "mcp": [
                "codebase-memory": [
                    "type": "local",
                    "command": paths.command,
                    "environment": env,
                    "enabled": true
                ]
            ]
        ], to: (workspacePath as NSString).appendingPathComponent("opencode.json"))
        
        // 2. Cursor: <workspace>/.cursor/mcp.json — uses the "mcpServers" key.
        let cursorDir = (workspacePath as NSString).appendingPathComponent(".cursor")
        try? FileManager.default.createDirectory(atPath: cursorDir, withIntermediateDirectories: true)
        writeJSON([
            "mcpServers": [
                "codebase-memory": [
                    "command": paths.command[0],
                    "args": [paths.command[1]],
                    "environment": env
                ]
            ]
        ], to: (cursorDir as NSString).appendingPathComponent("mcp.json"))
        
        // 3. Claude Code: <workspace>/.mcp.json — project-scoped MCP servers.
        writeJSON([
            "mcpServers": [
                "codebase-memory": [
                    "type": "stdio",
                    "command": paths.command[0],
                    "args": [paths.command[1]],
                    "environment": env
                ]
            ]
        ], to: (workspacePath as NSString).appendingPathComponent(".mcp.json"))
        
        // Remove the old file. It used the "mcpServers" key in a location OpenCode
        // never reads, so it was silently ignored.
        try? FileManager.default.removeItem(atPath: (workspacePath as NSString).appendingPathComponent(".opencode/mcp.json"))
    }
    
    // MARK: - Working Tree Actions
    
    public struct DirtyFile: Identifiable {
        public var id: String { path }
        /// Two-character porcelain status, e.g. " M", "??", "A ".
        public let status: String
        public let path: String
        
        public var label: String {
            switch status.trimmingCharacters(in: .whitespaces).prefix(1) {
            case "?": return "new"
            case "M": return "modified"
            case "A": return "added"
            case "D": return "deleted"
            case "R": return "renamed"
            default: return status.trimmingCharacters(in: .whitespaces)
            }
        }
    }
    
    /// Files with uncommitted changes in a worktree. Fetched on demand, not during
    /// the list scan, so the scan stays cheap.
    public func dirtyFiles(inWorkspace workspaceName: String, repo: String) -> [DirtyFile] {
        let wsRoot = (config.rootDirectory as NSString).expandingTildeInPath
        let repoPath = ((wsRoot as NSString)
            .appendingPathComponent(workspaceName) as NSString)
            .appendingPathComponent(repo)
        guard FileManager.default.fileExists(atPath: repoPath) else { return [] }
        
        let res = ProcessRunner.run("git status --porcelain", currentDirectory: repoPath)
        guard res.exitCode == 0 else { return [] }
        
        return res.stdout.split(separator: "\n").compactMap { line in
            let raw = String(line)
            guard raw.count > 3 else { return nil }
            let status = String(raw.prefix(2))
            let path = String(raw.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return nil }
            return DirtyFile(status: status, path: path)
        }
    }
    
    /// Commits everything in a worktree. Message defaults to the ticket so the
    /// history is traceable back to the workspace.
    @discardableResult
    public func commitAll(inWorkspace workspaceName: String, repo: String, message: String) throws -> String {
        let wsRoot = (config.rootDirectory as NSString).expandingTildeInPath
        let repoPath = ((wsRoot as NSString)
            .appendingPathComponent(workspaceName) as NSString)
            .appendingPathComponent(repo)
        guard FileManager.default.fileExists(atPath: repoPath) else {
            throw NSError(domain: "ws", code: 12, userInfo: [NSLocalizedDescriptionKey: "Repo not found: \(repo)"])
        }
        
        let add = ProcessRunner.run("git add -A", currentDirectory: repoPath)
        guard add.exitCode == 0 else {
            throw NSError(domain: "ws", code: 13, userInfo: [NSLocalizedDescriptionKey: "git add failed: \(add.stderr)"])
        }
        
        let commit = ProcessRunner.run("git commit -m \"\(shellQuote(message))\"", currentDirectory: repoPath)
        guard commit.exitCode == 0 else {
            throw NSError(domain: "ws", code: 14, userInfo: [NSLocalizedDescriptionKey: "git commit failed: \(commit.stderr)"])
        }
        return commit.stdout
    }
    
    /// Throws away uncommitted changes in a worktree. Destructive by definition.
    public func discardChanges(inWorkspace workspaceName: String, repo: String) throws {
        let wsRoot = (config.rootDirectory as NSString).expandingTildeInPath
        let repoPath = ((wsRoot as NSString)
            .appendingPathComponent(workspaceName) as NSString)
            .appendingPathComponent(repo)
        guard FileManager.default.fileExists(atPath: repoPath) else {
            throw NSError(domain: "ws", code: 12, userInfo: [NSLocalizedDescriptionKey: "Repo not found: \(repo)"])
        }
        
        // reset --hard drops tracked changes, clean -fd removes untracked files.
        let reset = ProcessRunner.run("git reset --hard", currentDirectory: repoPath)
        guard reset.exitCode == 0 else {
            throw NSError(domain: "ws", code: 15, userInfo: [NSLocalizedDescriptionKey: "git reset failed: \(reset.stderr)"])
        }
        let clean = ProcessRunner.run("git clean -fd", currentDirectory: repoPath)
        guard clean.exitCode == 0 else {
            throw NSError(domain: "ws", code: 16, userInfo: [NSLocalizedDescriptionKey: "git clean failed: \(clean.stderr)"])
        }
    }
    
    /// Single-quote for POSIX shell.
    private func shellQuote(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
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
