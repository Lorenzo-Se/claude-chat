import SwiftUI

struct MessageBubbleView: View {
    let message: Message
    var isStreaming: Bool = false

    private var isUser: Bool { message.role == .user }
    private var isSystem: Bool { message.role == .system }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if isSystem {
                    Text(message.content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                } else if isUser {
                    VStack(alignment: .trailing, spacing: 8) {
                        if let path = message.attachmentPath {
                            attachmentThumbnail(path: path)
                        }

                        Text(message.content)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    HStack(alignment: .bottom, spacing: 4) {
                        if message.content.isEmpty && isStreaming {
                            Text("…")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        } else {
                            markdownText(message.content)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }

                        if isStreaming && !message.content.isEmpty {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
            }

            if !isUser && !isSystem { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder
    private func attachmentThumbnail(path: String) -> some View {
        if let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 160)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func markdownText(_ content: String) -> some View {
        let normalized = MessageMarkdownPreprocessor.prepareForDisplay(content)
        let paragraphs = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if paragraphs.count <= 1 {
            markdownBlock(normalized)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    markdownBlock(paragraph)
                }
            }
        }
    }

    @ViewBuilder
    private func markdownBlock(_ content: String) -> some View {
        if let attributed = try? AttributedString(markdown: content) {
            Text(attributed)
        } else {
            Text(content)
        }
    }
}
