import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let watcher = ActivationWatcher()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()

        // Keeps one unresponsive app from stalling the AX queue for seconds.
        AX.setProcessWideTimeout(0.25)

        statusItem = StatusItemController(watcher: watcher)

        PermissionManager.shared.onChange = { [weak self] trusted in
            self?.statusItem?.updateIcon()
            if trusted { self?.watcher.start() } else { self?.watcher.stop() }
        }
        watcher.onPermissionLost = {
            _ = PermissionManager.shared.refresh()
        }

        if PermissionManager.shared.refresh(prompt: true) {
            watcher.start()
        } else {
            Log.note(Log.permission, "waiting for accessibility permission before watching activations")
        }

        if Prefs.useEventTap {
            SwitcherMonitor.shared.start()
        }

        // Re-check on return from System Settings.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in _ = PermissionManager.shared.refresh() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
        SwitcherMonitor.shared.stop()
    }
}
