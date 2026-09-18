import AppKit
import CoreGraphics

/// Optional listen-only event tap that records when the Cmd+Tab switcher was last
/// driven.
///
/// Cmd+Tab is a system symbolic hotkey: WindowServer routes it to the Dock, and the
/// switcher holds a keyboard grab while it is up, so `NSEvent.addGlobalMonitorForEvents`
/// never sees it. A tap inserted at the head of the session tap runs before symbolic
/// hotkey dispatch, which is how switcher replacements observe (and swallow) the
/// keystroke. This one only listens; it never modifies or consumes anything.
///
/// It costs a second TCC grant — Input Monitoring — so it stays off unless the free
/// modifier-flag check in ActivationWatcher proves unreliable.
final class SwitcherMonitor: @unchecked Sendable {
    static let shared = SwitcherMonitor()

    private let lock = NSLock()
    private var _lastActivity: CFAbsoluteTime = 0
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// Seconds since the switcher was last driven, or nil if never.
    var secondsSinceActivity: TimeInterval? {
        let last = lock.withLock { _lastActivity }
        guard last > 0 else { return nil }
        return CFAbsoluteTimeGetCurrent() - last
    }

    var isRunning: Bool { lock.withLock { tap != nil } }

    func mark() {
        lock.withLock { _lastActivity = CFAbsoluteTimeGetCurrent() }
    }

    /// Returns false if Input Monitoring has not been granted (and asks for it), or if
    /// the tap could not be created.
    @discardableResult
    func start() -> Bool {
        if isRunning { return true }

        guard CGPreflightListenEventAccess() else {
            Log.note(Log.permission, "Input Monitoring not granted — requesting it for the Cmd+Tab event tap")
            CGRequestListenEventAccess()
            return false
        }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<SwitcherMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.error(Log.permission, "could not create the Cmd+Tab event tap")
            return false
        }

        let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)

        lock.withLock {
            tap = newTap
            source = newSource
        }
        Log.note(Log.permission, "Cmd+Tab event tap installed")
        return true
    }

    func stop() {
        let (oldTap, oldSource): (CFMachPort?, CFRunLoopSource?) = lock.withLock {
            let t = tap, s = source
            tap = nil
            source = nil
            return (t, s)
        }
        if let oldTap { CGEvent.tapEnable(tap: oldTap, enable: false) }
        if let oldSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), oldSource, .commonModes) }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // The system disables a tap that runs long or trips on user input; re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = lock.withLock({ self.tap }) {
                CGEvent.tapEnable(tap: tap, enable: true)
                Log.note(Log.permission, "event tap was disabled by the system — re-enabled")
            }
            return
        }

        guard type == .keyDown else { return }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == 48 else { return }  // kVK_Tab
        guard event.flags.contains(.maskCommand) else { return }
        mark()
    }
}
