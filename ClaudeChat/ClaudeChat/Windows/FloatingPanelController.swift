import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    init(rootView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow

        setFrameAutosaveName("ClaudeChatFloatingPanel")
        self.contentView = rootView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingPanelController: ObservableObject {
    @Published private(set) var isVisible = false

    private var panel: FloatingPanel?
    private var localKeyMonitor: Any?
    private var rootView: AnyView
    private let settings: AppSettings

    var onToggleShortcut: (() -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?

    init<Content: View>(rootView: Content, settings: AppSettings = .shared) {
        self.rootView = AnyView(rootView)
        self.settings = settings
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if panel == nil {
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.translatesAutoresizingMaskIntoConstraints = false

            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false

            let effectView = NSVisualEffectView()
            effectView.material = .hudWindow
            effectView.state = .active
            effectView.blendingMode = .behindWindow
            effectView.wantsLayer = true
            effectView.layer?.cornerRadius = 12
            effectView.layer?.masksToBounds = true
            effectView.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(effectView)
            container.addSubview(hostingView)

            NSLayoutConstraint.activate([
                effectView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                effectView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                effectView.topAnchor.constraint(equalTo: container.topAnchor),
                effectView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

                hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: container.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])

            let panel = FloatingPanel(rootView: container)
            panel.delegate = PanelDelegate.shared
            panel.center()
            self.panel = panel
        }

        guard let panel else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.animator().alphaValue = 1
        }

        isVisible = true
        panel.makeKey()
        startLocalKeyMonitor()
        onVisibilityChanged?(true)
    }

    func hide() {
        guard let panel, isVisible else { return }

        stopLocalKeyMonitor()
        isVisible = false
        onVisibilityChanged?(false)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }

    func orderOutOnClose() {
        stopLocalKeyMonitor()
        isVisible = false
        onVisibilityChanged?(false)
    }

    private func startLocalKeyMonitor() {
        guard localKeyMonitor == nil else { return }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let combo = self.settings.combo(for: .toggleChat)
            guard combo.matches(event) else { return event }
            self.onToggleShortcut?()
            return nil
        }
    }

    private func stopLocalKeyMonitor() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }
}

private final class PanelDelegate: NSObject, NSWindowDelegate {
    static let shared = PanelDelegate()

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NotificationCenter.default.post(name: .floatingPanelDidClose, object: nil)
        return false
    }
}

extension Notification.Name {
    static let floatingPanelDidClose = Notification.Name("floatingPanelDidClose")
}
