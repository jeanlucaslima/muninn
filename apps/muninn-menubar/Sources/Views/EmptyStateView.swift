import SwiftUI

struct EmptyStateView: View {
    let daemonStatus: DaemonStatus
    let searchText: String
    let entryCount: Int

    var body: some View {
        VStack(spacing: 4) {
            switch daemonStatus {
            case .unavailable:
                Text("Offline")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
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
