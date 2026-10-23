import SwiftUI
import WorkspaceCore

struct WorkspacesRootView: View {
    @ObservedObject var store: WorkspacesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Sub-tabs
            Picker("", selection: $store.selectedTab) {
                ForEach(WorkspacesStore.WSTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Only the tab that owns the message renders it. Without this the same
            // "created!" string appears on Workspaces, New and Doctor at once.
            if store.statusOwner == store.selectedTab {
                if let err = store.statusError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(4)
                } else if let msg = store.statusMessage {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                }
            }

            switch store.selectedTab {
            case .list:
                workspacesListView
                if store.addRepoTarget != nil {
                    addRepoSheet
                }
            case .create:
                workspaceCreateView
            case .doctor:
                doctorView
            }

            Divider().padding(.vertical, 2)

            HStack {
                Button("Refresh") { store.refreshAll() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(12)
        .onAppear {
            store.refreshAll()
        }
        .overlay {
            if store.pruneTarget != nil {
                Color.black.opacity(0.35)
                    .onTapGesture { store.cancelPrune() }
                pruneDialog
            }
        }
    }

    // MARK: - Prune Confirmation
    //
    // Two-stage on purpose. A dirty workspace only exposes the destructive action
    // after a second, unambiguous confirmation. Clean workspaces confirm once.
    private var pruneDialog: some View {
        Group {
            if let ws = store.pruneTarget {
                let dirty = store.dirtyRepos(in: ws)
                let isDirty = !dirty.isEmpty

                VStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: isDirty ? "exclamationmark.triangle.fill" : "trash")
                            .foregroundStyle(isDirty ? .orange : .secondary)
                        Text("Prune \(ws.name)?")
                            .font(.headline)
                        Spacer()
                    }

                    Text(ws.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(ws.repos.count) repo(s) will be removed:")
                            .font(.caption)
                        ForEach(ws.repos, id: \.self) { r in
                            HStack(spacing: 6) {
                                Text(r).font(.system(size: 11)).lineLimit(1)
                                Spacer()
                                let n = ws.dirtyCounts[r] ?? 0
                                if n > 0 {
                                    Text("\(n) uncommitted")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }

                    if isDirty {
                        Text("Uncommitted changes are deleted permanently. Push or commit first, or cancel.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack {
                        Button("Cancel", role: .cancel) { store.cancelPrune() }
                            .keyboardShortcut(.cancelAction)
                        Spacer()
                        if isDirty {
                            Toggle("I understand", isOn: $store.pruneAckDestroy)
                                .toggleStyle(.checkbox)
                                .font(.caption)
                            Button("Delete Anyway", role: .destructive) {
                                store.confirmPrune(force: true)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .disabled(!store.pruneAckDestroy)
                        } else {
                            Button("Prune", role: .destructive) {
                                store.confirmPrune(force: false)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        }
                    }
                }
                .padding(12)
                .frame(width: 420)
                .background(Color(NSColor.windowBackgroundColor))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.4)))
                .shadow(radius: 8)
            }
        }
    }

    // MARK: - Workspaces List
    private var workspacesListView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let ap = store.activeProvision {
                    provisionCard(ap)
                }
                if store.workspaces.isEmpty && store.activeProvision == nil {
                    VStack(spacing: 8) {
                        Text("No active workspaces.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Create Workspace") {
                            store.selectedTab = .create
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(store.workspaces) { ws in
                        workspaceCard(ws)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Live card for the workspace being built. Replaces a scrolling log with one
    /// row per repo that visibly ticks from Waiting to Ready.
    private func provisionCard(_ ap: WorkspacesStore.ActiveProvision) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if !ap.finished && ap.failed == nil {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: ap.failed != nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(ap.failed != nil ? .red : .green)
                        .font(.caption)
                }

                Text(ap.ticket)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text(ap.headline)
                    .font(.caption2)
                    .foregroundStyle(ap.failed != nil ? .red : .secondary)

                Spacer()

                if ap.finished || ap.failed != nil {
                    Button {
                        store.dismissActiveProvision()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                }
            }

            if let failed = ap.failed {
                Text(failed)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(ap.repos) { r in
                    HStack(spacing: 6) {
                        phaseIcon(r.phase)
                            .font(.system(size: 9))
                            .frame(width: 12)
                        Text(r.repo)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(r.phase.rawValue)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if ap.indexing {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(ap.failed != nil ? 0.06 : 0.10))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(0.35)))
    }

    private func phaseIcon(_ phase: WorkspaceEngine.ProvisionEvent.RepoPhase) -> some View {
        switch phase {
        case .waiting:
            return AnyView(Image(systemName: "circle").foregroundStyle(.tertiary))
        case .mirror, .worktree:
            return AnyView(Image(systemName: "circle.dotted").foregroundStyle(.orange))
        case .indexed:
            return AnyView(Image(systemName: "checkmark.circle.fill").foregroundStyle(.green))
        }
    }

    private func workspaceCard(_ ws: WorkspaceInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ws.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                if ws.isStale {
                    Text("STALE")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.2))
                        .foregroundStyle(.orange)
                        .cornerRadius(3)
                }
                Spacer()
                // Actions menu
                Menu {
                    Button("Add Repository…") { store.beginAddRepos(to: ws) }
                    Divider()
                    Button(store.hasOpenCodeDesktop ? "Open in OpenCode" : "Open in OpenCode CLI") {
                        store.openInOpenCode(workspace: ws)
                    }
                    Button("Open in \(store.preferredTerminalName)") {
                        store.openInITerm(workspace: ws)
                    }
                    Button("Open in Terminal") {
                        store.openInTerminal(workspace: ws)
                    }
                    if store.hasCursor {
                        Button("Open in Cursor") { store.openInCursor(workspace: ws) }
                    }
                    Divider()
                    Button("Re-index MCP Graph") { store.reindex(workspace: ws) }
                    Divider()
                    Button("Prune Workspace…", role: .destructive) { store.requestPrune(ws) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }

            // CMB Badge
            HStack(spacing: 4) {
                Circle()
                    .fill(ws.hasMcpIndex ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(ws.hasMcpIndex ? "CMB Graph Ready" : "Index Missing")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Repos inside
            VStack(alignment: .leading, spacing: 3) {
                ForEach(ws.repos, id: \.self) { repo in
                    HStack {
                        Text(repo)
                            .font(.caption2)
                            .foregroundStyle(.primary)
                        Spacer()
                        let br = ws.branches[repo] ?? "main"
                        let dirty = ws.dirtyCounts[repo] ?? 0
                        Text(br)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if dirty > 0 {
                            Text("\(dirty) dirty")
                                .font(.system(size: 9))
                                .padding(.horizontal, 3)
                                .background(Color.yellow.opacity(0.2))
                                .foregroundStyle(.yellow)
                                .cornerRadius(2)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }

    // MARK: - Create View
    private var workspaceCreateView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Create Worktree Workspace")
                .font(.headline)

            TextField("Ticket ID (e.g. FINX-1234)", text: $store.ticketInput)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                TextField("Search \(store.configuredRepos.count) repos…", text: $store.repoSearchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                Button(store.isSyncingRepos || store.isSyncingUsage ? "…" : "Sync") {
                    store.syncRepos()
                }
                .controlSize(.small)
                .disabled(store.isSyncingRepos || store.isSyncingUsage)
                .help("Re-fetch repo list and activity ranking from GitHub")
            }

            HStack {
                Toggle(isOn: Binding(
                    get: { store.allVisibleSelected },
                    set: { store.toggleAllRepos($0) }
                )) {
                    Text(store.repoSearchText.isEmpty ? "Select all" : "Select all shown")
                        .font(.callout)
                }
                .toggleStyle(.checkbox)

                Spacer()

                Text("\(store.selectedRepoNames.count) selected")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(store.visibleRepos) { repo in
                        Toggle(isOn: Binding(
                            get: { store.selectedRepoNames.contains(repo.name) },
                            set: { isSelected in
                                if isSelected { store.selectedRepoNames.insert(repo.name) }
                                else { store.selectedRepoNames.remove(repo.name) }
                            }
                        )) {
                            HStack(spacing: 6) {
                                Text(repo.name)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if store.hasUsage {
                                    let prs = store.repoUsage?.prCounts[repo.name] ?? 0
                                    if prs > 0 {
                                        Text("\(prs) PR")
                                            .font(.system(size: 9, design: .monospaced))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.accentColor.opacity(0.18))
                                            .foregroundStyle(Color.accentColor)
                                            .cornerRadius(3)
                                    }
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.vertical, 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            HStack {
                Button(store.isProvisioning ? "Provisioning…" : "Provision & Index") {
                    store.createWorkspace()
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isProvisioning || store.selectedRepoNames.isEmpty)
                Spacer()
                Text("\(store.visibleRepos.count) shown")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Add Repo Sheet
    private var addRepoSheet: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Add to \(store.addRepoTarget?.name ?? "")")
                    .font(.headline)
                Spacer()
                Button("Cancel") { store.cancelAddRepos() }
                    .controlSize(.small)
                    .disabled(store.isAddingRepos)
            }

            TextField("Search repos…", text: $store.addRepoSearch)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            HStack {
                Toggle(isOn: Binding(
                    get: {
                        let c = store.addRepoCandidates
                        return !c.isEmpty && c.allSatisfy { store.addRepoSelection.contains($0.name) }
                    },
                    set: { on in
                        store.addRepoSelection = on
                            ? Set(store.addRepoCandidates.map { $0.name })
                            : []
                    }
                )) {
                    Text("Select all shown").font(.callout)
                }
                .toggleStyle(.checkbox)

                Spacer()
                Text("\(store.addRepoSelection.count) selected")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(store.addRepoCandidates) { repo in
                        Toggle(isOn: Binding(
                            get: { store.addRepoSelection.contains(repo.name) },
                            set: { sel in
                                if sel { store.addRepoSelection.insert(repo.name) }
                                else { store.addRepoSelection.remove(repo.name) }
                            }
                        )) {
                            HStack(spacing: 6) {
                                Text(repo.name)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                let prs = store.repoUsage?.prCounts[repo.name] ?? 0
                                if prs > 0 {
                                    Text("\(prs) PR")
                                        .font(.system(size: 9, design: .monospaced))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.18))
                                        .foregroundStyle(Color.accentColor)
                                        .cornerRadius(3)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.vertical, 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)

            HStack {
                Button(store.isAddingRepos ? "Adding…" : "Add & Index") {
                    store.commitAddRepos()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(store.isAddingRepos || store.addRepoSelection.isEmpty)
                Spacer()
                Text("\(store.addRepoCandidates.count) available")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
    }

    // MARK: - Doctor View
    private var doctorView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("System Readiness Doctor")
                    .font(.headline)
                Spacer()
                Button("Fix all missing") {
                    store.runDoctorFixes()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.isRunningDoctor)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    doctorSection(
                        title: "Required Tools",
                        subtitle: "Workspace creation depends on these.",
                        items: store.doctorItems.filter { $0.category == "tool" }
                    )
                    doctorSection(
                        title: "Coding Agents",
                        subtitle: "Optional. Install only the ones you use.",
                        items: store.doctorItems.filter { $0.category == "agent" }
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
    }
    
    private func doctorSection(title: String, subtitle: String, items: [DoctorItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline).fontWeight(.semibold)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            
            if items.isEmpty {
                Text("Checking…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            
            ForEach(items) { item in
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: item.installed ? "checkmark.circle.fill" : (item.required ? "xmark.circle.fill" : "circle.dashed"))
                        .foregroundStyle(item.installed ? .green : (item.required ? .red : .secondary))
                        .font(.caption)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                            .font(.callout)
                            .fontWeight(.medium)
                        if let d = item.details, item.installed || item.required {
                            Text(d).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        } else if let ver = item.version {
                            Text(ver).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    
                    Spacer(minLength: 4)
                    
                    if !item.installed, let cmd = item.installCommand {
                        Button("Install") {
                            store.install(item)
                        }
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                        .disabled(store.installingItemID == item.id)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}
