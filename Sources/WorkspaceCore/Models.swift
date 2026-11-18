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
    public var dirtyCounts: [String: Int]
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

/// Written to <workspace>/.ws.json. Keeps the ticket separate from the directory
/// name so branch naming stays consistent now that workspaces carry a name.
public struct WorkspaceMeta: Codable {
    public var ticket: String
    public var name: String
    public var createdAt: Date
    
    public init(ticket: String, name: String, createdAt: Date = Date()) {
        self.ticket = ticket
        self.name = name
        self.createdAt = createdAt
    }
}

/// Shared JSON coders for the on-disk caches.
///
/// ponytail: the writer used `.iso8601` and the reader used the default (a Double
/// timestamp), so every read of usage.json failed to decode. The ranking silently
/// degraded to alphabetical with no error anywhere. One pair of coders, used by
/// both sides, makes that class of bug impossible.
public enum CacheCoders {
    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? .prettyPrinted : []
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
    
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
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
    
    /// Publishes the enriched PATH to this process, so every child inherits it.
    ///
    /// ponytail: do NOT set `Process.environment` per spawn. Foundation's
    /// implementation of an explicit environment is not thread-safe: running
    /// several spawns concurrently corrupts the child's environment (observed:
    /// "/Users/madhup" arriving as "/Usersadhup") and can hang outright.
    /// Mutating the process environment once, before any spawn, is safe and gives
    /// every child the same PATH.
    private static let environmentReady: Bool = {
        setenv("PATH", enrichedPath, 1)
        return true
    }()
    
    /// Runs several commands at once, one per working directory, concurrently.
    /// Results come back in the same order as the inputs.
    /// ponytail: spawn cost dominates for short git commands, so overlap them.
    public static func runConcurrent(
        _ commands: [String],
        currentDirectories: [String]
    ) -> [String] {
        guard !commands.isEmpty else { return [] }
        var results = [String](repeating: "", count: commands.count)
        let lock = NSLock()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "ws.proc.parallel", attributes: .concurrent)
        
        for (i, cmd) in commands.enumerated() {
            let dir = i < currentDirectories.count ? currentDirectories[i] : nil
            queue.async(group: group) {
                let out = run(cmd, currentDirectory: dir).stdout
                lock.lock()
                results[i] = out
                lock.unlock()
            }
        }
        group.wait()
        return results
    }
    
    /// Runs a command through the shell.
    public static func run(_ command: String, currentDirectory: String? = nil, timeout: TimeInterval? = nil) -> (exitCode: Int32, stdout: String, stderr: String) {
        spawn(executable: "/bin/zsh", arguments: ["-c", command], currentDirectory: currentDirectory, timeout: timeout)
    }
    
    /// Runs a binary directly — no shell, no shell startup cost.
    /// Prefer this over `run(_:)` for anything simple: a shell spawn costs ~10ms
    /// before the command even starts.
    public static func exec(_ executable: String, _ arguments: [String] = [], currentDirectory: String? = nil, timeout: TimeInterval? = nil) -> (exitCode: Int32, stdout: String, stderr: String) {
        spawn(executable: executable, arguments: arguments, currentDirectory: currentDirectory, timeout: timeout)
    }
    
    /// Finds an executable on the enriched PATH without spawning a process.
    public static func which(_ name: String) -> String? {
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        for dir in enrichedPath.components(separatedBy: ":") where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
    
    /// Core spawn.
    ///
    /// ponytail: `Process.waitUntilExit()` costs ~52ms of pure latency on macOS — it
    /// polls for the child instead of being notified. The termination handler fires
    /// in ~1ms. Every git/gh/node call was paying that tax, and the Doctor alone
    /// makes 16 of them. Measured on this machine: 68ms -> 1ms for a fast command.
    ///
    /// ponytail: output goes to a temp file, not a Pipe. Concurrent Pipe reads on
    /// Darwin are not safe — they corrupted output ("/Users/madhup" arriving as
    /// "/Usersadhup") and a burst of 60 concurrent reads was killed by the kernel.
    /// A temp file has no EOF handshake and no shared Foundation state.
    private static func spawn(
        executable: String,
        arguments: [String],
        currentDirectory: String?,
        timeout: TimeInterval?
    ) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        
        // Touch the static so PATH is published before the first spawn.
        _ = environmentReady
        
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        
        let tmpDir = NSTemporaryDirectory()
        let outURL = URL(fileURLWithPath: tmpDir).appendingPathComponent("ws-out-\(UUID().uuidString)")
        let errURL = URL(fileURLWithPath: tmpDir).appendingPathComponent("ws-err-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        
        guard let outHandle = FileHandle(forWritingAtPath: outURL.path),
              let errHandle = FileHandle(forWritingAtPath: errURL.path) else {
            return (-1, "", "Could not create output file for \(executable)")
        }
        process.standardOutput = outHandle
        process.standardError = errHandle
        
        // Fast exit notification. Foundation delivers this on a private queue, so it
        // is safe to block the calling thread waiting on the semaphore.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        
        do {
            try process.run()
            
            // ponytail: network probes can hang forever without this. Kill the child
            // and return what we got so far rather than freezing the UI thread.
            if let timeout {
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline {
                    usleep(20_000)
                }
                if process.isRunning {
                    process.terminate()
                    usleep(200_000)
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            
            // Wait for the child. The handler is the fast path. If it was missed
            // (a child that exits before Foundation registers the handler) fall back
            // to polling isRunning, and only then to waitUntilExit().
            if exited.wait(timeout: .now() + 0.05) != .success {
                while process.isRunning {
                    if exited.wait(timeout: .now() + 0.05) == .success { break }
                }
                if exited.wait(timeout: .now()) != .success {
                    process.waitUntilExit()
                }
            }
            
            try? outHandle.close()
            try? errHandle.close()
            let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
            let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(atPath: outURL.path)
            try? FileManager.default.removeItem(atPath: errURL.path)
            return (
                process.terminationStatus,
                stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            try? outHandle.close()
            try? errHandle.close()
            try? FileManager.default.removeItem(atPath: outURL.path)
            try? FileManager.default.removeItem(atPath: errURL.path)
            return (-1, "", error.localizedDescription)
        }
    }
}
