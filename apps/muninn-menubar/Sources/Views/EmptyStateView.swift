import SwiftUI

struct EmptyStateView: View {
    let daemonStatus: DaemonStatus
    let searchText: String
    let entryCount: Int

    var body: some View {
        VStack(spacing: 4) {
            switch daemonStatus {
            case .unavailable:
                Text("Cannot connect to muninnd")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("Start with: muninnd run")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            default:
                if !searchText.isEmpty {
                    Text("No matches for '\(searchText)'")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    Text("No clipboard history yet")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
