import SwiftUI

struct NavigationSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var provider: MapNavigationProvider
    @State private var query = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextField("Nhập điểm đến", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)
                    .onChange(of: query) { value in
                        provider.search(query: value)
                    }

                if provider.searchResults.isEmpty {
                    Spacer()
                    Text(provider.status)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    List(provider.searchResults) { result in
                        Button {
                            provider.startNavigation(to: result)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.name).font(.headline)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Dẫn đường")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
    }
}
