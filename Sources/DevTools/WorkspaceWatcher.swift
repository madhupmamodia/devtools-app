import Foundation
import CoreServices
import WorkspaceCore

/// Watches workspace worktrees for file changes using FSEvents.
///
/// Replaces polling. The kernel tells us when an agent writes a file, and we
/// re-read only that repo's status. Idle cost is zero — no processes, no timers.
///
/// One stream watches every repo at once. ponytail: a single global C callback
/// with no captures keeps the Swift 6 compiler's SendNonSendable pass happy;
/// passing a captured closure through FSEventStreamContext crashed swift-frontend.
final class WorkspaceWatcher: @unchecked Sendable {

    static let shared = WorkspaceWatcher()

    /// Called on a background queue when a repo's working tree changed.
    var onChange: ((String, String) -> Void)?

    private struct Root {
        let path: String
        let workspace: String
        let repo: String
    }

    private let queue = DispatchQueue(label: "devtools.fsevents")
    private let lock = NSLock()
    private var roots: [Root] = []
    private var pending: [String: DispatchWorkItem] = [:]
    private var stream: FSEventStreamRef?
    private let debounceInterval: TimeInterval

    /// Directories that produce noise but never change the dirty count.
    /// A frontend build writing thousands of files into node_modules must not
    /// trigger a git status per file.
    private static let ignoredPaths = [
        "/node_modules/", "/.git/", "/target/", "/build/", "/dist/", "/.next/",
        "/.venv/", "/__pycache__/", "/.gradle/", "/vendor/", "/.dart_tool/",
        "/DerivedData/", "/coverage/", "/.idea/", "/.turbo/", "/.cache/"
    ]

    init(debounceInterval: TimeInterval = 0.4) {
        self.debounceInterval = debounceInterval
    }

    deinit { stop() }

    /// Replaces the watch set. Called after every list refresh so new workspaces
    /// and removed repos are picked up.
    func sync(workspaces: [WorkspaceInfo]) {
        let wanted = workspaces.flatMap { ws in
            ws.repos.map { repo in
                Root(path: (ws.path as NSString).appendingPathComponent(repo),
                     workspace: ws.name, repo: repo)
            }
        }

        lock.lock()
        let changed = wanted.map { $0.path } != roots.map { $0.path }
        roots = wanted
        lock.unlock()

        // FSEventStream takes its path list at creation, so a changed set means
        // a new stream. Cheap: one stream, not one per repo.
        if changed { rebuildStream() }
    }

    func stop() {
        lock.lock()
        for item in pending.values { item.cancel() }
        pending.removeAll()
        roots = []
        let s = stream
        stream = nil
        lock.unlock()

        if let s {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }

    // MARK: - Internals

    private func rebuildStream() {
        lock.lock()
        let paths = roots.map { $0.path }
        let old = stream
        stream = nil
        lock.unlock()

        if let old {
            FSEventStreamStop(old)
            FSEventStreamInvalidate(old)
            FSEventStreamRelease(old)
        }
        guard !paths.isEmpty else { return }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagUseCFTypes)

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, fseGlobalCallback, nil, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, flags
        ) else { return }

        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        lock.lock()
        stream = s
        lock.unlock()
    }

    /// Maps a changed file path back to the repo root that contains it.
    private func root(for path: String) -> Root? {
        lock.lock()
        defer { lock.unlock() }
        var best: Root?
        for r in roots {
            if path.hasPrefix(r.path) {
                if best == nil || r.path.count > best!.path.count { best = r }
            }
        }
        return best
    }

    fileprivate func handleChanged(paths: UnsafeMutableRawPointer?, count: Int) {
        guard let paths, count > 0 else { return }
        let arr = unsafeBitCast(paths, to: NSArray.self)

        var touched = Set<String>()
        for i in 0..<count {
            guard let p = arr[i] as? String else { continue }
            if WorkspaceWatcher.ignoredPaths.contains(where: { p.contains($0) }) { continue }
            guard let root = root(for: p) else { continue }
            touched.insert(root.path)
        }
        for path in touched { scheduleRescan(rootPath: path) }
    }

    /// Coalesces bursts of events into one rescan per repo.
    private func scheduleRescan(rootPath: String) {
        lock.lock()
        pending[rootPath]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let root = self.roots.first { $0.path == rootPath }
            self.pending[rootPath] = nil
            self.lock.unlock()
            guard let root else { return }
            self.onChange?(root.workspace, root.repo)
        }
        pending[rootPath] = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }
}

/// Global C callback — no captures, so nothing to send across the boundary.
private let fseGlobalCallback: FSEventStreamCallback = { _, _, count, paths, _, _ in
    WorkspaceWatcher.shared.handleChanged(paths: paths, count: count)
}
