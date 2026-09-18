import AppKit
import CoreGraphics
import Foundation

/// Watches for apps becoming frontmost and, when the switch looks like a Cmd+Tab to an
/// app whose windows are all minimized, asks AXWorker to bring one back.
@MainActor
final class ActivationWatcher {
    /// How long after a Cmd+Tab keystroke an activation still counts as caused by it.
    private static let switcherWindow: TimeInterval = 0.75
    /// Never act on the same app twice in quick succession, whatever the cause.
    private static let perAppCooldown: TimeInterval = 1.5
    /// Circuit breaker: more than this many restores inside `breakerWindow` means
    /// something is looping, so stand down.
    private static let breakerLimit = 8
    private static let breakerWindow: TimeInterval = 5
    private static let breakerCooldown: TimeInterval = 30

    private var observer: NSObjectProtocol?
    private var suppressedPID: pid_t?
    private var suppressUntil = Date.distantPast
    private var inFlight: Set<pid_t> = []
    private var lastActedAt: [pid_t: Date] = [:]
    private var recentRestores: [Date] = []
    private(set) var breakerTrippedUntil = Date.distantPast

    var onPermissionLost: (() -> Void)?

    var isRunning: Bool { observer != nil }

    private struct AppInfo: Sendable {
        let pid: pid_t
        let bundleID: String?
        let name: String
        let isRegular: Bool
    }

    /// Evidence about *how* the switch was made, sampled at the instant of activation.
    ///
    /// Command is already released by the time the notification arrives — the switcher
    /// commits on release — so asking whether it is held never works. What does survive
    /// is timing: a Cmd+Tab leaves a keystroke a fraction of a second in the past, while
    /// a Dock click leaves a mouse event as the most recent input. None of this needs a
    /// TCC grant; `CGEventSource` reports input recency, not input content.
    private struct InputEvidence: Sendable {
        let commandHeld: Bool
        let sinceKeyDown: CFTimeInterval
        let sinceFlagsChanged: CFTimeInterval
        let sinceMouseDown: CFTimeInterval

        static func sample() -> InputEvidence {
            func age(_ type: CGEventType) -> CFTimeInterval {
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
            }
            return InputEvidence(
                commandHeld: NSEvent.modifierFlags.contains(.command),
                sinceKeyDown: age(.keyDown),
                sinceFlagsChanged: age(.flagsChanged),
                sinceMouseDown: min(age(.leftMouseDown), age(.rightMouseDown))
            )
        }

        /// The keyboard was the most recent thing the user touched, and recently enough
        /// that this activation plausibly came from it.
        var looksKeyboardDriven: Bool {
            sinceKeyDown < 2.0 && sinceKeyDown < sinceMouseDown
        }

        var description: String {
            String(format: "command held: %@, since keyDown: %.2fs, flagsChanged: %.2fs, mouseDown: %.2fs",
                   commandHeld ? "true" : "false", sinceKeyDown, sinceFlagsChanged, sinceMouseDown)
        }
    }

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // Sample input state synchronously, before hopping actors — these are
            // "how long ago" readings and they age with every run loop turn.
            let evidence = InputEvidence.sample()
            let info = AppInfo(
                pid: app.processIdentifier,
                bundleID: app.bundleIdentifier,
                name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
                isRegular: app.activationPolicy == .regular
            )
            Task { @MainActor in
                self.handle(info, evidence: evidence)
            }
        }
        Log.note(Log.activation, "watching application activations")
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    // MARK: - Decision

    private func handle(_ info: AppInfo, evidence: InputEvidence) {
        let tapAge = SwitcherMonitor.shared.secondsSinceActivity
        Log.debug(Log.activation, "activated \(info.name) (pid \(info.pid)) — \(evidence.description), tap: \(tapAge.map { String(format: "%.2fs", $0) } ?? "n/a")")

        guard Prefs.enabled else { return }

        if Date() < breakerTrippedUntil {
            Log.debug(Log.activation, "\(info.name): circuit breaker is open, standing down")
            return
        }

        guard info.isRegular else { return }
        if info.pid == ProcessInfo.processInfo.processIdentifier { return }
        if let bundleID = info.bundleID,
           Prefs.builtInDenylist.contains(bundleID) || Prefs.ignoredBundleIDs.contains(bundleID) {
            return
        }

        // Guard against reacting to our own re-activation, and against stacking work.
        if let suppressedPID, suppressedPID == info.pid, Date() < suppressUntil {
            Log.debug(Log.activation, "\(info.name): suppressed (self-caused activation)")
            self.suppressedPID = nil
            return
        }
        if inFlight.contains(info.pid) { return }
        if let last = lastActedAt[info.pid], Date().timeIntervalSince(last) < Self.perAppCooldown {
            Log.debug(Log.activation, "\(info.name): within cooldown")
            return
        }

        if Prefs.requireCmdTab, !cameFromSwitcher(evidence: evidence) {
            Log.debug(Log.activation, "\(info.name): not a Cmd+Tab switch, ignoring")
            return
        }

        inFlight.insert(info.pid)
        let dryRun = Prefs.dryRun
        AXWorker.shared.restore(pid: info.pid, restoreAll: Prefs.restoreAllWindows, dryRun: dryRun) { outcome in
            Task { @MainActor in
                self.finish(info, outcome: outcome)
            }
        }
    }

    private func finish(_ info: AppInfo, outcome: Outcome) {
        inFlight.remove(info.pid)

        switch outcome {
        case .restored, .wouldRestore:
            Log.note(Log.activation, "\(info.name): \(outcome.description)")
        case .permissionLost:
            Log.error(Log.activation, "\(info.name): \(outcome.description)")
            onPermissionLost?()
            return
        case .failed(let why):
            Log.note(Log.activation, "\(info.name): failed — \(why)")
        case .skipped(let why):
            Log.debug(Log.activation, "\(info.name): skipped — \(why)")
        }

        guard outcome.didAct else { return }

        lastActedAt[info.pid] = Date()
        trackForBreaker()

        // Normally unnecessary: on the Cmd+Tab path the app is already frontmost, which
        // is the cheapest defence against a feedback loop there is.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != info.pid,
           let app = NSRunningApplication(processIdentifier: info.pid) {
            suppressedPID = info.pid
            suppressUntil = Date().addingTimeInterval(1.0)
            app.activate()
        }
    }

    /// Three tiers, cheapest first. The event tap is definitive but costs an Input
    /// Monitoring grant, so it is only consulted when it has been switched on.
    private func cameFromSwitcher(evidence: InputEvidence) -> Bool {
        if evidence.commandHeld { return true }
        if let age = SwitcherMonitor.shared.secondsSinceActivity, age < Self.switcherWindow { return true }
        if !SwitcherMonitor.shared.isRunning, evidence.looksKeyboardDriven { return true }
        return false
    }

    private func trackForBreaker() {
        let now = Date()
        recentRestores.append(now)
        recentRestores.removeAll { now.timeIntervalSince($0) > Self.breakerWindow }
        if recentRestores.count > Self.breakerLimit {
            breakerTrippedUntil = now.addingTimeInterval(Self.breakerCooldown)
            recentRestores.removeAll()
            Log.error(Log.activation, "circuit breaker tripped — \(Self.breakerLimit)+ restores in \(Int(Self.breakerWindow))s, pausing for \(Int(Self.breakerCooldown))s")
        }
    }
}
