import AppKit
import ApplicationServices
import Foundation

/// `--dump-ax [pid | bundle-id | app name]` — prints what Accessibility reports for an
/// app's windows. This stands in for Accessibility Inspector (which ships with Xcode)
/// and answers the question the whole design rests on: does a minimized window still
/// appear in kAXWindows, with AXMinimized true?
///
/// With no argument, every regular running app is dumped.
///
/// Output goes to stdout *and* the unified log. That is not redundant: TCC attributes a
/// binary launched from a shell to the terminal, not to this bundle, so running the
/// executable directly only has Accessibility access if the terminal itself was granted
/// it. Launching through LaunchServices — `make dump`, which uses `open --args` — runs
/// as the app, where the grant applies, and the unified log is the only way to see what
/// it found.
enum Diagnostics {
    static func runDumpAX(target: String?) -> Never {
        guard AXIsProcessTrusted() else {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            let message = "Accessibility permission is required. Note that running this binary straight from a shell is attributed to the terminal, not to TabMaximize — use 'make dump TARGET=...' instead, which launches the app bundle."
            emit(message)
            FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
            exit(1)
        }

        let apps = resolve(target: target)
        guard !apps.isEmpty else {
            emit("No running application matched \(target ?? "(all)").")
            exit(1)
        }

        for app in apps {
            let pid = app.processIdentifier
            let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
            let cg = CGWindows.summary(pid: pid)

            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var result: ([WindowSnapshot], AXError?) = ([], nil)
            AXWorker.shared.dump(pid: pid) { snapshots, error in
                result = (snapshots, error)
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 5)

            let (snapshots, error) = result
            emit("\(name) — pid \(pid), bundle \(app.bundleIdentifier ?? "?")")
            emit("  window server: \(cg.total) window(s), \(cg.onscreen) onscreen")
            if let error {
                emit("  AX error: \(error.name)")
            } else if snapshots.isEmpty {
                emit("  AX: no windows reported")
            } else {
                for snapshot in snapshots {
                    emit("  [\(snapshot.index)] minimized=\(snapshot.isMinimized) role=\(snapshot.role ?? "?") subrole=\(snapshot.subrole ?? "(none)") window=\(snapshot.isWindow) candidate=\(snapshot.isRestoreCandidate) blocks=\(snapshot.isVisibleWindow) title=\(snapshot.title ?? "(untitled)")")
                }
            }
        }
        exit(0)
    }

    /// `--restore-ax <target> [raise] [main]` — performs just the chosen steps of the
    /// restore sequence on one window, to see what each one actually does.
    static func runRestoreAX(target: String?, raise: Bool, setMain: Bool) -> Never {
        guard AXIsProcessTrusted() else {
            emit("Accessibility permission is required (launch via 'make' targets, not directly from a shell).")
            exit(1)
        }
        guard let app = resolve(target: target).first else {
            emit("No running application matched \(target ?? "(none)").")
            exit(1)
        }
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var report = ""
        AXWorker.shared.restoreFirstMinimized(pid: app.processIdentifier, raise: raise, setMain: setMain) {
            report = $0
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        emit("\(app.localizedName ?? "?"): \(report)")
        exit(0)
    }

    private static func emit(_ line: String) {
        print(line)
        Log.ax.notice("dump: \(line, privacy: .public)")
    }

    private static func resolve(target: String?) -> [NSRunningApplication] {
        let running = NSWorkspace.shared.runningApplications
        guard let target else {
            return running.filter { $0.activationPolicy == .regular }
        }
        if let pid = pid_t(target) {
            return NSRunningApplication(processIdentifier: pid).map { [$0] } ?? []
        }
        let needle = target.lowercased()
        return running.filter {
            $0.bundleIdentifier?.lowercased() == needle || $0.localizedName?.lowercased() == needle
        }
    }
}
