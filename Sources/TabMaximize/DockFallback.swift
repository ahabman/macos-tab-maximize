import AppKit
import ApplicationServices

/// Restoring a window by writing AXMinimized brings back *every* minimized window of
/// that app — verified on macOS 26 with both TextEdit and Finder, and true even for a
/// bare write with no raise and no main. Each minimized window also has its own tile in
/// the Dock, and pressing that tile is how a person restores exactly one, so this goes
/// through the Dock instead when only one window is wanted.
///
/// Every function here must be called on AXWorker's queue; AXUIElement values do not
/// escape this file.
enum DockFallback {
    struct Item {
        let title: String
        let element: AXUIElement
    }

    static func minimizedItems() -> [Item] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return []
        }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AX.setTimeout(app, 1.0)
        var found: [Item] = []
        collect(from: app, depth: 0, into: &found)
        return found
    }

    /// Presses the tile for `title`. Returns false if no such tile exists.
    static func press(title: String) -> Bool {
        guard let item = minimizedItems().first(where: { $0.title == title }) else { return false }
        return AX.perform(item.element, kAXPressAction as String) == .success
    }

    /// The Dock's tiles live under an AXList; the hierarchy is shallow, so a
    /// depth-limited walk is enough and avoids assuming an exact shape.
    private static func collect(from element: AXUIElement, depth: Int, into found: inout [Item]) {
        guard depth < 4 else { return }
        guard let children = try? AX.copyValue(element, kAXChildrenAttribute as String, as: [AXUIElement].self).get() else {
            return
        }
        for child in children {
            let subrole = try? AX.copyValue(child, kAXSubroleAttribute as String, as: String.self).get()
            if subrole == kAXMinimizedWindowDockItemSubrole as String {
                let title = (try? AX.copyValue(child, kAXTitleAttribute as String, as: String.self).get()) ?? ""
                found.append(Item(title: title, element: child))
            } else {
                collect(from: child, depth: depth + 1, into: &found)
            }
        }
    }
}
