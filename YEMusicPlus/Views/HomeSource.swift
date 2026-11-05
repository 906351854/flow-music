import SwiftUI

/// 首页封面流正在摆的那一摞牌来自哪个歌单。
///
/// 首页只有一种形态：封面流。能换的只有「牌堆的来源」——
/// 每日推荐是一个歌单，漫游是一个歌单，资料库里的每个歌单也是。
/// 选中谁，封面流就摆谁的曲目；正在播放的歌单变了，牌堆也跟着换。
struct HomeSource: Equatable, Hashable, Identifiable {
    enum Kind: Hashable {
        case daily
        case roam
        case playlist
    }

    var kind: Kind = .daily
    var name: String = "每日推荐"
    var playlistID: Int?
    /// 是不是资料库里自己的歌单（决定播放时上报的来源类型）。
    var owned: Bool = false

    var id: String { "\(kind)-\(playlistID ?? 0)" }

    static let daily = HomeSource(kind: .daily, name: "每日推荐")
    static let roam = HomeSource(kind: .roam, name: "漫游歌单")

    init(kind: Kind, name: String, playlistID: Int? = nil, owned: Bool = false) {
        self.kind = kind
        self.name = name
        self.playlistID = playlistID
        self.owned = owned
    }

    /// 播放器的队列来源 → 首页的牌堆来源。
    /// 单曲 / 搜索结果不是歌单，返回 nil，首页保持原样。
    init?(queueSource: PlayerService.QueueSource) {
        switch queueSource.kind {
        case .recommendation:
            self = .daily
        case .roam:
            self = HomeSource(kind: .roam,
                              name: queueSource.name.isEmpty ? "漫游歌单" : queueSource.name)
        case .playlist, .ownedPlaylist:
            self = HomeSource(kind: .playlist,
                              name: queueSource.name,
                              playlistID: queueSource.playlistID,
                              owned: queueSource.kind == .ownedPlaylist)
        case .single, .search:
            return nil
        }
    }

    /// 首页的牌堆来源 → 播放器上报的来源类型。
    var queueSource: PlayerService.QueueSource {
        switch kind {
        case .daily:
            return .recommendation
        case .roam:
            return .roam(name: name)
        case .playlist:
            return PlayerService.QueueSource(kind: owned ? .ownedPlaylist : .playlist,
                                             name: name,
                                             playlistID: playlistID)
        }
    }
}

// MARK: - 选择歌单

/// 首页顶部的歌单选择器。
///
/// 做成一张独立的表而不是 `Menu`：歌单可能很多，列表能滚动、能显示封面和曲目数，
/// 也能顺手把「每日推荐 / 漫游」这两个内置来源和自己的歌单放在同一套视觉里。
struct HomeSourcePicker: View {
    let current: HomeSource
    let onSelect: (HomeSource) -> Void

    @Environment(\.dismiss) private var dismiss
    /// 和资料库共用同一个 UID 兜底，账号接口偶尔抽风时也能把歌单拉回来。
    @AppStorage("library.lastUID") private var lastUID: Int = 0

    @State private var playlists: [PlaylistSummary] = []
    @State private var isLoading = false
    @State private var failed: String?
    /// 直接摊到大半屏 —— 歌单多的时候一进来就能看到一串，
    /// 往下拖还能收到中号。
    @State private var detent: PresentationDetent = .large

    private var isLoggedIn: Bool { MusicClient.shared.isLoggedIn }

    private var liked: PlaylistSummary? {
        if let special = playlists.first(where: \.isLikedMusic) { return special }
        return playlists.first { $0.name.contains("喜欢的音乐") }
    }

    private var created: [PlaylistSummary] {
        let likedID = liked?.id
        return playlists.filter { $0.id != likedID && !$0.isLikedMusic && $0.subscribed != true }
    }

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                // LazyVStack：歌单可能有几百个，只给滚到眼前的那几行建视图、取封面。
                // 用普通 VStack 的话一打开就几十上百张封面同时开始下载。
                LazyVStack(alignment: .leading, spacing: 8) {
                    header
                        .padding(.bottom, 8)

                    sectionTitle("为你推荐")
                    builtinRow(.daily,
                               icon: "sparkles",
                               detail: "每天更新一批，未登录也能听")
                    builtinRow(.roam,
                               icon: "shuffle",
                               detail: "从喜欢的音乐和自建歌单里随机穿行")

                    if isLoggedIn {
                        sectionTitle("我的歌单")
                            .padding(.top, 14)
                        myRows
                    } else {
                        signInHint
                            .padding(.top, 14)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 32)
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .task { await loadLibrary() }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("选择歌单")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Text("封面流摆的就是这个歌单的曲目")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }

            Spacer(minLength: 12)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.10), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 内置来源

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.tertiaryText)
            .padding(.top, 4)
    }

    private func builtinRow(_ source: HomeSource, icon: String, detail: String) -> some View {
        Button {
            select(source)
        } label: {
            rowLabel(source, detail: detail) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: source.kind == .daily
                                ? [Theme.accent, Theme.ocean]
                                : [Theme.violet, Theme.accentDeep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.94))
                    }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 我的歌单

    @ViewBuilder
    private var myRows: some View {
        if isLoading && playlists.isEmpty {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small).tint(Theme.accent)
                Text("正在同步歌单…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
        } else if let failed, playlists.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("歌单加载失败")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Text(failed)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(3)
                Button {
                    Task { await loadLibrary(force: true) }
                } label: {
                    Text("重试")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        } else if liked == nil && created.isEmpty {
            Text("还没有歌单")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.vertical, 10)
        } else {
            if let liked {
                playlistRow(liked)
            }
            ForEach(created) { item in
                playlistRow(item)
            }
        }
    }

    private func playlistRow(_ item: PlaylistSummary) -> some View {
        let source = HomeSource(kind: .playlist,
                                name: item.name,
                                playlistID: item.id,
                                owned: true)
        return Button {
            select(source)
        } label: {
            rowLabel(source, detail: "\(item.trackCount) 首") {
                if item.coverURL != nil {
                    ArtworkView(url: item.coverURL, cornerRadius: 13)
                } else {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Theme.accentDeep, Theme.violet],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                        }
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 未登录

    private var signInHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("登录后可以选自己的歌单")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
            Text("「我喜欢的音乐」和自建歌单会出现在这里，封面流直接摆它们的曲目。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    // MARK: 通用行

    private func rowLabel<Tile: View>(_ source: HomeSource,
                                      detail: String,
                                      @ViewBuilder tile: () -> Tile) -> some View {
        let selected = source == current

        return HStack(spacing: 12) {
            tile()
                .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text(source.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.12) : Color.white.opacity(0.055))
                .overlay {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(selected ? Theme.accent.opacity(0.45) : Color.white.opacity(0.05),
                                      lineWidth: 0.8)
                }
        }
        .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    // MARK: 动作 / 数据

    private func select(_ source: HomeSource) {
        onSelect(source)
        dismiss()
    }

    private func loadLibrary(force: Bool = false) async {
        guard isLoggedIn else { return }
        if !force {
            guard playlists.isEmpty, !isLoading else { return }
        }
        guard !isLoading else { return }

        isLoading = true
        failed = nil
        defer { isLoading = false }

        do {
            let profile = try await MusicAPI.account()
            guard let uid = profile?.userId ?? (lastUID > 0 ? lastUID : nil) else {
                failed = "取不到账号 UID，请稍后重试"
                return
            }
            lastUID = uid
            playlists = try await MusicAPI.userPlaylists(uid: uid, forceRefresh: force)
        } catch {
            failed = error.localizedDescription
        }
    }
}
