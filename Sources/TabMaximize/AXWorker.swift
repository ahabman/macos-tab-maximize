import ApplicationServices
import Foundation

/// What happened for one activation. Sendable so it can cross back to the main actor.
enum Outcome: Sendable {
    case restored([String])
    case wouldRestore([String])
    case skipped(String)
    case failed(String)
    case permissionLost

    var description: String {
        switch self {
        case .restored(let titles): return "restored \(titles.joined(separator: ", "))"
        case .wouldRestore(let titles): return "would restore \(titles.joined(separator: ", "))"
        case .skipped(let why): return "skipped — \(why)"
        case .failed(let why): return "failed — \(why)"
        case .permissionLost: return "accessibility permission lost"
        }
    }

    var didAct: Bool {
        if case .restored = self { return true }
        return false
    }
}

/// Owns every Accessibility call in the process.
///
/// AX calls are synchronous Mach IPC into the target application's run loop: safe from
/// any thread, but blocking, so they must never run on the main thread. A dedicated
/// serial `DispatchQueue` is used rather than an `actor` because blocking IPC on the
/// cooperative thread pool can starve it.
///
/// `AXUIElement` values never escape this file — the public surface takes a `pid_t` and
/// hands back Sendable values.
final class AXWorker: @unchecked Sendable {
    static let shared = AXWorker()

    private let queue = DispatchQueue(label: "com.bamf.tabmaximize.ax", qos: .userInitiated)

    /// Retry ladder, in seconds. The AX window list is frequently empty or stale at the
    /// instant the activation notification arrives, especially the first time an app is
    /// inspected. Roughly half a second of total budget, spent front-loaded.
    private static let ladder: [TimeInterval] = [0, 0.03, 0.08, 0.16, 0.30, 0.50]

    private static let messagingTimeout: Float = 0.25

    /// Queue-confined. Apps that time out repeatedly are parked so a hung process does
    /// not burn the ladder on every single switch.
    private var timeoutStrikes: [pid_t: Int] = [:]
    private var parkedUntil: [pid_t: Date] = [:]

    // MARK: - Public surface

    func restore(pid: pid_t, restoreAll: Bool, dryRun: Bool, completion: @escaping @Sendable (Outcome) -> Void) {
        queue.async { [self] in
            if let until = parkedUntil[pid], until > Date() {
                completion(.skipped("app parked after repeated AX timeouts"))
                return
            }
            attempt(pid: pid, step: 0, restoreAll: restoreAll, dryRun: dryRun, completion: completion)
        }
    }

    /// Used by `--restore-ax` to isolate which step of the restore sequence has which
    /// effect. Acts on the front-most minimized window only.
    func restoreFirstMinimized(pid: pid_t, raise: Bool, setMain: Bool, completion: @escaping @Sendable (String) -> Void) {
        queue.async {
            let app = AXUIElementCreateApplication(pid)
            AX.setTimeout(app, 2.0)
            guard let windows = try? AX.copyValue(app, kAXWindowsAttribute as String, as: [AXUIElement].self).get() else {
                completion("could not read windows")
                return
            }
            let snapshots = windows.enumerated().map { Self.snapshot(index: $0.offset, window: $0.element) }
            guard let target = snapshots.first(where: { $0.isRestoreCandidate })?.index else {
                completion("nothing minimized")
                return
            }
            AX.setValue(windows[target], kAXMinimizedAttribute as String, kCFBooleanFalse)
            if raise { AX.perform(windows[target], kAXRaiseAction as String) }
            if setMain { AX.setValue(windows[target], kAXMainAttribute as String, kCFBooleanTrue) }
            completion("acted on [\(target)] \(snapshots[target].title ?? "(untitled)") (raise: \(raise), setMain: \(setMain))")
        }
    }

    /// Used by `--dock-list` to inspect what the Dock exposes.
    func dockItems(completion: @escaping @Sendable ([String]) -> Void) {
        queue.async {
            completion(DockFallback.minimizedItems().map(\.title))
        }
    }

