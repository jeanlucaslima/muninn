import Foundation

func normalizePreview(_ content: String, maxWidth: Int = 60) -> String {
    let collapsed = content
        .split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace || $0.isNewline })
        .joined(separator: " ")

    if collapsed.isEmpty {
        return "(empty)"
    }

    if collapsed.count <= maxWidth {
        return collapsed
    }
    return String(collapsed.prefix(maxWidth - 1)) + "…"
}
