import AppKit
import ApplicationServices
import Foundation

/// `--dump-ax [pid | bundle-id | app name]` — prints what Accessibility reports for an
/// app's windows. This stands in for Accessibility Inspector (which ships with Xcode)
/// and answers the question the whole design rests on: does a minimized window still
/// appear in kAXWindows, with AXMinimized true?
///
/// With no argument, every regular running app is dumped.
enum Diagnostics {
    static func runDumpAX(target: String?) -> Never {
        guard AXIsProcessTrusted() else {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            FileHandle.standardError.write("Accessibility permission is required. Grant it in System Settings › Privacy & Security › Accessibility, then re-run.\n".data(using: .utf8)!)
            exit(1)
        }

        let apps = resolve(target: target)
        guard !apps.isEmpty else {
            FileHandle.standardError.write("No running application matched \(target ?? "(all)").\n".data(using: .utf8)!)
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
            print("\(name) — pid \(pid), bundle \(app.bundleIdentifier ?? "?")")
            print("  window server: \(cg.total) window(s), \(cg.onscreen) onscreen")
            if let error {
                print("  AX error: \(error.name)")
            } else if snapshots.isEmpty {
                print("  AX: no windows reported")
            } else {
                for snapshot in snapshots {
                    print("  [\(snapshot.index)] minimized=\(snapshot.isMinimized) role=\(snapshot.role ?? "?") subrole=\(snapshot.subrole ?? "(none)") standard=\(snapshot.isStandard) title=\(snapshot.title ?? "(untitled)")")
                }
            }
            print("")
        }
        exit(0)
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
