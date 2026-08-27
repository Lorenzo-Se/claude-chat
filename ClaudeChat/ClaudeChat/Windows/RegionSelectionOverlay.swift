import AppKit

/// Transparentes Overlay über allen Displays für Bereichsauswahl (analog ⌘⇧4).
@MainActor
final class RegionSelectionController {
    private var overlayWindows: [RegionOverlayWindow] = []
    private var continuation: CheckedContinuation<CGRect?, Never>?

    func selectRegion() async -> CGRect? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            showOverlay()
        }
    }

    private func showOverlay() {
        overlayWindows = NSScreen.screens.map { screen in
            let window = RegionOverlayWindow(screen: screen) { [weak self] event in
                self?.handleOverlayEvent(event)
            }
            window.orderFrontRegardless()
            return window
        }
    }

    private func handleOverlayEvent(_ event: RegionOverlayEvent) {
        switch event {
        case .selected(let rect):
            finish(with: rect)
        case .cancelled:
            finish(with: nil)
        }
    }

    private func finish(with rect: CGRect?) {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows = []
        continuation?.resume(returning: rect)
        continuation = nil
    }
}

private enum RegionOverlayEvent {
    case selected(CGRect)
    case cancelled
}

private final class RegionOverlayWindow: NSWindow {
    private let overlayView: RegionOverlayView

    init(screen: NSScreen, onEvent: @escaping (RegionOverlayEvent) -> Void) {
        overlayView = RegionOverlayView(screen: screen, onEvent: onEvent)

        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true

        contentView = overlayView
    }
}

private final class RegionOverlayView: NSView {
    private let screen: NSScreen
    private let onEvent: (RegionOverlayEvent) -> Void

    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var isDragging = false

    init(screen: NSScreen, onEvent: @escaping (RegionOverlayEvent) -> Void) {
        self.screen = screen
        self.onEvent = onEvent
        super.init(frame: screen.frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onEvent(.cancelled)
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = event.locationInWindow
        startPoint = point
        currentPoint = point
        isDragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        currentPoint = event.locationInWindow
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging, let start = startPoint else { return }
        isDragging = false

        let end = event.locationInWindow
        let localRect = normalizedRect(from: start, to: end)

        guard localRect.width >= 4, localRect.height >= 4 else {
            onEvent(.cancelled)
            return
        }

        // Lokales Rechteck in globale Bildschirmkoordinaten (Unten-Links-Origin)
        let globalRect = CGRect(
            x: screen.frame.origin.x + localRect.origin.x,
            y: screen.frame.origin.y + localRect.origin.y,
            width: localRect.width,
            height: localRect.height
        )
        onEvent(.selected(globalRect))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.setFillColor(NSColor.black.withAlphaComponent(0.25).cgColor)
        context.fill(bounds)

        if let start = startPoint, let current = currentPoint {
            let selection = normalizedRect(from: start, to: current)

            context.clear(selection)
            context.setStrokeColor(NSColor.systemBlue.cgColor)
            context.setLineWidth(2)
            context.stroke(selection)

            let sizeText = "\(Int(selection.width)) × \(Int(selection.height))"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let text = NSAttributedString(string: sizeText, attributes: attributes)
            let textPoint = CGPoint(x: selection.minX + 4, y: selection.maxY - 18)
            text.draw(at: textPoint)
        }
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        let x = min(start.x, end.x)
        let y = min(start.y, end.y)
        let width = abs(end.x - start.x)
        let height = abs(end.y - start.y)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
