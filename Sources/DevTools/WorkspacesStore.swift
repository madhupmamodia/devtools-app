import Foundation
import Combine
import SwiftUI
import WorkspaceCore

@MainActor
public final class WorkspacesStore: ObservableObject {
    @Published public var doctorItems: [DoctorItem] = []
    @Published public var workspaces: [WorkspaceInfo] = []
    @Published public var configuredRepos: [RepoDefinition] = []
    
    @Published public var selectedTab: WSTab = .list
    @Published public var isRunningDoctor: Bool = false
    @Published public var isProvisioning: Bool = false
    @Published public var statusMessage: String?
    @Published public var statusError: String?
    
    // Creation Sheet State
    @Published public var ticketInput: String = ""
    @Published public var selectedRepoNames: Set<String> = []
    
    public enum WSTab: String, CaseIterable, Identifiable {
        case list = "Workspaces"
        case create = "New"
        case doctor = "Doctor"
        public var id: String { rawValue }
    }
    
    private let engine = WorkspaceEngine.shared
    
    public init() {
        refreshAll()
    }
    
    public func refreshAll() {
        self.workspaces = engine.listWorkspaces()
        self.doctorItems = engine.checkDoctor()
        self.configuredRepos = engine.config.repos
        if selectedRepoNames.isEmpty {
            selectedRepoNames = Set(configuredRepos.map { $0.name })
        }
    }
    
    public func runDoctorFixes() {
        isRunningDoctor = true
        statusMessage = "Installing missing prerequisites..."
        Task.detached { [engine = self.engine] in
            let items = engine.checkDoctor()
            for item in items where !item.installed {
                _ = engine.fixDoctor(item: item)
            }
            await MainActor.run {
                self.doctorItems = engine.checkDoctor()
                self.isRunningDoctor = false
                self.statusMessage = "Doctor verification finished."
            }
        }
    }
    
    public func createWorkspace() {
        guard !ticketInput.trimmingCharacters(in: .whitespaces).isEmpty else {
            statusError = "Ticket ID cannot be empty."
            return
        }
        guard !selectedRepoNames.isEmpty else {
            statusError = "Select at least one repo."
            return
        }
        
        isProvisioning = true
        statusError = nil
        let ticket = ticketInput.trimmingCharacters(in: .whitespaces).uppercased()
        let repos = Array(selectedRepoNames)
        
        Task.detached { [engine = self.engine] in
            do {
                _ = try engine.createWorkspace(ticket: ticket, selectedRepoNames: repos) { progress in
                    Task { @MainActor in
                        self.statusMessage = progress
                    }
                }
                await MainActor.run {
                    self.isProvisioning = false
                    self.ticketInput = ""
                    self.statusMessage = "Workspace \(ticket) created!"
                    self.refreshAll()
                    self.selectedTab = .list
                }
            } catch {
                await MainActor.run {
                    self.isProvisioning = false
                    self.statusError = error.localizedDescription
                }
            }
        }
    }
    
    public func reindex(workspace: WorkspaceInfo) {
        statusMessage = "Re-indexing \(workspace.name)..."
        let path = workspace.path
        Task.detached { [engine = self.engine] in
            let res = engine.reindexWorkspace(workspacePath: path)
            await MainActor.run {
                self.statusMessage = res.message
                self.refreshAll()
            }
        }
    }
    
    public func prune(workspace: WorkspaceInfo, force: Bool = false) {
        do {
            try engine.pruneWorkspace(name: workspace.name, force: force)
            statusMessage = "Pruned \(workspace.name)."
            refreshAll()
        } catch {
            statusError = error.localizedDescription
        }
    }
    
    public func openInCursor(workspace: WorkspaceInfo) {
        _ = ProcessRunner.run("cursor \"\(workspace.path)\"")
    }
    
    public func openInTerminal(workspace: WorkspaceInfo) {
        _ = ProcessRunner.run("open -a Terminal \"\(workspace.path)\"")
    }
    
    public func openInOpenCode(workspace: WorkspaceInfo) {
        _ = ProcessRunner.run("open -a Terminal \"\(workspace.path)\"")
    }
}
