import Foundation

func relativeTime(from date: Date) -> String {
    let seconds = Int(-date.timeIntervalSinceNow)

    if seconds < 5 { return "just now" }
    if seconds < 60 { return "\(seconds)s ago" }

    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m ago" }

    let hours = minutes / 60
    if hours < 24 { return "\(hours)h ago" }

    let days = hours / 24
    if days == 1 { return "yesterday" }
    if days < 7 { return "\(days)d ago" }

    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter.string(from: date)
}
