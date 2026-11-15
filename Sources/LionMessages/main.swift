import AppKit

// Lion Messages: a personal Messages client dressed as a Mac OS X Lion (10.7) app.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(options: LaunchOptions.parse(CommandLine.arguments))
    app.delegate = delegate
    app.run()
}
