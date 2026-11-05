import SwiftUI

/// 资料库只放两样东西：账号里的「我喜欢的音乐」和自建歌单。
///
/// 音质选择已经从这里撤掉 —— 档位恢复成 `config.json` 里的默认值，
/// 不再让用户在资料库这种「内容陈列」的地方调参数。
/// 「关于」也不是页面级信息，收进了账号的二级页，跟着账号一起走。
struct LibraryView: View {
    @EnvironmentObject private var player: PlayerService

    @State private var profile: AccountResponse.Profile?
    @State private var playlists: [PlaylistSummary] = []
    @State private var isLoading = false
    @State private var failed: String?
    @State private var showLogin = false
    @State private var showAccount = false

    /// 上次成功取到的 UID。`/nuser/account/get` 偶尔失败时还能靠它把歌单拉回来。
    @AppStorage("library.lastUID") private var lastUID: Int = 0

    private var isLoggedIn: Bool { MusicClient.shared.isLoggedIn }

    /// 优先认 `specialType == 5`；接口没给标记时按名字兜底。
    private var likedPlaylist: PlaylistSummary? {
        if let special = playlists.first(where: \.isLikedMusic) { return special }
        return playlists.first { $0.name.contains("喜欢的音乐") }
    }

    /// 「自建」= 排除我喜欢的音乐，也排除收藏来的别人的歌单。
    private var createdPlaylists: [PlaylistSummary] {
        let likedID = likedPlaylist?.id
        return playlists.filter { $0.id != likedID && !$0.isLikedMusic && $0.subscribed != true }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        accountCard

                        if isLoggedIn {
                            content
                        } else {
                            signInHint
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 28)
                }
                .softTopEdge()
                .refreshable { await refresh(force: true) }
            }
            .navigationTitle("资料库")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if !isLoggedIn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("登录") { showLogin = true }
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .navigationDestination(for: PlaylistRoute.self) { route in
                PlaylistView(summary: route.summary, owned: route.owned)
            }
            .navigationDestination(isPresented: $showAccount) {
                AccountDetailView(profile: profile) { signOut() }
            }
        }
        // sheet 挂在 NavigationStack 外层：挂在内部时，标签页切换重建视图
        // 有可能让已置位的 isPresented 丢掉，表现就是「点了没反应」。
        .sheet(isPresented: $showLogin) {
            LoginSheet {
                Task { await refresh(force: true) }
            }
        }
        .task {
            await refresh()
            #if DEBUG
            // 模拟器没法被脚本点按，留个钩子直接进账号二级页截图。
            if ProcessInfo.processInfo.environment["LIBRARY_ACCOUNT"] == "1" {
                showAccount = true
            }
            #endif
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if isLoading && playlists.isEmpty {
            StatusCard(icon: "arrow.down.circle", title: "正在同步歌单…")
        } else if let failed, playlists.isEmpty {
            VStack(spacing: 12) {
                StatusCard(icon: "exclamationmark.triangle",
                           title: "歌单加载失败",
                           detail: failed)
                Button {
                    Task { await refresh(force: true) }
                } label: {
                    Text("重试")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.base)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .background(Theme.accent, in: Capsule())
            }
            .frame(maxWidth: .infinity)
        } else {
            if let liked = likedPlaylist {
                NavigationLink(value: PlaylistRoute(summary: liked, owned: true)) {
                    likedRow(liked)
                }
                .buttonStyle(.plain)
            }

            createdSection
        }
    }

    // MARK: - 我喜欢的音乐

    private func likedRow(_ item: PlaylistSummary) -> some View {
        HStack(spacing: 14) {
            // 「我喜欢的音乐」经常没有封面，这时用心形渐变自己画一个，
            // 直接交给 ArtworkView 会显示成一个灰底音符，看着像加载失败。
            LikedCover(url: item.coverURL)
                .frame(width: 68, height: 68)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.name.isEmpty ? "我喜欢的音乐" : item.name)
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(item.trackCount) 首")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - 自建歌单

    private var createdSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "自建歌单",
                subtitle: createdPlaylists.isEmpty ? nil : "\(createdPlaylists.count) 个"
            )

            if createdPlaylists.isEmpty {
                Text("还没有自建歌单")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
                    .padding(.horizontal, 16)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 14),
                        GridItem(.flexible(), spacing: 14),
                    ],
                    alignment: .leading,
                    spacing: 18
                ) {
                    ForEach(createdPlaylists) { item in
                        NavigationLink(value: PlaylistRoute(summary: item, owned: true)) {
                            LibraryPlaylistCell(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - 账号

    private var accountCard: some View {
        Button {
            if isLoggedIn { showAccount = true } else { showLogin = true }
        } label: {
            accountLabel
        }
        .buttonStyle(.plain)
    }

    private var accountLabel: some View {
        HStack(spacing: 12) {
            ArtworkView(url: avatarURL, cornerRadius: 26)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(nickname)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(accountSubtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isLoading && isLoggedIn {
                ProgressView().controlSize(.small).tint(Theme.accent)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var signInHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("登录后同步你的歌单")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
            Text("「我喜欢的音乐」和建过的歌单都会出现在这里。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var nickname: String {
        if let name = profile?.nickname, !name.isEmpty { return name }
        return isLoggedIn ? "已登录" : "未登录"
    }

    private var accountSubtitle: String {
        guard isLoggedIn else { return "登录后同步我喜欢的音乐与自建歌单" }
        if let uid = profile?.userId { return "UID \(uid)" }
        return "登录态已保存在本机"
    }

    private var avatarURL: URL? {
        guard let raw = profile?.avatarUrl, !raw.isEmpty,
              var components = URLComponents(string: raw) else { return nil }
        components.scheme = "https"
        components.queryItems = [URLQueryItem(name: "param", value: "200y200")]
        return components.url
    }

    // MARK: - 数据

    private func refresh(force: Bool = false) async {
        guard isLoggedIn else {
            profile = nil
            playlists = []
            failed = nil
            return
        }
        guard !isLoading else { return }

        isLoading = true
        failed = nil
        defer { isLoading = false }

        do {
            let fetched = try await MusicAPI.account()
            if let fetched { profile = fetched }

            if let uid = fetched?.userId ?? (lastUID > 0 ? lastUID : nil) {
                lastUID = uid
                playlists = try await MusicAPI.userPlaylists(uid: uid, forceRefresh: force)
            } else {
                failed = "取不到账号 UID，请下拉重试"
            }
        } catch {
            failed = error.localizedDescription
        }
    }

    private func signOut() {
        MusicClient.shared.clearAuth()
        profile = nil
        playlists = []
        failed = nil
        lastUID = 0
    }
}

// MARK: - 歌单网格单元

private struct LibraryPlaylistCell: View {
    let item: PlaylistSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ArtworkView(url: item.coverURL, cornerRadius: 14)
                .aspectRatio(1, contentMode: .fit)

            Text(item.name)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(item.trackCount) 首")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
        }
    }
}

// MARK: - 我喜欢的音乐封面

/// 有封面就正常显示；没有就画一颗心。
/// 这颗心的封面是系统歌单的固定形象，不该跟着「空数据」一起消失。
private struct LikedCover: View {
    let url: URL?

    var body: some View {
        if let url {
            ArtworkView(url: url, cornerRadius: 16)
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.accentDeep, Theme.violet],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
        }
    }
}
