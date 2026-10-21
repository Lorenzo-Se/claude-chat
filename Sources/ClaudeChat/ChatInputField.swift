import AppKit
import SwiftUI

/// Multi-line input backed by NSTextView: ↩ sends, ⇧↩ inserts a newline, ⎋ hides the panel.
/// Grows with its content up to `maxHeight`, then scrolls. It registers with `InputFocus`
/// so the panel can place the cursor here reliably.
struct ChatInputField: View {
    @Binding var text: String
    let focus: InputFocus
    var placeholder: String
    var onSubmit: () -> Void
    var onEscape: () -> Void

    static let minHeight: CGFloat = 22
    static let maxHeight: CGFloat = 160

    // SwiftUI does not re-ask an NSViewRepresentable for its size when the text changes,
    // so the text view measures itself and drives an explicit height.
    @State private var height = ChatInputField.minHeight

    var body: some View {
        InputTextRepresentable(
            text: $text,
            height: $height,
            focus: focus,
            placeholder: placeholder,
            onSubmit: onSubmit,
            onEscape: onEscape
        )
        .frame(height: height)
    }
}

private struct InputTextRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let focus: InputFocus
    var placeholder: String
    var onSubmit: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = InputTextView()
        textView.delegate = context.coordinator
        textView.placeholder = placeholder
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.textContainer?.lineFragmentPadding = 2
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        // Wrapping changes when the panel is resized.
        scrollView.contentView.postsFrameChangedNotifications = true
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak coordinator = context.coordinator, weak textView] _ in
            // Deferred so the text view has picked up the new width first.
            DispatchQueue.main.async {
                if let textView { coordinator?.updateHeight(of: textView) }
            }
        }

        focus.textView = textView
        context.coordinator.updateHeight(of: textView)
        return scrollView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.frameObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? InputTextView else { return }
        focus.textView = textView
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            textView.needsDisplay = true
            context.coordinator.updateHeight(of: textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InputTextRepresentable
        var frameObserver: NSObjectProtocol?

        init(parent: InputTextRepresentable) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            updateHeight(of: textView)
        }

        /// Measures the laid-out text and publishes the clamped height.
        func updateHeight(of textView: NSTextView) {
            // Before the first layout the text view has no width and every glyph would wrap.
            guard textView.bounds.width > 20,
                  let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: NSFont.systemFontSize))
            let content = max(layoutManager.usedRect(for: container).height, lineHeight) + textView.textContainerInset.height * 2
            let clamped = min(max(ceil(content), ChatInputField.minHeight), ChatInputField.maxHeight)
            guard abs(clamped - parent.height) > 0.5 else { return }
            // Deferred: this can run while SwiftUI is updating the view, where state must not change.
            DispatchQueue.main.async { [self] in
                parent.height = clamped
                textView.scrollRangeToVisible(textView.selectedRange())
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Composing (dead keys, IME): ↩ confirms the composition and must not send.
                if textView.hasMarkedText() || NSEvent.modifierFlags.contains(.shift) { return false }
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if textView.hasMarkedText() { return false }
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }
}

final class InputTextView: NSTextView {
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerInset.height
        )
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }

    /// SwiftUI may create the field after the panel became key; take focus once attached.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, window.isKeyWindow, window.firstResponder === window {
            window.makeFirstResponder(self)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
