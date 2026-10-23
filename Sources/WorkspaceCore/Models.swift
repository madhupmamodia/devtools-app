import Foundation

public struct DoctorItem: Codable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let command: String
    public let required: Bool
    public let installed: Bool
    public let version: String?
    public let path: String?
    public let details: String?
    public let installCommand: String?
    /// "tool" for hard dependencies, "agent" for optional AI agents the user picks.
    public let category: String
    
    public init(name: String, command: String, required: Bool, installed: Bool, version: String? = nil, path: String? = nil, details: String? = nil, installCommand: String? = nil, category: String = "tool") {
        self.name = name
        self.command = command
        self.required = required
        self.installed = installed
        self.version = version
        self.path = path
        self.details = details
        self.installCommand = installCommand
        self.category = category
    }
    
    public static func == (lhs: DoctorItem, rhs: DoctorItem) -> Bool { lhs.id == rhs.id }
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
    public let ticket: String
    public let path: String
    public let repos: [String]
    public let branches: [String: String]
    public let dirtyCounts: [String: Int]
    public let hasMcpIndex: Bool
    public let isStale: Bool
    public let lastModified: Date
    
    public init(name: String, ticket: String, path: String, repos: [String], branches: [String: String], dirtyCounts: [String: Int], hasMcpIndex: Bool, isStale: Bool, lastModified: Date) {
        self.name = name
        self.ticket = ticket
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
    // ponytail: login shell (-l) costs 200-400ms per spawn loading zprofile. PATH is
    // injected explicitly below, so skip it. Add -l back if a command needs user profile env.
    private static let enrichedPath: String = {
        var paths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin"]
        if let nvm = ProcessInfo.processInfo.environment["NVM_BIN"] {
            paths.append(nvm)
        }
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
