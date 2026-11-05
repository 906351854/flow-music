import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var player: PlayerService

    @State private var query = ""
    @State private var results: [Track] = []
    @State private var isSearching = false
    @State private var failed: String?

    init() {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "scenario") == "search" {
            _query = State(initialValue: "周杰伦")
        }
        #endif
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if isSearching && results.isEmpty {
                            StatusCard(icon: "magnifyingglass", title: "搜索中…")
                        } else if let failed {
                            StatusCard(icon: "exclamationmark.triangle", title: "搜索失败", detail: failed)
                        } else if results.isEmpty {
                            StatusCard(
                                icon: "sparkle.magnifyingglass",
                                title: "搜点什么",
                                detail: "单曲搜索走 /cloudsearch/pc，\n结果可直接点击播放"
                            )
                        } else {
                            HStack {
                                Text("单曲")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text("\(results.count) 首")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.tertiaryText)
                                Spacer()
                            }
                            .padding(.bottom, 2)

                            LazyVStack(spacing: 0) {
                                ForEach(Array(results.enumerated()), id: \.element.id) { offset, track in
                                    TrackRow(
                                        track: track,
                                        index: offset + 1,
                                        isCurrent: player.current?.id == track.id
                                    ) {
                                        player.play(track: track,
                                                    in: results,
                                                    source: .search)
                                    }
                                    if offset < results.count - 1 {
                                        Divider().overlay(Theme.hairline).padding(.leading, 36)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }
                .softTopEdge()
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "歌曲、歌手"
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .task(id: query) { await debouncedSearch() }
    }

    /// 输入停顿 400ms 再打接口，避免每敲一个字符都发一次请求。
    private func debouncedSearch() async {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            results = []
            failed = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(420))
        guard !Task.isCancelled else { return }

        isSearching = true
        failed = nil
        defer { isSearching = false }

        do {
            let found = try await MusicAPI.search(keyword, limit: 30)
            guard !Task.isCancelled else { return }
            results = found
            if found.isEmpty { failed = "没有找到「\(keyword)」的相关结果" }
        } catch {
            guard !Task.isCancelled else { return }
            failed = error.localizedDescription
        }
    }
}
