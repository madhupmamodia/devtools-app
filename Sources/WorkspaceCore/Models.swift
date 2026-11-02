import Foundation

public struct DoctorItem: Codable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let required: Bool
    public let installed: Bool
    public let version: String?
    public let details: String?
    public let installCommand: String?
    /// "tool" for hard dependencies, "agent" for optional AI agents the user picks.
    public let category: String
    
    public init(name: String, required: Bool, installed: Bool, version: String? = nil, details: String? = nil, installCommand: String? = nil, category: String = "tool") {
        self.name = name
        self.required = required
        self.installed = installed
        self.version = version
        self.details = details
        self.installCommand = installCommand
        self.category = category
    }
}

public struct RepoDefinition: Codable, Identifiable {
    public var id: String { name }
    public let name: String
    public let cloneUrl: String
    public let defaultBranch: String
    
    public init(name: String, cloneUrl: String, defaultBranch: String = "main") {
        self.name = name
        self.cloneUrl = cloneUrl
        self.defaultBranch = defaultBranch
    }
}

public struct WorkspaceInfo: Codable, Identifiable {
    public var id: String { name }
    public let name: String
    public let path: String
    public let repos: [String]
    public let branches: [String: String]
    public let dirtyCounts: [String: Int]
    public let hasMcpIndex: Bool
    public let isStale: Bool
    public let lastModified: Date
    
    public init(name: String, path: String, repos: [String], branches: [String: String], dirtyCounts: [String: Int], hasMcpIndex: Bool, isStale: Bool, lastModified: Date) {
        self.name = name
        self.path = path
        self.repos = repos
        self.branches = branches
        self.dirtyCounts = dirtyCounts
        self.hasMcpIndex = hasMcpIndex
        self.isStale = isStale
        self.lastModified = lastModified
    }
}

public struct WSConfig: Codable {
    public var rootDirectory: String
    public var cacheDirectory: String
    public var repos: [RepoDefinition]
    public var defaultOrg: String
    
    public init(
        rootDirectory: String = ("~/workspaces" as NSString).expandingTildeInPath,
        cacheDirectory: String = ("~/.cache/ws/repos" as NSString).expandingTildeInPath,
        repos: [RepoDefinition] = [],
        defaultOrg: String = "Multiplier-Core"
    ) {
        self.rootDirectory = rootDirectory
        self.cacheDirectory = cacheDirectory
        self.repos = repos
        self.defaultOrg = defaultOrg
    }
}

public enum ProcessRunner {
    /// Node major version the app prefers when several are installed via nvm.
    /// ponytail: one constant, not a settings screen. Bump it when the team moves on.
    public static let preferredNodeMajor = 22
    
    /// Every nvm-installed node bin dir, best first: preferred major version (highest
    /// patch) first, then the rest newest-first.
    ///
    /// GUI apps never source .zshrc, so nvm is not initialised and `node` / npm globals
    /// are invisible. That is why the Doctor reported node and codebase-memory-mcp as
    /// missing even though both are installed. Keep the other majors on PATH as a
    /// fallback so globals installed under a different version stay reachable.
    public static func nvmBinPaths() -> [String] {
        let versionsDir = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".nvm/versions/node")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: versionsDir) else {
            return []
        }
        
        struct V { let major: Int; let minor: Int; let patch: Int; let dir: String }
        let parsed: [V] = entries.compactMap { name in
            guard name.hasPrefix("v") else { return nil }
            let parts = name.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 3,
                  let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2])
            else { return nil }
            let bin = (versionsDir as NSString).appendingPathComponent("\(name)/bin")
            guard FileManager.default.fileExists(atPath: bin) else { return nil }
            return V(major: major, minor: minor, patch: patch, dir: bin)
        }
        
        let preferred = parsed.filter { $0.major == preferredNodeMajor }
            .sorted { ($0.minor, $0.patch) > ($1.minor, $1.patch) }
        let others = parsed.filter { $0.major != preferredNodeMajor }
            .sorted { ($0.major, $0.minor, $0.patch) > ($1.major, $1.minor, $1.patch) }
        return (preferred + others).map { $0.dir }
    }
    
    /// Well-known directories where AI agent CLIs install themselves. GUI apps do not
    /// source .zshrc, so these are invisible to the app unless added explicitly.
    /// Filtered to dirs that exist so new joiners do not get phantom PATH entries.
    public static func agentBinPaths() -> [String] {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.opencode/bin",
            "\(home)/.local/bin",
            "\(home)/.claude/local",
            "\(home)/.claude/bin",
            "\(home)/.codex/bin",
            "\(home)/.gemini/bin",
            "\(home)/.aider/bin",
            "\(home)/.antigravity/bin",
            "\(home)/.factory/bin"
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0) }
    }
    
    // ponytail: login shell (-l) costs 200-400ms per spawn loading zprofile. PATH is
    // injected explicitly below, so skip it. Add -l back if a command needs user profile env.
    private static let enrichedPath: String = {
        var paths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin"]
        paths.append(contentsOf: agentBinPaths())
        paths.append(contentsOf: nvmBinPaths())
        let base = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return (paths + base.components(separatedBy: ":")).joined(separator: ":")
    }()
    
    public static func run(_ command: String, currentDirectory: String? = nil, timeout: TimeInterval? = nil) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = enrichedPath
        process.environment = env
        
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        
        // Drain both pipes on background queues BEFORE waiting. Calling waitUntilExit()
        // first deadlocks on any command that writes more than the 64KB pipe buffer:
        // the child blocks on write, never exits. ponytail: don't "optimize" this back.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "ws.proc", attributes: .concurrent)
        
        queue.async(group: group) {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        }
        queue.async(group: group) {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        }
        
        do {
            try process.run()
            // ponytail: network probes can hang forever without this. Kill the child
            // and return what we got so far rather than freezing the UI thread.
            if let timeout {
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline {
                    usleep(50_000)
                }
                if process.isRunning {
                    process.terminate()
                    usleep(200_000)
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            process.waitUntilExit()
            // Drains finish once the child closed its pipes (i.e. after exit). Must come
            // AFTER the kill logic or a hung child blocks here forever, defeating timeout.
            group.wait()
            let stdout = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus, stdout, stderr)
        } catch {
            return (-1, "", error.localizedDescription)
        }
    }
}
