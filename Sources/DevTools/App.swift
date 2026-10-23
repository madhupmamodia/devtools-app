import SwiftUI
import AppKit
import WorkspaceCore

public enum RootSection: String, CaseIterable, Identifiable {
    case workspaces = "Workspaces"
    case llmUsage = "LLM Usage"
    public var id: String { rawValue }
}

@main
struct DevToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var usageStore = UsageStore()
    @StateObject private var wsStore = WorkspacesStore()

    var body: some Scene {
        MenuBarExtra {
            MainContainerView(usageStore: usageStore, wsStore: wsStore)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "hammer.fill")
                if usageStore.todaySpend > 0 {
                    Text(String(format: "$%.2f", usageStore.todaySpend))
                        .font(.caption2)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct MainContainerView: View {
    @ObservedObject var usageStore: UsageStore
    @ObservedObject var wsStore: WorkspacesStore
    @State private var activeSection: RootSection = .workspaces

    var body: some View {
        VStack(spacing: 0) {
            // Top Section Switcher
            Picker("", selection: $activeSection) {
                ForEach(RootSection.allCases) { sec in
                    Text(sec.rawValue).tag(sec)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            // Content Body
            if activeSection == .workspaces {
                WorkspacesRootView(store: wsStore)
            } else {
                if usageStore.needsSetup {
                    SetupView(store: usageStore)
                } else if usageStore.showCustomRange {
                    CustomRangeView(store: usageStore)
                } else {
                    StatsView(store: usageStore)
                }
            }
        }
        .frame(width: 360)
    }
}
