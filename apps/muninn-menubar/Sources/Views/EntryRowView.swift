import SwiftUI
import MuninnCore

struct EntryRowView: View {
    let entry: ClipboardEntry
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(normalizePreview(entry.content))
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)

                Text(relativeTime(from: entry.createdAt))
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
}
