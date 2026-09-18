import AppKit

let arguments = CommandLine.arguments

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    TabMaximize — restores a minimized window when you Cmd+Tab to an app.

      --verbose            mirror log lines to stderr
      --dump-ax [target]   print the AX window state of an app (pid, bundle id or name)
                           and exit; with no target, dumps every regular app
      --help               this message
    """)
    exit(0)
}

Log.mirrorToStderr = arguments.contains("--verbose") || arguments.contains("--dump-ax")

if let index = arguments.firstIndex(of: "--restore-ax") {
    let target = arguments.count > index + 1 ? arguments[index + 1] : nil
    Diagnostics.runRestoreAX(target: target,
                             raise: arguments.contains("raise"),
                             setMain: arguments.contains("main"))
}

if let index = arguments.firstIndex(of: "--dump-ax") {
    let target = arguments.count > index + 1 ? arguments[index + 1] : nil
    Diagnostics.runDumpAX(target: target)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
