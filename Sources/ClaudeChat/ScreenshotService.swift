import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum ScreenshotError: LocalizedError {
    case permissionMissing
    case noDisplay
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionMissing:
            "Screen recording permission is missing. Enable Claude Chat in System Settings → Privacy & Security → Screen & System Audio Recording, then restart the app."
        case .noDisplay:
            "No display found for capture."
        case .cancelled:
            "Selection cancelled."
        case .failed(let detail):
            "Screenshot failed: \(detail)"
        }
    }
}

/// Captures at native (Retina) resolution via ScreenCaptureKit. Claude Chat's own windows are excluded.
@MainActor
final class ScreenshotService {
    private let regionSelector = RegionSelector()

    /// The display under the mouse pointer.
    func captureFullScreen() async throws -> String {
        try ensurePermission()
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else {
            throw ScreenshotError.noDisplay
        }
        return try await capture(screen: screen, rect: nil)
    }

    func captureRegion() async throws -> String {
        try ensurePermission()
        guard let selection = await regionSelector.select() else { throw ScreenshotError.cancelled }
        // Let the window server remove the overlay before capturing.
        try? await Task.sleep(for: .milliseconds(80))
        return try await capture(screen: selection.screen, rect: selection.rect)
    }

    private func ensurePermission() throws {
        if CGPreflightScreenCaptureAccess() { return }
        // Shows the system prompt once; afterwards macOS only allows enabling it in System Settings.
        if CGRequestScreenCaptureAccess() { return }
        throw ScreenshotError.permissionMissing
    }

    /// `rect` is in global AppKit coordinates (bottom-left origin) and lies on `screen`.
    private func capture(screen: NSScreen, rect: CGRect?) async throws -> String {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenshotError.permissionMissing
        }
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenshotError.noDisplay
        }

        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let scale = screen.backingScaleFactor
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.captureResolution = .best
        if let rect {
            // ScreenCaptureKit uses display-local points with a top-left origin.
            configuration.sourceRect = CGRect(
                x: rect.minX - screen.frame.minX,
                y: screen.frame.maxY - rect.maxY,
                width: rect.width,
                height: rect.height
            )
            configuration.width = Int(rect.width * scale)
            configuration.height = Int(rect.height * scale)
        } else {
            configuration.width = Int(screen.frame.width * scale)
            configuration.height = Int(screen.frame.height * scale)
        }

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw ScreenshotError.failed(error.localizedDescription)
        }
        return try savePNG(image)
    }

    private func savePNG(_ image: CGImage) throws -> String {
        let url: URL
        do {
            url = try AppPaths.screenshots.newFileURL(named: "screenshot.png")
        } catch {
            throw ScreenshotError.failed(error.localizedDescription)
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ScreenshotError.failed("Could not create PNG file.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotError.failed("Could not write PNG file.")
        }
        return url.path
    }
}

// MARK: - Region selection overlay

/// Dimmed overlay on every display; drag to select (like ⌘⇧4), ⎋ cancels.
@MainActor
final class RegionSelector {
    /// Created and consumed on the main actor only.
    struct Selection: @unchecked Sendable {
        let screen: NSScreen
        let rect: CGRect
    }

    private var windows: [OverlayWindow] = []
    private var continuation: CheckedContinuation<Selection?, Never>?
    private var previousApp: NSRunningApplication?

    func select() async -> Selection? {
        finish(nil)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            previousApp = NSWorkspace.shared.frontmostApplication
            // Key events (⎋) only reach the overlay while the app is active.
            NSApp.activate(ignoringOtherApps: true)
            windows = NSScreen.screens.map { screen in
                let window = OverlayWindow(screen: screen) { [weak self] rect in
                    self?.finish(rect.map { Selection(screen: screen, rect: $0) })
                }
                window.orderFrontRegardless()
                return window
            }
            let mouse = NSEvent.mouseLocation
            (windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first)?.makeKey()
        }
    }

    private func finish(_ selection: Selection?) {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        if let previousApp, previousApp != NSRunningApplication.current {
            previousApp.activate()
        }
        previousApp = nil
        continuation?.resume(returning: selection)
        continuation = nil
    }
}

private final class OverlayWindow: NSWindow {
    init(screen: NSScreen, onFinish: @escaping (CGRect?) -> Void) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        contentView = OverlayView(screenOrigin: screen.frame.origin, onFinish: onFinish)
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
}

private final class OverlayView: NSView {
    private let screenOrigin: CGPoint
    private let onFinish: (CGRect?) -> Void
    private var start: CGPoint?
    private var current: CGPoint?

    init(screenOrigin: CGPoint, onFinish: @escaping (CGRect?) -> Void) {
        self.screenOrigin = screenOrigin
        self.onFinish = onFinish
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish(nil) } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        onFinish(nil)
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish(nil)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard start != nil else { return }
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        let rect = Self.rect(from: start, to: convert(event.locationInWindow, from: nil)).intersection(bounds)
        self.start = nil
        guard rect.width >= 4, rect.height >= 4 else {
            onFinish(nil)
            return
        }
        onFinish(rect.offsetBy(dx: screenOrigin.x, dy: screenOrigin.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        guard let start, let current else { return }
        let selection = Self.rect(from: start, to: current)
        selection.fill(using: .clear)
        NSColor.systemBlue.setStroke()
        let border = NSBezierPath(rect: selection)
        border.lineWidth = 1.5
        border.stroke()

        let label = "\(Int(selection.width)) × \(Int(selection.height))" as NSString
        label.draw(at: NSPoint(x: selection.minX + 4, y: selection.maxY + 4), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
    }

    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
