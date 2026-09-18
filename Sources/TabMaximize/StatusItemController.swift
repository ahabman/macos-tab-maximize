import AppKit

/// The whole UI: one menu bar item. The menu is rebuilt in `menuNeedsUpdate` so it
/// always reflects live state (permission, login item, breaker) without any observers.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let watcher: ActivationWatcher

    init(watcher: ActivationWatcher) {
        self.watcher = watcher
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
    }

    func updateIcon() {
        let trusted = PermissionManager.shared.isTrusted
        let symbol = !trusted ? "exclamationmark.triangle"
            : (Prefs.enabled ? "macwindow.on.rectangle" : "macwindow")
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TabMaximize")
        statusItem.button?.image?.isTemplate = true
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(header(statusLine()))
        menu.addItem(.separator())

        if !PermissionManager.shared.isTrusted {
            menu.addItem(action("Grant Accessibility Access…", #selector(grantAccess)))
            menu.addItem(.separator())
        }

        menu.addItem(toggle("Enabled", #selector(toggleEnabled), on: Prefs.enabled))
        menu.addItem(toggle("Only After Cmd+Tab", #selector(toggleRequireCmdTab), on: Prefs.requireCmdTab))
        let restoreAll = toggle("Restore All Minimized Windows", #selector(toggleRestoreAll), on: Prefs.restoreAllWindows)
        restoreAll.toolTip = "macOS restores an app's minimized windows as a group, so for most apps "
            + "they all come back either way. This only changes how many windows TabMaximize itself acts on."
        menu.addItem(restoreAll)
        menu.addItem(.separator())

        menu.addItem(toggle("Launch at Login", #selector(toggleLoginItem), on: LoginItem.isEnabled))
        menu.addItem(action("Open Accessibility Settings…", #selector(openAccessibilitySettings)))
        menu.addItem(.separator())

        let tapItem = toggle("Cmd+Tab Event Tap (Input Monitoring)", #selector(toggleEventTap), on: Prefs.useEventTap)
        tapItem.toolTip = "Only needed if plain Cmd+Tab switches are being missed."
        menu.addItem(tapItem)
        menu.addItem(toggle("Dry Run (log only)", #selector(toggleDryRun), on: Prefs.dryRun))
        menu.addItem(toggle("Verbose Logging", #selector(toggleVerbose), on: Prefs.verboseLogging))
        menu.addItem(.separator())

        let quit = action("Quit TabMaximize", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func statusLine() -> String {
        if !PermissionManager.shared.isTrusted { return "Accessibility permission needed" }
        if Date() < watcher.breakerTrippedUntil { return "Paused — too many restores" }
        if !Prefs.enabled { return "TabMaximize — off" }
        if Prefs.dryRun { return "TabMaximize — dry run" }
        return "TabMaximize — active"
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func toggle(_ title: String, _ selector: Selector, on: Bool) -> NSMenuItem {
        let item = action(title, selector)
        item.state = on ? .on : .off
        return item
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        Prefs.enabled.toggle()
        updateIcon()
    }

    @objc private func toggleRequireCmdTab() {
        Prefs.requireCmdTab.toggle()
    }

    @objc private func toggleRestoreAll() {
        Prefs.restoreAllWindows.toggle()
    }

    @objc private func toggleDryRun() {
        Prefs.dryRun.toggle()
    }

    @objc private func toggleVerbose() {
        Prefs.verboseLogging.toggle()
    }

    @objc private func toggleEventTap() {
        Prefs.useEventTap.toggle()
        if Prefs.useEventTap {
            if !SwitcherMonitor.shared.start() {
                alert("Input Monitoring required",
                      "Grant TabMaximize access under System Settings › Privacy & Security › Input Monitoring, then toggle this again.")
                Prefs.useEventTap = false
            }
        } else {
            SwitcherMonitor.shared.stop()
        }
    }

    @objc private func toggleLoginItem() {
        if let hint = LoginItem.setEnabled(!LoginItem.isEnabled) {
            alert("Login item could not be changed", hint)
        }
    }

    @objc private func grantAccess() {
        if !PermissionManager.shared.refresh(prompt: true) {
            PermissionManager.shared.openSettings()
        }
    }

    @objc private func openAccessibilitySettings() {
        PermissionManager.shared.openSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
