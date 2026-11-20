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
    @Published public var isScanning: Bool = false
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
    @Published public var nameInput: String = ""
    @Published public var selectedRepoNames: Set<String> = []
    @Published public var repoSearchText: String = ""
    @Published public var isSyncingRepos: Bool = false
    @Published public var repoUsage: WorkspaceEngine.RepoUsage?
    @Published public var isSyncingUsage: Bool = false
    
        /// Live slug preview of the name field, capped the same way the engine caps it.
    public var nameSlug: String {
        WorkspaceEngine.normalizeName(nameInput)
    }
    
    public func usageScore(for repo: String) -> Int {
        guard let usage = repoUsage else { return 0 }
        return engine.usageScore(for: repo, usage: usage)
    }
    
    public var hasUsage: Bool { repoUsage != nil }
    
    /// Repos matching the search box, always ranked by the signed-in user's own
    /// GitHub activity. No toggle: alphabetical order of 379 repos is never the
    /// useful default.
    ///
    /// ponytail: the sort is cached. It used to run on every access, and SwiftUI
    /// reads this from several places per frame (ForEach body, select-all state,
    /// counts). Sorting 379 repos per frame is pure waste.
    public var visibleRepos: [RepoDefinition] {
        let q = repoSearchText.trimmingCharacters(in: .whitespaces).lowercased()
        let cacheKey = "\(q)|\(configuredRepos.count)|\(usageRevision)"
        if let cached = visibleReposCache, cached.key == cacheKey {
            return cached.repos
        }
        
        let list = q.isEmpty ? configuredRepos : configuredRepos.filter { $0.name.lowercased().contains(q) }
        let sorted = list.sorted { a, b in
            let sa = usageScore(for: a.name), sb = usageScore(for: b.name)
            if sa != sb { return sa > sb }
            return a.name < b.name
        }
        visibleReposCache = (key: cacheKey, repos: sorted)
        return sorted
    }
    
    /// Bumped whenever the ranking changes, so the cached order is invalidated.
    private var usageRevision: Int = 0
    private var visibleReposCache: (key: String, repos: [RepoDefinition])?
    
    /// Fetches ranking in the background when the cache is missing or older than 7 days.
    /// ponytail: never blocks the UI on this — it costs ~12s of GitHub paging.
    /// - Parameter force: refresh even when the cache is fresh. The Sync button uses
    ///   this — the cache can be fresh but WRONG (e.g. written by an older build
    ///   that could not read it back).
    public func syncUsageIfStale(maxAgeDays: Int = 7, force: Bool = false) {
        guard !isSyncingUsage else { return }
        if !force, let cached = repoUsage,
           Date().timeIntervalSince(cached.fetchedAt) < Double(maxAgeDays) * 86400 {
            return
        }
        isSyncingUsage = true
        Task.detached { [engine = self.engine] in
            let usage = engine.syncRepoUsage()
            await MainActor.run {
                self.repoUsage = usage
                self.usageRevision += 1
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
    /// Workspaces only. Runs the git scan off the main actor so switching tabs never
    /// blocks the UI, and shows the previous list until the new one lands.
    /// Doctor / repo sync / usage ranking have their own triggers and are NOT
    /// run here — the doctor alone costs ~14 process spawns plus two network probes.
    public func refreshAll() {
        configuredRepos = engine.config.repos
        if repoUsage == nil { repoUsage = engine.loadRepoUsage() }
        // Self-heal the ranking: if the cache is missing or older than a week,
        // refresh it in the background. This was never wired up, so the ranking
        // silently stayed whatever the cache happened to hold.
        syncUsageIfStale()
        guard !isScanning else { return }
        isScanning = true
        let expanded = expandedRepo
        let expandedWS = expanded?.workspaceName
        let expandedRepoName = expanded?.repo
        Task.detached { [engine = self.engine] in
            let found = engine.listWorkspaces()
            // Keep the open file list in step with the counts.
            var files: [WorkspaceEngine.DirtyFile] = []
            if let expandedWS, let expandedRepoName {
                files = engine.dirtyFiles(inWorkspace: expandedWS, repo: expandedRepoName)
            }
            await MainActor.run {
                self.workspaces = found
                self.isScanning = false
                if let expandedRepoName { self.dirtyFileLists[expandedRepoName] = files }
                self.watcher.sync(workspaces: found)
            }
        }
    }
    
    /// Live refresh via FSEvents. The kernel notifies us when an agent writes a
    /// file, so we re-read only that repo instead of polling every repo on a timer.
    /// Idle cost is zero.
    /// Must be the shared instance: the global FSEvents C callback routes through
    /// WorkspaceWatcher.shared, so a private instance would never receive events.
    private let watcher = WorkspaceWatcher.shared
    
    public func startAutoRefresh() {
        watcher.onChange = { [weak self] workspace, repo in
            Task { @MainActor in self?.refreshRepo(workspace: workspace, repo: repo) }
        }
        watcher.sync(workspaces: workspaces)
    }
    
    public func stopAutoRefresh() {
        watcher.onChange = nil
        watcher.stop()
    }
    
    /// Re-reads the status of one repo and updates just that repo's counts.
    private func refreshRepo(workspace: String, repo: String) {
        guard let ws = workspaces.first(where: { $0.name == workspace }),
              ws.repos.contains(repo) else { return }
        Task.detached { [engine = self.engine] in
            let files = engine.dirtyFiles(inWorkspace: workspace, repo: repo)
            await MainActor.run {
                self.dirtyFileLists[repo] = files
                // Reuse the cached list to patch the count in place.
                if let idx = self.workspaces.firstIndex(where: { $0.name == workspace }) {
                    var updated = self.workspaces[idx]
                    updated.dirtyCounts[repo] = files.count
                    self.workspaces[idx] = updated
                }
            }
        }
    }
    
    /// Doctor scan. Triggered by opening the Doctor tab or hitting Refresh there,
    /// not by every tab switch.
    ///
    /// The tab paints from the cached snapshot immediately, then re-checks in the
    /// background. A full check costs ~1.3s (network probe included) and the user
    /// should never stare at a spinner for it.
    public func refreshDoctor(force: Bool = false) {
        guard !isRunningDoctor else { return }
        if !force, let snapshot = engine.loadDoctorSnapshot() {
            doctorItems = snapshot.items
            // Fresh enough — nothing to do.
            if Date().timeIntervalSince(snapshot.checkedAt) < 300 {
                return
            }
        }
        isRunningDoctor = true
        Task.detached { [engine = self.engine] in
            let items = engine.checkDoctor()
            await MainActor.run {
                self.doctorItems = items
                self.isRunningDoctor = false
            }
            engine.saveDoctorSnapshot(items: items)
        }
    }
    
    /// Called when the Doctor tab becomes visible. Shows the cached result at once.
    public func doctorTabAppeared() {
        if let snapshot = engine.loadDoctorSnapshot() {
            doctorItems = snapshot.items
        }
        refreshDoctor()
    }
    
    public func syncReposAndUsage() {
        syncReposIfEmpty()
        syncUsageIfStale()
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
                    DispatchQueue.main.async { self.apply(ev) }
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
    
    // MARK: - Dirty File Actions
    
    /// Which repo's dirty file list is expanded.
    public struct ExpandedRepo: Equatable {
        public let workspaceName: String
        public let repo: String
    }
    @Published public var expandedRepo: ExpandedRepo?
    @Published public var dirtyFileLists: [String: [WorkspaceEngine.DirtyFile]] = [:]
    @Published public var discardTarget: (workspace: String, repo: String)?
    @Published public var isWorking: Bool = false
    
    /// Toggles the file list for a repo. Fetched on demand so the list scan stays cheap.
    public func toggleDirtyFiles(workspace: WorkspaceInfo, repo: String) {
        let target = ExpandedRepo(workspaceName: workspace.name, repo: repo)
        if expandedRepo == target {
            expandedRepo = nil
            return
        }
        expandedRepo = target
        let wsName = workspace.name
        Task.detached { [engine = self.engine] in
            let files = engine.dirtyFiles(inWorkspace: wsName, repo: repo)
            await MainActor.run { self.dirtyFileLists[repo] = files }
        }
    }
    
    public func commitRepo(_ workspace: WorkspaceInfo, repo: String) {
        isWorking = true
        let message = "chore(\(workspace.name)): workspace changes"
        let wsName = workspace.name
        Task.detached { [engine = self.engine] in
            do {
                try engine.commitAll(inWorkspace: wsName, repo: repo, message: message)
                await MainActor.run {
                    self.isWorking = false
                    self.flash("Committed \(repo).", owner: .list)
                    self.dirtyFileLists[repo] = []
                    self.refreshAll()
                }
            } catch {
                await MainActor.run {
                    self.isWorking = false
                    self.fail(error.localizedDescription, owner: .list)
                }
            }
        }
    }
    
    public func requestDiscard(_ workspace: WorkspaceInfo, repo: String) {
        discardTarget = (workspace: workspace.name, repo: repo)
    }
    
    public func cancelDiscard() {
        discardTarget = nil
    }
    
    public func confirmDiscard() {
        guard let target = discardTarget else { return }
        discardTarget = nil
        isWorking = true
        let wsName = target.workspace
        let repoName = target.repo
        Task.detached { [engine = self.engine] in
            do {
                try engine.discardChanges(inWorkspace: wsName, repo: repoName)
                await MainActor.run {
                    self.isWorking = false
                    self.flash("Discarded changes in \(repoName).", owner: .list)
                    self.dirtyFileLists[repoName] = []
                    self.refreshAll()
                }
            } catch {
                await MainActor.run {
                    self.isWorking = false
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
        let slug = WorkspaceEngine.normalizeName(nameInput)
        guard !slug.isEmpty else {
            fail("Workspace name cannot be empty.", owner: .create)
            return
        }
        guard !selectedRepoNames.isEmpty else {
            fail("Select at least one repo.", owner: .create)
            return
        }
        
        let ticket = ticketInput.trimmingCharacters(in: .whitespaces).uppercased()
        let name = slug
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
                _ = try engine.createWorkspace(ticket: ticket, name: name, selectedRepoNames: repos) { ev in
                    DispatchQueue.main.async { self.apply(ev) }
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
        case .repoSkipped(let r, _):
            if let i = ap.repos.firstIndex(where: { $0.repo == r }) { ap.repos[i].phase = .skipped }
        case .indexing:
            ap.indexing = true
        case .complete:
            ap.indexing = false
            ap.finished = true
            ap.repos = ap.repos.map { $0.phase == .skipped ? $0 : RepoProgress(repo: $0.repo, phase: .indexed) }
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
        nameInput = ""
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
