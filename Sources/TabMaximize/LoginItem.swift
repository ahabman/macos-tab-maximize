import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService. Requires a signed bundle at a stable path —
/// running out of `.build/` is the usual reason registration fails.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .notRegistered: return "not registered"
        case .requiresApproval: return "needs approval in System Settings › Login Items"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }

    /// Returns nil on success, or a human-readable hint on failure.
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            let hint = "Login item \(enabled ? "registration" : "removal") failed: \(error.localizedDescription). "
                + "Run the app from /Applications and make sure the bundle is signed."
            Log.error(Log.permission, hint)
            return hint
        }
    }
}
