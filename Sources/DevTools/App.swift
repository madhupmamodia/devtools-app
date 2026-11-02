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
        MenuBarExtra("DevTools", systemImage: "hammer.fill") {
            MainContainerView(usageStore: usageStore, wsStore: wsStore)
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
                    .frame(height: 560)
            } else {
                // Only Models needs a tall pane — its list should fill it.
                // Overview/Insights/Setup size to their own content instead of
                // leaving a dead gap above the action bar.
                let paneHeight: CGFloat? = usageStore.activeTab == .models ? 560 : nil
                if usageStore.needsSetup {
                    SetupView(store: usageStore)
                        .frame(height: paneHeight)
                } else if usageStore.showCustomRange {
                    CustomRangeView(store: usageStore)
                        .frame(height: paneHeight)
                } else {
                    StatsView(store: usageStore)
                        .frame(height: paneHeight)
                }
            }
        }
        // One width for every pane. 440 fits long repo names + PR badges and the
        // 4-column models table. A per-section width makes the window jump on tab switch.
        .frame(width: 440)
    }
}
