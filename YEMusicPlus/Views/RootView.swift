import SwiftUI

struct RootView: View {
    @EnvironmentObject private var player: PlayerService
    @State private var selection: Int = 0
    @State private var showNowPlaying = false
    @State private var showLoginDebug = false
    /// 轻提示（试听片段 / 音质降级 / 自动跳过）的显示任务。
    @State private var noticeTask: Task<Void, Never>?
    @State private var showNotice = false

    var body: some View {
        // 用系统真正的 tabViewBottomAccessory，而不是自己压一条悬浮胶囊。
        // 只有这样做，下滑时播放条才会和标签栏一起下沉、上滑一起回来 ——
        // 也就是 Apple Music 的那个行为。自绘 overlay 是钉死的，不会跟着动。
        TabView(selection: $selection) {
            Tab("推荐", systemImage: "sparkles", value: 0) {
                HomeView()
            }
            Tab("排行榜", systemImage: "chart.bar.doc.horizontal", value: 1) {
                ChartsView()
            }
            Tab("搜索", systemImage: "magnifyingglass", value: 2) {
                SearchView()
            }
            Tab("资料库", systemImage: "music.note.list", value: 3) {
                LibraryView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // isEnabled 控制配件是否参与布局：没有播放曲目时必须关掉，
        // 否则系统会留一条空白玻璃胶囊占着位置。
        .tabViewBottomAccessory(isEnabled: player.current != nil) {
            if let track = player.current {
                PlayerBar(track: track, embedded: true) {
                    showNowPlaying = true
                }
            }
        }
        .animation(.smooth(duration: 0.28), value: player.current?.id)
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView()
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
        .task { await runDebugScenario() }
    }

    #if DEBUG
    /// 仅调试用：通过 `-scenario <名称>` 启动参数直接跳到某个界面，
    /// 方便脚本截图验证（模拟器无法被自动化点按）。
    private func runDebugScenario() async {
        let scenario = UserDefaults.standard.string(forKey: "scenario") ?? ""
        guard !scenario.isEmpty else { return }

        switch scenario {
        case "charts":
            selection = 1
        case "search":
            selection = 2
        case "library":
            selection = 3
        case "login":
            selection = 3
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
            // 在资料库里播一个歌单，再切回首页 —— 验证封面流会不会跟着换成它。
            await playOwnedPlaylistDemo()
            selection = 0
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
