import Foundation
import os

/// Logging for TabMaximize.
///
/// Everything goes to the unified log under the bundle's subsystem, so it can be
/// watched with `make logs`. When the process is started with `--verbose` the same
/// lines are mirrored to stderr, which is the practical debug loop: run the bundled
/// binary straight from Terminal and watch decisions scroll by.
enum Log {
    static let subsystem = "com.bamf.tabmaximize"

    static let activation = Logger(subsystem: subsystem, category: "activation")
    static let ax = Logger(subsystem: subsystem, category: "ax")
    static let permission = Logger(subsystem: subsystem, category: "permission")

    /// Set once during startup, before any concurrency begins.
    nonisolated(unsafe) static var mirrorToStderr = false

    static func note(_ logger: Logger, _ message: String) {
        logger.notice("\(message, privacy: .public)")
        mirror(message)
    }

    static func debug(_ logger: Logger, _ message: String) {
        logger.debug("\(message, privacy: .public)")
        if verbose { mirror(message) }
    }

    static func error(_ logger: Logger, _ message: String) {
        logger.error("\(message, privacy: .public)")
        mirror(message)
    }

    /// Verbose gate for the noisy per-attempt lines. Read from UserDefaults directly
    /// rather than through Prefs because this is called off the main actor.
    private static var verbose: Bool {
        mirrorToStderr || UserDefaults.standard.bool(forKey: "verboseLogging")
    }

    private static func mirror(_ message: String) {
        guard mirrorToStderr else { return }
        FileHandle.standardError.write("\(stamp()) \(message)\n".data(using: .utf8)!)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static func stamp() -> String { formatter.string(from: Date()) }
}
