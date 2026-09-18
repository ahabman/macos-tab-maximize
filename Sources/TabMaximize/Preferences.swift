import Foundation

/// Typed wrapper over UserDefaults. Deliberately thin — there is no preferences
/// window, only the status menu and `defaults write com.bamf.tabmaximize ...`.
@MainActor
enum Prefs {
    enum Key: String {
        case enabled
        case requireCmdTab
        case restoreAllWindows
        case verboseLogging
        case useEventTap
        case dryRun
        case ignoredBundleIDs
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.enabled.rawValue: true,
            Key.requireCmdTab.rawValue: true,
            Key.restoreAllWindows.rawValue: false,
            Key.verboseLogging.rawValue: false,
            Key.useEventTap.rawValue: false,
            Key.dryRun.rawValue: false,
            Key.ignoredBundleIDs.rawValue: [String](),
        ])
    }

    private static func bool(_ key: Key) -> Bool { UserDefaults.standard.bool(forKey: key.rawValue) }
    private static func set(_ key: Key, _ value: Bool) { UserDefaults.standard.set(value, forKey: key.rawValue) }

    static var enabled: Bool {
        get { bool(.enabled) } set { set(.enabled, newValue) }
    }
    /// Only act when the activation looks like it came from the Cmd+Tab switcher.
    static var requireCmdTab: Bool {
        get { bool(.requireCmdTab) } set { set(.requireCmdTab, newValue) }
    }
    static var restoreAllWindows: Bool {
        get { bool(.restoreAllWindows) } set { set(.restoreAllWindows, newValue) }
    }
    static var verboseLogging: Bool {
        get { bool(.verboseLogging) } set { set(.verboseLogging, newValue) }
    }
    /// Install the listen-only event tap (needs Input Monitoring). Only worth turning
    /// on if the free modifier-flag check turns out not to catch Cmd+Tab.
    static var useEventTap: Bool {
        get { bool(.useEventTap) } set { set(.useEventTap, newValue) }
    }
    /// Log what would happen without touching any window.
    static var dryRun: Bool {
        get { bool(.dryRun) } set { set(.dryRun, newValue) }
    }

    /// Apps never acted on, beyond the built-in denylist.
    static var ignoredBundleIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Key.ignoredBundleIDs.rawValue) ?? [])
    }

    static let builtInDenylist: Set<String> = [
        "com.apple.dock",
        "com.apple.loginwindow",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
        "com.apple.systemuiserver",
        "com.apple.WindowManager",
        "com.bamf.tabmaximize",
    ]
}
