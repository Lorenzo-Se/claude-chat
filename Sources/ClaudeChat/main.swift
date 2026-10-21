import AppKit

// Writing to a pipe or socket whose reader is gone (claude CLI exited, browser host closed)
// must surface as an error, not terminate the app.
signal(SIGPIPE, SIG_IGN)

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.run()
}
