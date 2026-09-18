import ApplicationServices
import CoreGraphics
import Foundation

/// A Sendable description of one window. `AXUIElement` itself is not Sendable and
/// never leaves AXWorker — this is what crosses back to the main actor.
struct WindowSnapshot: Sendable {
    let index: Int
    let title: String?
    let role: String?
    let subrole: String?
    let isMinimized: Bool

    /// kAXWindows is not purely windows: Finder reports its desktop as an
    /// AXScrollArea in the same list, and counting that as a visible window would mean
    /// Finder's minimized windows never came back.
    var isWindow: Bool {
        role == kAXWindowRole as String
    }

    /// Anything minimized is worth restoring, regardless of subrole.
    ///
    /// The subrole cannot be trusted here: AppKit reports a plain document window as
    /// AXStandardWindow while it is on screen and as **AXDialog** once it is minimized
    /// — verified on macOS 26 with TextEdit and Finder. Filtering minimized windows by
    /// subrole would reject exactly the windows this app exists to bring back.
    var isRestoreCandidate: Bool {
        isWindow && isMinimized
    }

    /// A window that means the user can already see something, so nothing should be
    /// restored. Sheets, palettes and dialogs do not count — only real windows do, and
    /// their subrole is reliable because they are on screen.
    var isVisibleWindow: Bool {
        guard isWindow, !isMinimized else { return false }
        guard let subrole else { return true }
        return subrole == kAXStandardWindowSubrole as String
    }

    var label: String {
        let name = title.flatMap { $0.isEmpty ? nil : $0 } ?? "(untitled)"
        return "\(name)[\(role ?? "?")/\(subrole ?? "no-subrole")\(isMinimized ? ", minimized" : "")]"
    }
}

/// A cheap, permission-free second opinion from the window server.
///
/// Only `onscreen` is trustworthy. The total is not a window count: AppKit keeps
/// offscreen backing windows around for menu bars and toolbars (3360x30 and 2056x39
/// strips were observed for a TextEdit with no documents open at all), and they sit at
/// layer 0 like real windows. Treating the total as "this app has windows" made
/// windowless apps look like they had nine of them.
///
/// Only PID, layer and onscreen are read — `kCGWindowName` would require Screen
/// Recording permission, and is not needed.
enum CGWindows {
    struct Summary: Sendable {
        /// Includes offscreen backing windows — do not treat this as a window count.
        let total: Int
        /// Windows actually being displayed. Zero for an app whose windows are all
        /// minimized, which is the case this app cares about.
        let onscreen: Int
    }

    static func summary(pid: pid_t) -> Summary {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return Summary(total: 0, onscreen: 0)
        }
        var total = 0
        var onscreen = 0
        for info in infos {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            total += 1
            if let visible = info[kCGWindowIsOnscreen as String] as? Bool, visible { onscreen += 1 }
        }
        return Summary(total: total, onscreen: onscreen)
    }
}
