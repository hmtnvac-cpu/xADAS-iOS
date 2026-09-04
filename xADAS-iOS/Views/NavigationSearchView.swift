import SwiftUI

struct NavigationSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var provider: MapNavigationProvider
    @State private var query = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Nhập tên địa điểm hoặc địa chỉ", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { runSearch() }
                    Button("Tìm") { runSearch() }
                        .buttonStyle(.borderedProminent)
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                    if !query.isEmpty {
                        Button {
                            query = ""
                            provider.search(query: "")
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal)

                if provider.searchResults.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "map.fill").font(.system(size: 32, weight: .semibold)).foregroundStyle(.secondary)
                        Text(provider.status.contains("SEARCHING") ? "Đang tìm…" : "Tìm điểm đến bằng OpenStreetMap").font(.headline)
                        Text(statusText).font(.subheadline).foregroundStyle(provider.status.contains("ERROR") ? .red : .secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
                        Text("© OpenStreetMap contributors").font(.caption2).foregroundStyle(.tertiary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(provider.searchResults) { result in
                        Button {
                            provider.startNavigation(to: result)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.circle.fill").font(.title3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.name).font(.headline).foregroundStyle(.primary)
                                    Text(result.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                            }.padding(.vertical, 4)
                        }
                    }.listStyle(.plain)
                }
            }
            .navigationTitle("Chọn điểm đến")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } } }
        }
    }

    private func runSearch() { provider.search(query: query) }

    private var statusText: String {
        if provider.status.contains("SEARCH ERROR") { return "Không thể tải kết quả. Kiểm tra mạng rồi thử lại." }
        if provider.status.contains("NO RESULT") { return "Không tìm thấy địa điểm phù hợp. Hãy thử tên hoặc địa chỉ khác." }
        if provider.status.contains("SEARCHING") { return "Đang truy vấn dữ liệu địa điểm OSM…" }
        return "Nhập địa điểm rồi bấm Tìm. Ví dụ: “Bệnh viện Đà Nẵng”, “Huế”, “Đà Nẵng Airport”."
    }
}
