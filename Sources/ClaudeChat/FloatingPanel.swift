import AppKit
import SwiftUI

/// The chat input registers itself here so the panel can put the cursor into it whenever it is shown.
@MainActor
final class InputFocus {
    weak var textView: NSTextView?

    func focus() {
        guard let textView, let window = textView.window, window.isVisible else { return }
        if window.firstResponder !== textView {
            window.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        }
    }
}

/// Non-activating panel: typing into it does not pull the user's app out of focus.
final class FloatingPanel: NSPanel {
    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 620),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        // Shown on whichever Space is active, including over full-screen apps.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        minSize = NSSize(width: 360, height: 420)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        self.contentView = contentView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let panel: FloatingPanel
    private let focus: InputFocus
    /// Incremented by every show/hide so a finishing fade-out never hides a panel that was shown again.
    private var transition = 0
    /// False until the panel has a saved or user-chosen frame; the first show then centers it.
    private var hasPlacement: Bool

    private static let frameKey = "ClaudeChatFloatingPanel"

    init(rootView: some View, focus: InputFocus) {
        self.focus = focus

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        panel = FloatingPanel(contentView: effect)
        hasPlacement = panel.setFrameUsingName(Self.frameKey)
        super.init()
        panel.delegate = self
    }

    var isVisible: Bool { panel.isVisible && panel.alphaValue > 0 }

    func toggle() {
        // Visible but unfocused or on another display → bring it here and focus instead of hiding.
        if isVisible, panel.isKeyWindow, panel.screen == Self.screenUnderMouse {
            hide()
        } else {
            show()
        }
    }

    func show() {
        transition += 1
        moveOntoActiveScreen()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        } else {
            // Replaces a running fade-out; a plain `alphaValue = 1` would be overridden by it.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
            }
        }
        panel.makeKeyAndOrderFront(nil)
        focus.focus()
        // On first show SwiftUI creates the text view during the next layout pass.
        DispatchQueue.main.async { [focus] in focus.focus() }
    }

    func hide() {
        guard panel.isVisible else { return }
        transition += 1
        let current = transition
        panel.saveFrame(usingName: Self.frameKey)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.transition == current else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        })
    }

    // MARK: - Placement

    private static var screenUnderMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// Puts the panel on the display the user is working on, fully inside its visible area.
    /// The saved frame may belong to a display that is gone or arranged differently.
    private func moveOntoActiveScreen() {
        guard let target = Self.screenUnderMouse else { return }
        let visible = target.visibleFrame
        var frame = panel.frame

        if !hasPlacement {
            hasPlacement = true
            frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
            panel.setFrame(frame, display: false)
            return
        }

        if panel.screen != target || !visible.contains(frame) {
            if let source = panel.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) }), source != target {
                // Keep the same relative position the panel had on its previous display.
                let from = source.visibleFrame
                let relativeX = (frame.minX - from.minX) / max(from.width - frame.width, 1)
                let relativeY = (frame.minY - from.minY) / max(from.height - frame.height, 1)
                frame.origin.x = visible.minX + relativeX * (visible.width - frame.width)
                frame.origin.y = visible.minY + relativeY * (visible.height - frame.height)
            } else if !visible.intersects(frame) {
                frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
            }
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            panel.setFrame(frame, display: false)
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if panel.firstResponder === panel || panel.firstResponder == nil {
            focus.focus()
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        panel.saveFrame(usingName: Self.frameKey)
    }

    func windowDidMove(_ notification: Notification) {
        panel.saveFrame(usingName: Self.frameKey)
    }
}
