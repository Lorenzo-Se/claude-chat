import ClaudeChatCore
import SwiftUI

struct ChatView: View {
    @Bindable var controller: ChatController
    let speech: SpeechService
    let focus: InputFocus
    var onHide: () -> Void

    @AppStorage("showsConversationList") private var showsSidebar = false
    @State private var renaming: ConversationIndexEntry?
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 0) {
            if showsSidebar {
                sidebar
                    .frame(width: 180)
                Divider()
            }
            VStack(spacing: 0) {
                header
                Divider()
                messages
                Divider()
                inputArea
            }
        }
        .frame(minWidth: showsSidebar ? 540 : 360, minHeight: 420)
        .alert("Rename conversation", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let renaming { controller.rename(renaming.id, to: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { controller.activeID }, set: { if let id = $0 { controller.select(id) } })) {
            ForEach(controller.index) { entry in
                HStack(spacing: 6) {
                    Text(entry.title)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if controller.isRunning(entry.id) {
                        ProgressView().controlSize(.mini)
                    }
                }
                .tag(entry.id)
                .contextMenu {
                    Button("Rename…") {
                        renameText = entry.title
                        renaming = entry
                    }
                    Button("Delete", role: .destructive) { controller.delete(entry.id) }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                showsSidebar.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help(showsSidebar ? "Hide conversations" : "Show conversations")

            Text(controller.active.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if let saveError = controller.saveError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(saveError)
            }

            if speech.isSpeaking {
                Button {
                    speech.stop()
                } label: {
                    Image(systemName: "speaker.slash.fill")
                }
                .help("Stop speaking")
            }

            if controller.isRunning(controller.activeID) {
                ProgressView().controlSize(.small)
            }

            Button {
                controller.newConversation()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .help("New conversation")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Messages

    private var messages: some View {
        let conversation = controller.active
        let streamingID = controller.streamingMessageIDs[conversation.id]
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if conversation.messages.isEmpty {
                        Text("Ask Claude anything…")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    }
                    ForEach(conversation.messages) { message in
                        MessageRow(message: message, isStreaming: message.id == streamingID, speech: speech)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(14)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: conversation.messages.last?.content) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            .onChange(of: conversation.messages.count) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            .onChange(of: conversation.id) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        }
    }

    private static let bottomID = "bottom"

    // MARK: - Input

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !controller.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(controller.pendingAttachments, id: \.self) { path in
                            AttachmentView(path: path, maxImageHeight: 64)
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        controller.removePendingAttachment(path)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 6, y: -6)
                                    .help("Remove attachment")
                                }
                        }
                    }
                    .padding(.top, 6)
                    .padding(.trailing, 6)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                ChatInputField(
                    text: $controller.input,
                    focus: focus,
                    placeholder: "Message Claude…",
                    onSubmit: { controller.sendInput() },
                    onEscape: onHide
                )

                if controller.isRunning(controller.activeID) {
                    Button {
                        controller.stop(controller.activeID)
                    } label: {
                        Image(systemName: "stop.circle.fill").font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop response")
                } else {
                    Button {
                        controller.sendInput()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!controller.canSend)
                    .help("Send (↩)")
                }
            }
        }
        .padding(12)
    }
}