    /// Used by `--dock-press` to check whether a Dock tile restores just one window.
    func pressDockItem(title: String, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            completion(DockFallback.press(title: title))
        }
    }

    /// Used by `--dump-ax`. Returns whatever the app reports, unfiltered.
    func dump(pid: pid_t, completion: @escaping @Sendable ([WindowSnapshot], AXError?) -> Void) {
        queue.async {
            let app = AXUIElementCreateApplication(pid)
            AX.setTimeout(app, 2.0)
            switch AX.copyValue(app, kAXWindowsAttribute as String, as: [AXUIElement].self) {
            case .failure(let err):
                completion([], err)
            case .success(let windows):
                completion(windows.enumerated().map { Self.snapshot(index: $0.offset, window: $0.element) }, nil)
            }
        }
    }

    // MARK: - The ladder

    private func attempt(pid: pid_t, step: Int, restoreAll: Bool, dryRun: Bool, completion: @escaping @Sendable (Outcome) -> Void) {
        // The window server answers without touching the target process, so this costs
        // far less than an AX round trip and settles the common case: the app already
        // has something on screen, and Cmd+Tab did the right thing by itself.
        if step == 0 {
            let onscreen = CGWindows.summary(pid: pid).onscreen
            if onscreen > 0 {
                completion(.skipped("\(onscreen) window(s) already on screen"))
                return
            }
        }

        let app = AXUIElementCreateApplication(pid)
        AX.setTimeout(app, Self.messagingTimeout)

        switch AX.copyValue(app, kAXWindowsAttribute as String, as: [AXUIElement].self) {
        case .failure(let err):
            if err == .apiDisabled {
                completion(.permissionLost)
                return
            }
            if err == .cannotComplete {
                noteTimeout(pid: pid)
            }
            if err.isTerminalForApp {
                completion(.failed("app does not expose windows over AX (\(err.name))"))
                return
            }
            retry(pid: pid, step: step, restoreAll: restoreAll, dryRun: dryRun,
                  giveUpReason: "AX error \(err.name)", completion: completion)

        case .success(let windows):
            clearTimeouts(pid: pid)

            if windows.isEmpty {
                // Either the list has not caught up with the activation yet, or the app
                // genuinely has no windows. Only time tells them apart, so ride out the
                // ladder and treat persistent emptiness as the ordinary, harmless case
                // it usually is — an app whose windows the user closed.
                retry(pid: pid, step: step, restoreAll: restoreAll, dryRun: dryRun,
                      giveUpReason: nil, completion: completion)
                return
            }

            let snapshots = windows.enumerated().map { Self.snapshot(index: $0.offset, window: $0.element) }
            let windowIndexes = snapshots.indices.filter { snapshots[$0].isWindow }

            guard !windowIndexes.isEmpty else {
                completion(.skipped("no windows among \(snapshots.count) AX element(s): \(snapshots.map(\.label).joined(separator: " "))"))
                return
            }

            let visible = windowIndexes.filter { snapshots[$0].isVisibleWindow }
            guard visible.isEmpty else {
                completion(.skipped("\(visible.count) window(s) already visible"))
                return
            }

            let minimized = windowIndexes.filter { snapshots[$0].isRestoreCandidate }
            guard !minimized.isEmpty else {
                completion(.skipped("nothing minimized to restore"))
                return
            }

            // Everything standard is minimized — this is the case Cmd+Tab gets wrong.
            let targets = restoreAll ? minimized : [Self.preferredTarget(app: app, windows: windows, candidates: minimized)]
            let titles = targets.map { snapshots[$0].title ?? "(untitled)" }

            if dryRun {
                completion(.wouldRestore(titles))
                return
            }

            var restored: [String] = []
            for index in targets {
                if Self.deminiaturize(windows[index]) {
                    restored.append(snapshots[index].title ?? "(untitled)")
                }
            }

            // Note: macOS restores an app's minimized windows as a group. Writing
            // AXMinimized on one window brings back all of them, and so does pressing a
            // single window's Dock tile — verified on macOS 26 with TextEdit and
            // Finder. Putting the siblings back down was tried and does not work: the
            // re-minimize is overridden by the restore animation still in flight, and
            // making it stick would mean windows visibly popping up and sinking again.
            // So `restoreAll` controls only how many windows this app writes to; the
            // number that actually appears is the operating system's decision.

            completion(restored.isEmpty
                       ? .failed("AXMinimized stayed true for \(titles.joined(separator: ", "))")
                       : .restored(restored))
        }
    }

    /// `giveUpReason` nil means running out of attempts is not a failure — it is an app
    /// with no windows, which is a perfectly normal thing to Cmd+Tab to.
    private func retry(pid: pid_t, step: Int, restoreAll: Bool, dryRun: Bool,
                       giveUpReason: String?, completion: @escaping @Sendable (Outcome) -> Void) {
        let next = step + 1
        guard next < Self.ladder.count else {
            completion(giveUpReason.map { Outcome.failed($0) } ?? .skipped("app has no windows"))
            return
        }
        let delay = Self.ladder[next] - Self.ladder[step]
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            attempt(pid: pid, step: next, restoreAll: restoreAll, dryRun: dryRun, completion: completion)
        }
    }

    // MARK: - Window work

    private static func snapshot(index: Int, window: AXUIElement) -> WindowSnapshot {
        WindowSnapshot(
            index: index,
            title: try? AX.copyValue(window, kAXTitleAttribute as String, as: String.self).get(),
            role: try? AX.copyValue(window, kAXRoleAttribute as String, as: String.self).get(),
            subrole: try? AX.copyValue(window, kAXSubroleAttribute as String, as: String.self).get(),
            isMinimized: (try? AX.copyValue(window, kAXMinimizedAttribute as String, as: Bool.self).get()) ?? false
        )
    }

    /// The app's own main window if it is among the minimized candidates, otherwise the
    /// first — AX returns windows front-to-back, so index 0 is the most recently fronted.
    private static func preferredTarget(app: AXUIElement, windows: [AXUIElement], candidates: [Int]) -> Int {
        if let main = try? AX.copyValue(app, kAXMainWindowAttribute as String, as: AXUIElement.self).get(),
           let match = candidates.first(where: { CFEqual(windows[$0], main) }) {
            return match
        }
        return candidates[0]
    }

    /// Unminimize, confirm, then raise. Returns whether the window actually came back.
    private static func deminiaturize(_ window: AXUIElement) -> Bool {
        AX.setValue(window, kAXMinimizedAttribute as String, kCFBooleanFalse)

        var stillMinimized = (try? AX.copyValue(window, kAXMinimizedAttribute as String, as: Bool.self).get()) ?? false
        if stillMinimized {
            // One app-paced retry; some apps animate the dock genie before updating.
            Thread.sleep(forTimeInterval: 0.05)
            AX.setValue(window, kAXMinimizedAttribute as String, kCFBooleanFalse)
            stillMinimized = (try? AX.copyValue(window, kAXMinimizedAttribute as String, as: Bool.self).get()) ?? false
        }
        guard !stillMinimized else { return false }

        AX.perform(window, kAXRaiseAction as String)
        AX.setValue(window, kAXMainAttribute as String, kCFBooleanTrue)  // best effort
        return true
    }

    // MARK: - Hung-app parking

    private func noteTimeout(pid: pid_t) {
        let strikes = (timeoutStrikes[pid] ?? 0) + 1
        timeoutStrikes[pid] = strikes
        if strikes >= 2 {
            parkedUntil[pid] = Date().addingTimeInterval(60)
            timeoutStrikes[pid] = 0
            Log.note(Log.ax, "pid \(pid): parked for 60s after repeated AX timeouts")
        }
    }

    private func clearTimeouts(pid: pid_t) {
        timeoutStrikes[pid] = nil
        parkedUntil[pid] = nil
    }
}
