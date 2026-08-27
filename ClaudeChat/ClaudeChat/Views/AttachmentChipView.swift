import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum AttachmentPresentation {
    static func icon(for path: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }

    static func isImage(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if let type = UTType(filenameExtension: ext) {
            return type.conforms(to: .image)
        }
        return false
    }

    static func displayName(for path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

struct AttachmentChipView: View {
    let path: String
    var maxImageHeight: CGFloat = 160

    var body: some View {
        if AttachmentPresentation.isImage(path: path), let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: maxImageHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            HStack(spacing: 8) {
                Image(nsImage: AttachmentPresentation.icon(for: path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)

                Text(AttachmentPresentation.displayName(for: path))
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
            .padding(8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
