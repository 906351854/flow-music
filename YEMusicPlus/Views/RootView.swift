import SwiftUI

/// 根视图。
///
/// 不再有标签栏：主页（封面流）就是唯一的舞台，底部只留
/// 「播放条 + 搜索」两件东西，其余入口收进右上角的头像。
/// 头像点开是资料库（歌单陈列），设置再收在资料库的齿轮里。
struct RootView: View {
    @EnvironmentObject private var player: PlayerService

    @State private var showNowPlaying = false
    @State private var showProfile = false
    @State private var showSearch = false
    @State private var showLoginDebug = false
    /// 轻提示（试听片段 / 音质降级 / 自动跳过）的显示任务。
    @State private var noticeTask: Task<Void, Never>?
    @State private var showNotice = false

    var body: some View {
        HomeView(onAvatarTap: { showProfile = true })
            // 底部配件：播放条 + 搜索。用 safeAreaInset 而不是 overlay ——
            // 它会真的占掉一段安全区，主页的信息区（歌名/计数）自动抬到它上方，
            // 不会像浮层那样盖住内容；封面流本身 ignoresSafeArea，仍然通屏。
            .safeAreaInset(edge: .bottom, spacing: 0) {
                dock
            }
            .animation(.smooth(duration: 0.28), value: player.current?.id)
            // 正在播放页和「选择歌单」同款弹出样式：sheet + 拖拽指示条。
            .sheet(isPresented: $showNowPlaying) {
                NowPlayingView()
            }
            .sheet(isPresented: $showProfile) {
                LibraryView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showSearch) {
                SearchView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            #if DEBUG
            .sheet(isPresented: $showLoginDebug) {
                LoginSheet {}
            }
            #endif
            .alert("无法播放", isPresented: errorBinding) {
                Button("好", role: .cancel) { player.errorMessage = nil }
            } message: {
                Text(player.errorMessage ?? "")
            }
            // 轻提示：不值得弹窗的反馈（试听片段、降级、自动跳过）从这里飘一条，
            // 顶部居中，2.8s 自己消失。
            .overlay(alignment: .top) {
                if showNotice, let notice = player.notice {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12, weight: .semibold))
                        Text(notice)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
                    .padding(.horizontal, 40)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onChange(of: player.notice) { _, value in
                noticeTask?.cancel()
                guard value != nil else {
                    showNotice = false
                    return
                }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showNotice = true }
                noticeTask = Task {
                    try? await Task.sleep(for: .seconds(2.8))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.3)) { showNotice = false }
                }
            }
            .task {
                // 头像不参与首屏布局，账号信息后台取即可，别拖慢启动。
                Task { await AccountStore.shared.loadIfNeeded() }
                await runDebugScenario()
            }
    }

    // MARK: - 底部配件

    private var dock: some View {
        HStack(spacing: 10) {
            // 播放条常驻：没在放歌时是空态（点它去搜索），放歌后换成曲目信息。
            // 形态固定、高度一致，开始/结束播放时整页不会上下跳一格。
            PlayerBar(track: player.current) {
                if player.current == nil {
                    showSearch = true
                } else {
                    showNowPlaying = true
                }
            }
            searchButton
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private var searchButton: some View {
        Button {
            showSearch = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("搜索")
    }

    #if DEBUG
    /// 仅调试用：通过 `-scenario <名称>` 启动参数直接跳到某个界面，
    /// 方便脚本截图验证（模拟器无法被自动化点按）。
    private func runDebugScenario() async {
        let scenario = UserDefaults.standard.string(forKey: "scenario") ?? ""
        guard !scenario.isEmpty else { return }

        switch scenario {
        case "search":
            try? await Task.sleep(for: .milliseconds(500))
            showSearch = true
        case "library":
            try? await Task.sleep(for: .milliseconds(500))
            showProfile = true
        case "settings":
            // 资料库自身再读 LIBRARY_SETTINGS 环境变量把设置页推开。
            try? await Task.sleep(for: .milliseconds(500))
            showProfile = true
        case "login":
            try? await Task.sleep(for: .milliseconds(600))
            showProfile = true
            try? await Task.sleep(for: .milliseconds(600))
            showLoginDebug = true
        case "play", "nowplaying":
            let demo = Track(
                id: 1330348068,
                name: "起风了",
                artists: [Track.Artist(id: 0, name: "冯沁苑(买辣椒也用券)")],
                album: Track.Album(id: 0,
                                   name: "起风了",
                                   picUrl: "https://p1.music.126.net/diGAyEmpymX8G7JcnElncQ==/109951163699673355.jpg"),
                durationMS: 325868,
                fee: 8
            )
            player.play(track: demo)
            if scenario == "nowplaying" {
                try? await Task.sleep(for: .seconds(3))
                showNowPlaying = true
            }
        case "follow":
            // 在资料库里播一个歌单 —— 验证封面流会不会跟着换成它。
            await playOwnedPlaylistDemo()
        default:
            break
        }
    }

    /// 调试用：拿资料库里「我喜欢的音乐」直接开播，模拟用户从歌单页点了播放。
    private func playOwnedPlaylistDemo() async {
        guard let profile = try? await MusicAPI.account(),
              let uid = profile.userId else { return }
        let playlists = (try? await MusicAPI.userPlaylists(uid: uid)) ?? []
        guard let target = playlists.first(where: \.isLikedMusic) ?? playlists.first,
              let detail = try? await MusicAPI.playlistDetail(id: target.id),
              let first = detail.tracks.first else { return }
        player.play(track: first,
                    in: detail.tracks,
                    source: .playlist(target, owned: true))
        try? await Task.sleep(for: .milliseconds(900))
    }
    #else
    private func runDebugScenario() async {}
    #endif

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { player.errorMessage != nil },
            set: { if !$0 { player.errorMessage = nil } }
        )
    }
}
