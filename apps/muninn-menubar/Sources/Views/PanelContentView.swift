import SwiftUI
import MuninnCore

struct PanelContentView: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $viewModel.searchText, keyDelegate: viewModel)
                .frame(height: 32)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            Divider()

            if viewModel.entries.isEmpty {
                EmptyStateView(
                    daemonStatus: viewModel.daemonStatus,
                    searchText: viewModel.searchText,
                    entryCount: viewModel.totalCount
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(viewModel.entries.enumerated()), id: \.element.id) { index, entry in
                                Button {
                                    viewModel.selectedIndex = index
                                    viewModel.copySelected()
                                    viewModel.requestClose?()
                                } label: {
                                    EntryRowView(
                                        entry: entry,
                                        isSelected: index == viewModel.selectedIndex
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(entry.id)
                            }
                        }
                    }
                    .onChange(of: viewModel.selectedIndex) { newIndex in
                        if let entry = viewModel.selectedEntry {
                            proxy.scrollTo(entry.id, anchor: .center)
                        }
                    }
                }
            }

            Divider()

            StatusFooterView(
                totalCount: viewModel.totalCount,
                daemonStatus: viewModel.daemonStatus
            )
        }
        .frame(width: 380, height: 420)
    }
}
