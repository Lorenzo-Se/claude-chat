import AppKit
import ClaudeChatCore
import SwiftUI
import UniformTypeIdentifiers

struct MessageRow: View {
    let message: Message
    let isStreaming: Bool
    let speech: SpeechService

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantBubble
        case .system: systemNote
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(message.attachments, id: \.self) { AttachmentView(path: $0) }
                if !message.content.isEmpty {
                    Text(message.content)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if message.content.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, 4)
            } else {
                MarkdownView(markdown: message.content)
            }
            if !isStreaming, !message.content.isEmpty {
                HStack(spacing: 12) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.content, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy response")

                    Button {
                        speech.toggle(markdown: message.content, id: message.id)
                    } label: {
                        Image(systemName: speech.speakingID == message.id ? "stop.fill" : "speaker.wave.2")
                    }
                    .help(speech.speakingID == message.id ? "Stop speaking" : "Read aloud")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var systemNote: some View {
        Text(message.content)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
    }
}

struct MarkdownView: View {
    let markdown: String

    var body: some View {
        let blocks = MarkdownParser.blocks(from: markdown)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(InlineMarkdown.attributed(text))
                .font(level == 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, 4)
        case .paragraph(let text):
            Text(InlineMarkdown.attributed(text))
        case .listItem(let marker, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(InlineMarkdown.attributed(text))
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .quote(let text):
            Text(InlineMarkdown.attributed(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(.tertiary).frame(width: 3)
                }
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(InlineMarkdown.attributed(cell))
                                .fontWeight(index == 0 ? .semibold : .regular)
                        }
                    }
                }
            }
            .font(.callout)
        case .rule:
            Divider()
        }
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct AttachmentView: View {
    let path: String
    var maxImageHeight: CGFloat = 160

    var body: some View {
        Group {
            if let image = Thumbnails.image(for: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: maxImageHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .frame(width: 28, height: 28)
                    Text((path as NSString).lastPathComponent)
                        .font(.caption)
                        .lineLimit(2)
                }
                .padding(8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .onTapGesture(count: 2) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        .help(path)
    }
}

/// Decoded images are cached — the message list re-renders on every streamed update.
@MainActor
enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for path: String) -> NSImage? {
        guard let type = UTType(filenameExtension: (path as NSString).pathExtension), type.conforms(to: .image) else {
            return nil
        }
        if let cached = cache.object(forKey: path as NSString) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}
