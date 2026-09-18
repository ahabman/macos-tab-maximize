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

    /// Sheets, palettes and dialogs are not what Cmd+Tab is meant to bring back.
    /// Some apps omit the subrole entirely; treat those as standard rather than
    /// silently ignoring the app.
    var isStandard: Bool {
        guard let subrole else { return true }
        return subrole == kAXStandardWindowSubrole as String
    }

    var label: String {
        let name = title.flatMap { $0.isEmpty ? nil : $0 } ?? "(untitled)"
        return "\(name)[\(subrole ?? "no-subrole")\(isMinimized ? ", minimized" : "")]"
    }
}

/// A cheap, permission-free second opinion from the window server, used to tell
/// "the AX window list is still warming up" apart from "this app genuinely has no
/// windows". Only PID, layer and onscreen are read — `kCGWindowName` would require
/// Screen Recording permission, and is not needed.
enum CGWindows {
    struct Summary: Sendable {
        let total: Int
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
