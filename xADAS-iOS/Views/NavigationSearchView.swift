import SwiftUI

struct NavigationSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var provider: MapNavigationProvider
    @State private var query = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Nhập tên địa điểm hoặc địa chỉ", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onChange(of: query) { value in
                            provider.search(query: value)
                        }
                    if !query.isEmpty {
                        Button {
                            query = ""
                            provider.search(query: "")
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                if query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                    VStack(spacing: 14) {
                        Image(systemName: "location.magnifyingglass")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("Tìm điểm đến")
                            .font(.headline)
                        Text("Nhập ít nhất 2 ký tự, ví dụ: “Bệnh viện Đà Nẵng”, “Huế”, “Đà Nẵng Airport” hoặc một địa chỉ cụ thể.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if provider.searchResults.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView().opacity(provider.status.contains("SEARCHING") ? 1 : 0)
                        Text(statusText)
                            .font(.footnote.monospaced())
                            .foregroundStyle(provider.status.contains("ERROR") || provider.status.contains("NO TOKEN") ? .red : .secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(provider.searchResults) { result in
                        Button {
                            provider.startNavigation(to: result)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    if !result.subtitle.isEmpty {
                                        Text(result.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Chọn điểm đến")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
    }

    private var statusText: String {
        if provider.status.contains("NO TOKEN") {
            return "Mapbox chưa được cấu hình trong bản build này."
        }
        if provider.status.contains("SEARCH ERROR") {
            return "Không thể tải kết quả tìm kiếm. Kiểm tra kết nối mạng rồi thử lại."
        }
        if provider.status.contains("NO RESULT") {
            return "Không tìm thấy địa điểm phù hợp. Hãy thử tên hoặc địa chỉ khác."
        }
        if provider.status.contains("SEARCHING") {
            return "Đang tìm địa điểm…"
        }
        return provider.status
    }
}
