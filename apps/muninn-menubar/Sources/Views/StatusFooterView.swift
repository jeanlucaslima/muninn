import SwiftUI

struct StatusFooterView: View {
    let totalCount: Int
    let daemonStatus: DaemonStatus

    var body: some View {
        HStack {
            switch daemonStatus {
            case .unavailable:
                Text("Offline")
                    .foregroundStyle(.red)
            case .paused:
                Text("\(totalCount) entries")
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("⏸ Paused")
                    .foregroundStyle(.orange)
            case .connected:
                Text("\(totalCount) entries")
                    .foregroundStyle(.secondary)
            case .unknown:
                Text("…")
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text("⌘⌥V")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
