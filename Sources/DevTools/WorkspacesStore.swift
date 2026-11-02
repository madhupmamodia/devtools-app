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
    @Published public var installingItemID: String?
    @Published public var isProvisioning: Bool = false
    @Published public var statusMessage: String?
    @Published public var statusError: String?
    /// Which tab the current message belongs to. Stops "created!" banners leaking
    /// across Workspaces / New / Doctor.
    @Published public var statusOwner: WSTab?
    private var statusClearTask: Task<Void, Never>?
    
    /// Sets a transient message and auto-clears it. Errors stay until replaced.
    public func flash(_ message: String, owner: WSTab, after seconds: Double = 6) {
        statusOwner = owner
        statusMessage = message
        statusError = nil
        statusClearTask?.cancel()
        statusClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.statusMessage == message else { return }
                self?.statusMessage = nil
            }
        }
    }
    
    public func fail(_ message: String, owner: WSTab) {
        statusClearTask?.cancel()
        statusOwner = owner
        statusError = message
        statusMessage = nil
    }
    
    // Creation Sheet State
    @Published public var ticketInput: String = ""
    @Published public var selectedRepoNames: Set<String> = []
    @Published public var repoSearchText: String = ""
    @Published public var isSyncingRepos: Bool = false
    @Published public var repoUsage: WorkspaceEngine.RepoUsage?
    @Published public var isSyncingUsage: Bool = false
    
    public func usageScore(for repo: String) -> Int {
        guard let usage = repoUsage else { return 0 }
        return engine.usageScore(for: repo, usage: usage)
    }
    
    public var hasUsage: Bool { repoUsage != nil }
    
    /// Repos matching the search box, always ranked by the signed-in user's own
    /// GitHub activity. No toggle: alphabetical order of 379 repos is never the
    /// useful default.
    public var visibleRepos: [RepoDefinition] {
        let q = repoSearchText.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? configuredRepos : configuredRepos.filter { $0.name.lowercased().contains(q) }
        return list.sorted { a, b in
            let sa = usageScore(for: a.name), sb = usageScore(for: b.name)
            if sa != sb { return sa > sb }
            return a.name < b.name
        }
    }
    
    /// Fetches ranking in the background when the cache is missing or older than 7 days.
    /// ponytail: never blocks the UI on this — it costs ~12s of GitHub paging.
    public func syncUsageIfStale(maxAgeDays: Int = 7) {
        guard !isSyncingUsage else { return }
        if let cached = repoUsage,
           Date().timeIntervalSince(cached.fetchedAt) < Double(maxAgeDays) * 86400 {
            return
        }
        isSyncingUsage = true
        Task.detached { [engine = self.engine] in
            let usage = engine.syncRepoUsage()
            await MainActor.run {
                self.repoUsage = usage
                self.isSyncingUsage = false
                if usage == nil {
                    self.fail("Could not read GitHub activity. Check 'gh auth status'.", owner: .create)
                }
            }
        }
    }
    
    public func toggleAllRepos(_ on: Bool) {
        selectedRepoNames = on ? Set(visibleRepos.map { $0.name }) : []
    }
    
    public var allVisibleSelected: Bool {
        let vis = visibleRepos
        return !vis.isEmpty && vis.allSatisfy { selectedRepoNames.contains($0.name) }
    }
    
    public func syncRepos() {
        isSyncingRepos = true
        Task.detached { [engine = self.engine] in
            let count = engine.syncReposFromGitHub()
            await MainActor.run {
                self.configuredRepos = engine.config.repos
                self.isSyncingRepos = false
                if count > 0 {
                    self.flash("Synced \(count) repos from \(engine.config.defaultOrg).", owner: .create)
                } else {
                    self.fail("Sync failed. Check 'gh auth status'.", owner: .create)
                }
            }
        }
    }
    
    public enum WSTab: String, CaseIterable, Identifiable {
        case list = "Workspaces"
        case create = "New"
        case doctor = "Doctor"
        public var id: String { rawValue }
    }
    
    private let engine = WorkspaceEngine.shared
    
    public init() {
        self.configuredRepos = engine.config.repos
        // ponytail: don't preselect 379 repos. Start empty, user opts in.
        self.selectedRepoNames = []
        self.repoUsage = engine.loadRepoUsage()
    }
    
    /// Kicks off a GitHub org scan on first load if the cache is empty.
    public func syncReposIfEmpty() {
        guard configuredRepos.isEmpty, !isSyncingRepos else { return }
        syncRepos()
    }
    
    // ponytail: workspaces load fast, doctor shells out ~14x so it runs in background.
    // Never blocks the tab switch.
    public func refreshAll() {
        self.workspaces = engine.listWorkspaces()
        self.configuredRepos = engine.config.repos
        if repoUsage == nil { repoUsage = engine.loadRepoUsage() }
        syncReposIfEmpty()
        syncUsageIfStale()
        Task.detached { [engine = self.engine] in
            let items = engine.checkDoctor()
            await MainActor.run { self.doctorItems = items }
        }
    }
    
    /// Installs a single tool. ponytail: users pick what they want — never blanket-install
    /// every agent just because one is missing.
    // Sheet state for adding repos to a live workspace
    @Published public var addRepoTarget: WorkspaceInfo?
    @Published public var addRepoSelection: Set<String> = []
    @Published public var addRepoSearch: String = ""
    @Published public var isAddingRepos: Bool = false
    
    /// Repos not already present in the target workspace, ranked like the create form.
    public var addRepoCandidates: [RepoDefinition] {
        guard let target = addRepoTarget else { return [] }
        let existing = Set(target.repos)
        let q = addRepoSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return configuredRepos
            .filter { !existing.contains($0.name) }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) }
            .sorted { a, b in
                let sa = usageScore(for: a.name), sb = usageScore(for: b.name)
                if sa != sb { return sa > sb }
                return a.name < b.name
            }
    }
    
    public func beginAddRepos(to ws: WorkspaceInfo) {
        addRepoTarget = ws
        addRepoSelection = []
        addRepoSearch = ""
    }
    
    public func cancelAddRepos() {
        addRepoTarget = nil
        addRepoSelection = []
        isAddingRepos = false
    }
    
    public func commitAddRepos() {
        guard let target = addRepoTarget, !addRepoSelection.isEmpty else { return }
        isAddingRepos = true
        statusOwner = .list
        statusError = nil
        let name = target.name
        let repos = Array(addRepoSelection)
        activeProvision = ActiveProvision(
            ticket: name,
            repos: repos.map { RepoProgress(repo: $0, phase: .waiting) },
            indexing: false, finished: false, failed: nil
        )
        // Close the sheet immediately. The provision card at the top now owns the
        // progress; leaving the form open duplicates it and blocks the list.
        addRepoTarget = nil
        addRepoSelection = []
        
        Task.detached { [engine = self.engine] in
            do {
                try engine.addRepos(toWorkspace: name, repoNames: repos) { ev in
                    Task { @MainActor in self.apply(ev) }
                }
                await MainActor.run {
                    self.isAddingRepos = false
                    self.refreshAll()
                    self.flash("Added \(repos.count) repo(s) to \(name).", owner: .list)
                }
            } catch {
                await MainActor.run {
                    self.isAddingRepos = false
                    self.refreshAll()
                    self.fail(error.localizedDescription, owner: .list)
                }
            }
        }
    }
    
    // Sheet state for removing repos from a live workspace
    @Published public var removeRepoTarget: WorkspaceInfo?
    @Published public var removeRepoSelection: Set<String> = []
    @Published public var isRemovingRepos: Bool = false
    /// Must be true before a repo with uncommitted changes can be discarded.
    @Published public var removeAckDirty: Bool = false
    
    public func beginRemoveRepos(to ws: WorkspaceInfo) {
        removeRepoTarget = ws
        removeRepoSelection = []
        removeAckDirty = false
    }
    
    public func cancelRemoveRepos() {
        removeRepoTarget = nil
        removeRepoSelection = []
        removeAckDirty = false
    }
    
    /// Repos selected for removal that still have uncommitted changes.
    public var removeDirtyRepos: [(repo: String, count: Int)] {
        guard let ws = removeRepoTarget else { return [] }
        return removeRepoSelection
            .compactMap { name -> (String, Int)? in
                let n = ws.dirtyCounts[name] ?? 0
                return n > 0 ? (name, n) : nil
            }
            .sorted { $0.1 > $1.1 }
    }
    
    public func commitRemoveRepos() {
        guard let target = removeRepoTarget, !removeRepoSelection.isEmpty else { return }
        let name = target.name
        let repos = Array(removeRepoSelection)
        let dirty = !removeDirtyRepos.isEmpty
        if dirty && !removeAckDirty { return }
        
        isRemovingRepos = true
        statusError = nil
        Task.detached { [engine = self.engine] in
            do {
                try engine.removeRepos(fromWorkspace: name, repoNames: repos, force: dirty)
                await MainActor.run {
                    self.isRemovingRepos = false
                    self.removeRepoTarget = nil
                    self.removeRepoSelection = []
                    self.removeAckDirty = false
                    self.refreshAll()
                    self.flash("Removed \(repos.count) repo(s) from \(name).", owner: .list)
                }
            } catch {
                await MainActor.run {
                    self.isRemovingRepos = false
                    self.fail(error.localizedDescription, owner: .list)
                }
            }
        }
    }
    
    public func install(_ item: DoctorItem) {
        guard installingItemID == nil, let cmd = item.installCommand else { return }
        installingItemID = item.id
        statusOwner = .doctor
        statusError = nil
        statusMessage = "Installing \(item.name)…"
        let name = item.name
        Task.detached { [engine = self.engine] in
            let ok = engine.fixDoctor(item: item)
            await MainActor.run {
                self.installingItemID = nil
                self.doctorItems = engine.checkDoctor()
                if ok {
                    self.flash("\(name) installed.", owner: .doctor)
                } else {
                    self.fail("Install failed for \(name). Command: \(cmd)", owner: .doctor)
                }
            }
        }
    }
    
    public func runDoctorFixes() {
        isRunningDoctor = true
        statusOwner = .doctor
        statusMessage = "Installing missing prerequisites..."
        Task.detached { [engine = self.engine] in
            let items = engine.checkDoctor()
            for item in items where !item.installed {
                _ = engine.fixDoctor(item: item)
            }
            await MainActor.run {
                self.doctorItems = engine.checkDoctor()
                self.isRunningDoctor = false
                self.flash("Doctor verification finished.", owner: .doctor)
            }
        }
    }
    
    /// Live state for the workspace currently being provisioned. Rendered as a card in the
    /// Workspaces list so the user watches the workspace build, not a log scroll by.
    public struct RepoProgress: Identifiable {
        public var id: String { repo }
        public var repo: String
        public var phase: WorkspaceEngine.ProvisionEvent.RepoPhase
    }
    
    public struct ActiveProvision: Identifiable {
        public var id: String { ticket }
        public var ticket: String
        public var repos: [RepoProgress]
        public var indexing: Bool
        public var finished: Bool
        public var failed: String?
        
        var headline: String {
            if let failed { return "Failed" }
            if finished { return "Ready" }
            if indexing { return "Building code graph…" }
            return "Creating…"
        }
    }
    
    @Published public var activeProvision: ActiveProvision?
    /// Non-nil means "a prune is awaiting confirmation". Nothing deletes without it.
    @Published public var pruneTarget: WorkspaceInfo?
    /// Must be true before a dirty workspace can be force-deleted.
    @Published public var pruneAckDestroy: Bool = false
    private var provisionClearTask: Task<Void, Never>?

    /// Repos with uncommitted changes in the pending prune. Empty = safe to delete.
    public func dirtyRepos(in ws: WorkspaceInfo) -> [(repo: String, count: Int)] {
        ws.repos
            .map { ($0, ws.dirtyCounts[$0] ?? 0) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
    }

    /// Stage a prune for confirmation. Never deletes on its own.
    public func requestPrune(_ ws: WorkspaceInfo) {
        pruneTarget = ws
        pruneAckDestroy = false
    }

    public func cancelPrune() {
        pruneTarget = nil
        pruneAckDestroy = false
    }

    /// Actually delete. `force` is required when any repo has uncommitted changes.
    public func confirmPrune(force: Bool) {
        guard let ws = pruneTarget else { return }
        pruneTarget = nil
        pruneAckDestroy = false
        do {
            try engine.pruneWorkspace(name: ws.name, force: force)
            flash("Pruned \(ws.name).", owner: .list)
        } catch {
            fail(error.localizedDescription, owner: .list)
        }
        refreshAll()
    }
    
    public func createWorkspace() {
        guard !ticketInput.trimmingCharacters(in: .whitespaces).isEmpty else {
            fail("Ticket ID cannot be empty.", owner: .create)
            return
        }
        guard !selectedRepoNames.isEmpty else {
            fail("Select at least one repo.", owner: .create)
            return
        }
        
        let ticket = ticketInput.trimmingCharacters(in: .whitespaces).uppercased()
        let repos = Array(selectedRepoNames)
        
        isProvisioning = true
        statusError = nil
        selectedTab = .list
        activeProvision = ActiveProvision(
            ticket: ticket,
            repos: repos.map { RepoProgress(repo: $0, phase: .waiting) },
            indexing: false,
            finished: false,
            failed: nil
        )
        resetCreateForm()
        
        Task.detached { [engine = self.engine] in
            do {
                _ = try engine.createWorkspace(ticket: ticket, selectedRepoNames: repos) { ev in
                    Task { @MainActor in self.apply(ev) }
                }
                await MainActor.run {
                    self.isProvisioning = false
                    self.refreshAll()
                }
            } catch {
                await MainActor.run {
                    self.isProvisioning = false
                    self.activeProvision?.failed = error.localizedDescription
                    self.refreshAll()
                }
            }
        }
    }
    
    private func apply(_ ev: WorkspaceEngine.ProvisionEvent) {
        guard var ap = activeProvision else { return }
        switch ev {
        case .repoStarted(let r):
            if let i = ap.repos.firstIndex(where: { $0.repo == r }) { ap.repos[i].phase = .mirror }
        case .repoPhase(let r, let phase):
            if let i = ap.repos.firstIndex(where: { $0.repo == r }) { ap.repos[i].phase = phase }
        case .indexing:
            ap.indexing = true
        case .complete:
            ap.indexing = false
            ap.finished = true
            ap.repos = ap.repos.map { RepoProgress(repo: $0.repo, phase: .indexed) }
            // Hand over to the real workspace card once the user has seen "Ready".
            provisionClearTask?.cancel()
            provisionClearTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if self?.activeProvision?.finished == true { self?.activeProvision = nil }
                }
            }
        }
        activeProvision = ap
    }
    
    public func dismissActiveProvision() {
        provisionClearTask?.cancel()
        activeProvision = nil
    }
    
    /// Fresh form for the next ticket. Keeps repo list + ranking cache intact.
    public func resetCreateForm() {
        ticketInput = ""
        selectedRepoNames = []
        repoSearchText = ""
    }
    
    public func reindex(workspace: WorkspaceInfo) {
        statusOwner = .list
        statusMessage = "Re-indexing \(workspace.name)…"
        let path = workspace.path
        Task.detached { [engine = self.engine] in
            let res = engine.reindexWorkspace(workspacePath: path)
            await MainActor.run {
                self.flash(res.message, owner: .list, after: 8)
                self.refreshAll()
            }
        }
    }
    
    public func openInCursor(workspace: WorkspaceInfo) {
        // shell-escaped: workspace paths can contain spaces
        _ = ProcessRunner.run("cursor \(shellQuote(workspace.path))")
    }
    
    private func appExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: "/Applications/\(name).app")
    }
    
    /// iTerm2 when installed, otherwise Terminal.app. Checked at call time so a later
    /// `brew install --cask iterm2` is picked up without a restart.
    public func openInITerm(workspace: WorkspaceInfo) {
        _ = ProcessRunner.run("open -a \(terminalApp) \(shellQuote(workspace.path))")
    }
    
    public func openInTerminal(workspace: WorkspaceInfo) {
        _ = ProcessRunner.run("open -a Terminal \(shellQuote(workspace.path))")
    }
    
    /// Bundle name Launch Services understands. Falls back to Terminal.app.
    private var terminalApp: String { appExists("iTerm") ? "iTerm" : "Terminal" }
    
    public var preferredTerminalName: String { appExists("iTerm") ? "iTerm2" : "Terminal" }
    
    public var hasOpenCodeDesktop: Bool { appExists("OpenCode") }
    
    public var hasCursor: Bool { appExists("Cursor") }
    
    public func openInOpenCode(workspace: WorkspaceInfo) {
        // OpenCode desktop 1.19.3 cannot be driven into a project. Its
        // opencode://open-project deep link is received by the main process but the
        // renderer drops it: handleDeepLinks() bails on server.isLocal(), and the
        // shipped build hardcodes InstallationChannel = "prod", so isLocal() is always
        // false. Verified: the link logs as received, but projects.touch() never runs.
        //
        // ponytail: do not "fix" this by adding a deep link back — it will silently
        // no-op. Launching the CLI instead registers the directory in the shared
        // ~/.local/share/opencode DB, so the desktop app then lists the project and
        // the engineer opens it with one click. Works without quitting their session.
        openTerminalRunning("opencode", in: workspace)
    }
    
    /// Opens a terminal window at the workspace and runs `command` there.
    public func openTerminalRunning(_ command: String, in workspace: WorkspaceInfo) {
        let dir = shellQuote(workspace.path)
        let line = "cd \(dir) && \(command)"
        
        if appExists("iTerm") {
            // iTerm2 AppleScript: create a window running the command in that dir.
            let script = """
            tell application "iTerm"
              activate
              set newWindow to (create window with default profile)
              tell current session of newWindow
                write text "\(line)"
              end tell
            end tell
            """
            ProcessRunner.run("osascript -e \(shellQuote(script))")
        } else {
            ProcessRunner.run("osascript -e \(shellQuote("tell application \"Terminal\" to do script \(shellQuote(line))"))")
        }
    }
    
    /// Fallback that always works: show the folder so the engineer can use
    /// OpenCode desktop's File > Open Folder.
    public func revealInFinder(workspace: WorkspaceInfo) {
        ProcessRunner.run("open \(shellQuote(workspace.path))")
    }
    
    /// Single-quote for POSIX shell. Ticket names are validated but repo/paths are not.
    private func shellQuote(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
