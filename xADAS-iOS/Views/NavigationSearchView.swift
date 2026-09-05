import SwiftUI

struct NavigationSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var provider: MapNavigationProvider
    @StateObject private var destinationSearch = IvyDestinationSearch()
    @State private var query = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Số nhà, tên đường hoặc địa điểm", text: $query)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onChange(of: query) { text in destinationSearch.update(query: text, near: nil) }
                        .onSubmit { fallbackSearch() }
                    Button {
                        destinationSearch.toggleVoice { text in
                            query = text
                            destinationSearch.update(query: text, near: nil)
                        }
                    } label: {
                        Image(systemName: destinationSearch.isListening ? "waveform.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 27))
                            .foregroundStyle(destinationSearch.isListening ? .red : .blue)
                    }
                    .accessibilityLabel("Tìm điểm đến bằng giọng nói")
                    if !query.isEmpty {
                        Button {
                            query = ""
                            destinationSearch.update(query: "", near: nil)
                            provider.search(query: "")
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal)

                if destinationSearch.isListening {
                    Label("Đang nghe… hãy nói địa chỉ", systemImage: "mic.fill").font(.caption).foregroundStyle(.red)
                } else if let error = destinationSearch.speechError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                if !destinationSearch.suggestions.isEmpty {
                    List(destinationSearch.suggestions) { suggestion in
                        Button {
                            destinationSearch.resolve(suggestion) { result in
                                guard let result else { return }
                                DispatchQueue.main.async {
                                    provider.startNavigation(to: result)
                                    dismiss()
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.and.ellipse")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(suggestion.title).font(.headline).foregroundStyle(.primary)
                                    if !suggestion.subtitle.isEmpty { Text(suggestion.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                }
                                Spacer()
                            }.padding(.vertical, 3)
                        }
                    }.listStyle(.plain)
                } else if !provider.searchResults.isEmpty {
                    List(provider.searchResults) { result in
                        Button {
                            provider.startNavigation(to: result)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.name).font(.headline).foregroundStyle(.primary)
                                Text(result.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }.listStyle(.plain)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "map.fill").font(.system(size: 30)).foregroundStyle(.secondary)
                        Text("Gõ số nhà + tên đường").font(.headline)
                        Text("Ivy sẽ gợi ý ngay khi bạn gõ. Hoặc bấm micro và nói, ví dụ “157 Trần Hưng Đạo”.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 28)
                        Button("Tìm bằng OSM nếu chưa thấy") { fallbackSearch() }
                            .buttonStyle(.bordered)
                            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Chọn điểm đến")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Đóng") { destinationSearch.stopVoice(); dismiss() } } }
            .onDisappear { destinationSearch.stopVoice() }
        }
    }

    private func fallbackSearch() { provider.search(query: query) }
}
