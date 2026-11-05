import SwiftUI

/// 歌单页的导航参数。
///
/// `owned` 只决定播放来源归类（资料库里的歌单 vs 榜单/别人分享的歌单）；
/// 首页的封面流不管哪种歌单，播了哪张就摆哪张。
struct PlaylistRoute: Hashable {
    let summary: PlaylistSummary
    var owned: Bool = false
}

struct PlaylistView: View {
    let summary: PlaylistSummary
    var owned: Bool = false

    @EnvironmentObject private var player: PlayerService

    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var failed: String?

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    if isLoading {
                        StatusCard(icon: "music.note.list", title: "正在加载曲目…")
                    } else if let failed {
                        StatusCard(icon: "exclamationmark.triangle", title: "加载失败", detail: failed)
                    } else if tracks.isEmpty {
                        StatusCard(icon: "tray", title: "这个歌单没有可显示的曲目")
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { offset, track in
                                TrackRow(
                                    track: track,
                                    index: offset + 1,
                                    isCurrent: player.current?.id == track.id
                                ) {
                                    player.play(track: track,
                                                in: tracks,
                                                source: .playlist(summary, owned: owned))
                                }
                                if offset < tracks.count - 1 {
                                    Divider().overlay(Theme.hairline).padding(.leading, 36)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .softTopEdge()
        }
        .navigationTitle(summary.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ArtworkView(url: summary.coverURL, cornerRadius: 16)
                .frame(width: 108, height: 108)

            VStack(alignment: .leading, spacing: 6) {
                Text(summary.name)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(summary.updateFrequency ?? "共 \(summary.trackCount) 首")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)

                if !tracks.isEmpty {
                    Button {
                        if let first = tracks.first {
                            player.play(track: first,
                                        in: tracks,
                                        source: .playlist(summary, owned: owned))
                        }
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.base)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .background(Theme.accent, in: Capsule())
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func load() async {
        isLoading = true
        failed = nil
        defer { isLoading = false }
        do {
            let result = try await MusicAPI.playlistDetail(id: summary.id)
            tracks = result.tracks
        } catch {
            failed = error.localizedDescription
        }
    }
}
