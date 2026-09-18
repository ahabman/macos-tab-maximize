import AppKit
import ApplicationServices

/// Accessibility trust: check, prompt, and notice when it comes back.
///
/// There is no notification for a TCC change, so the only way to notice a grant is to
/// poll — but only while untrusted, and the timer is torn down the moment it flips.
@MainActor
final class PermissionManager {
    static let shared = PermissionManager()

    private(set) var isTrusted = false
    private var timer: Timer?

    var onChange: ((Bool) -> Void)?

    /// `prompt: true` shows the system dialog, but only the first time the app is seen;
    /// afterwards it silently returns false, which is why the menu also offers a link.
    @discardableResult
    func refresh(prompt: Bool = false) -> Bool {
        let trusted: Bool
        if prompt {
            // The imported `kAXTrustedCheckOptionPrompt` global is not concurrency-safe
            // under Swift 6, so the key is spelled out.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(options)
        } else {
            trusted = AXIsProcessTrusted()
        }

        if trusted != isTrusted {
            isTrusted = trusted
            Log.note(Log.permission, "accessibility trust: \(trusted ? "granted" : "missing")")
            onChange?(trusted)
        }
        trusted ? stopPolling() : startPolling()
        return trusted
    }

    func openSettings() {
        let anchored = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        if !NSWorkspace.shared.open(anchored) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
        }
    }

    private func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in _ = self.refresh() }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}
