import SwiftUI

struct ChartsView: View {

    private struct Group: Identifiable {
        let id: String
        let title: String
        let items: [PlaylistSummary]
    }

    @State private var toplists: [PlaylistSummary] = []
    @State private var isLoading = true
    @State private var failed: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if isLoading {
                            StatusCard(icon: "chart.bar", title: "正在加载…")
                        } else if let failed {
                            StatusCard(icon: "exclamationmark.triangle", title: "加载失败", detail: failed)
                        } else {
                            ForEach(groups) { group in
                                VStack(alignment: .leading, spacing: 8) {
                                    SectionHeader(title: group.title, subtitle: "\(group.items.count) 个")
                                    ForEach(group.items) { item in
                                        NavigationLink(value: item) {
                                            row(item)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }
                .softTopEdge()
                .refreshable { await load() }
            }
            .navigationTitle("排行榜")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: PlaylistSummary.self) { summary in
                PlaylistView(summary: summary)
            }
        }
        .task {
            if toplists.isEmpty { await load() }
        }
    }

    private func row(_ item: PlaylistSummary) -> some View {
        HStack(spacing: 12) {
            ArtworkView(url: item.coverURL, cornerRadius: 10)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(item.updateFrequency ?? "\(item.trackCount) 首")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// 65 个榜单铺平没有层次，前 8 个单独一组当「热门」。
    private var groups: [Group] {
        let named = toplists.filter { $0.name.contains("榜") }
        let source = named.isEmpty ? toplists : named
        let head = Array(source.prefix(8))
        let tail = Array(source.dropFirst(8))

        var result: [Group] = []
        if !head.isEmpty { result.append(Group(id: "hot", title: "热门", items: head)) }
        if !tail.isEmpty { result.append(Group(id: "all", title: "全部榜单", items: tail)) }
        return result
    }

    private func load() async {
        isLoading = true
        failed = nil
        defer { isLoading = false }
        do {
            toplists = try await MusicAPI.toplists()
        } catch {
            failed = error.localizedDescription
        }
    }
}
