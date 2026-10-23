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

            if let err = store.statusError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(4)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(4)
            } else if let msg = store.statusMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
            }

            switch store.selectedTab {
            case .list:
                workspacesListView
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
    }

    // MARK: - Workspaces List
    private var workspacesListView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if store.workspaces.isEmpty {
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
        .frame(maxHeight: 380)
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
                    Button("Open in Cursor") { store.openInCursor(workspace: ws) }
                    Button("Open in Terminal") { store.openInTerminal(workspace: ws) }
                    Button("Re-index MCP Graph") { store.reindex(workspace: ws) }
                    Divider()
                    Button("Prune Workspace", role: .destructive) { store.prune(workspace: ws) }
                    Button("Force Prune (Ignore dirty)", role: .destructive) { store.prune(workspace: ws, force: true) }
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
                .font(.subheadline)
                .fontWeight(.semibold)

            TextField("Ticket ID (e.g. FINX-1234)", text: $store.ticketInput)
                .textFieldStyle(.roundedBorder)

            Text("Select Repositories:")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.configuredRepos) { repo in
                        Toggle(isOn: Binding(
                            get: { store.selectedRepoNames.contains(repo.name) },
                            set: { isSelected in
                                if isSelected { store.selectedRepoNames.insert(repo.name) }
                                else { store.selectedRepoNames.remove(repo.name) }
                            }
                        )) {
                            Text(repo.name).font(.caption)
                        }
                    }
                }
            }
            .frame(maxHeight: 140)

            HStack {
                Button(store.isProvisioning ? "Provisioning..." : "Provision & Index") {
                    store.createWorkspace()
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isProvisioning)
            }
        }
    }

    // MARK: - Doctor View
    private var doctorView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("System Readiness Doctor")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button("Fix Missing") {
                    store.runDoctorFixes()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(store.isRunningDoctor)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.doctorItems) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: item.installed ? "checkmark.circle.fill" : (item.required ? "xmark.circle.fill" : "exclamationmark.triangle.fill"))
                                .foregroundStyle(item.installed ? .green : (item.required ? .red : .orange))
                                .font(.caption)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(.caption).fontWeight(.medium)
                                if let ver = item.version {
                                    Text(ver).font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                if let d = item.details {
                                    Text(d).font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
        }
    }
}
