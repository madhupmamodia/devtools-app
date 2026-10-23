import Foundation

public struct DoctorItem: Codable, Identifiable {
    public var id: String { name }
    public let name: String
    public let command: String
    public let required: Bool
    public let installed: Bool
    public let version: String?
    public let path: String?
    public let details: String?
    public let installCommand: String?
    
    public init(name: String, command: String, required: Bool, installed: Bool, version: String? = nil, path: String? = nil, details: String? = nil, installCommand: String? = nil) {
        self.name = name
        self.command = command
        self.required = required
        self.installed = installed
        self.version = version
        self.path = path
        self.details = details
        self.installCommand = installCommand
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
    
    public init(
        rootDirectory: String = ("~/workspaces" as NSString).expandingTildeInPath,
        cacheDirectory: String = ("~/.cache/ws/repos" as NSString).expandingTildeInPath,
        repos: [RepoDefinition] = []
    ) {
        self.rootDirectory = rootDirectory
        self.cacheDirectory = cacheDirectory
        self.repos = repos
    }
}

public enum ProcessRunner {
    @discardableResult
    public static func run(_ command: String, currentDirectory: String? = nil) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        
        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            ("/Users/madhup/.nvm/versions/node/v20.13.1/bin" as NSString).expandingTildeInPath,
            (ProcessInfo.processInfo.environment["HOME"] ?? "") + "/.local/bin"
        ]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = extraPaths.joined(separator: ":") + ":" + currentPath
        process.environment = env
        
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus, stdout, stderr)
        } catch {
            return (-1, "", error.localizedDescription)
        }
    }
}
