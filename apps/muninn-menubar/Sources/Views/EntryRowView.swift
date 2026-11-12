import SwiftUI
import MuninnCore

struct EntryRowView: View {
    let entry: ItemSummary
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
            }

            Spacer()

            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
    }

    private var title: String {
        if let preview = entry.preview, !preview.isEmpty {
            return normalizePreview(preview)
        }
        switch entry.kind {
        case .image: return "Image"
        case .pdf: return "PDF"
        case .richText: return "Rich text"
        case .html: return "Web content"
        case .file: return "File"
        case .text, .other: return "(empty)"
        }
    }

    private var subtitle: String {
        var parts = [relativeTime(from: entry.lastCapturedAt)]
        if let app = entry.sourceAppName { parts.append(app) }
        if entry.kind != .text, let bytes = entry.byteSize {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }
}
