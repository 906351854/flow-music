import SwiftUI

/// 首页：一摞纵向堆叠的封面流 —— 这也是首页唯一的形态。
///
/// 一叠唱片摊在屏幕上 —— 正中的那张最大、最实、正面朝着你；往上和往下，
/// 每一张都比前一张更小、更后仰、并被前一张压住一截，形成「一摞卡片」的纵深。
/// 上下拖动把整摞牌推走，松手吸附到最近的一张。
///
/// 会变的不是形态，是**牌堆的来源**：每日推荐是一个歌单，漫游是一个歌单，
/// 资料库里的每个歌单也是。点顶部标题换成别的歌单，牌堆就摆它的曲目；
/// 在别处播放了某个歌单，首页也会自动跟过去 —— 正在放什么歌单，
/// 封面流就摆什么歌单。
///
/// 大歌单不会一次性把封面画出来：牌堆只创建正中附近 9 张，
/// 外面的既没有视图也没有取图请求，翻到哪儿才加载到哪儿。
struct HomeView: View {
    @EnvironmentObject private var player: PlayerService

    /// 当前牌堆的来源。
    @State private var source: HomeSource = .daily
    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var failed: String?
    @State private var showPicker = false
    /// 每次换来源 +1。先发后到的旧请求据此丢弃，
    /// 否则快速连点两个歌单时，慢的那个回来会把画面盖回去。
    @State private var generation = 0

    /// 正中那张的序号。
    @State private var index = 0
    /// 手指位移（向上为负），松手后归零。真正决定画面的是 `index - drag / step`。
    @State private var drag: CGFloat = 0
    /// 拖动过程中上一次打过触感的卡位，用来判断是否又越过一张。
    @State private var tickSlot: Int?
    /// 信息区当前展示的卡位。手势里直接更新，避免每帧重算几何。
    @State private var liveSlot = 0
    /// 调试用：让牌堆停在两张之间（`HOME_START_INDEX=3.5`），检查交棒那一瞬的姿态。
    /// 正常运行时恒为 0，一次加法，可以忽略。
    @State private var debugShift: CGFloat = 0
    /// 长按进入的「快速翻牌」模式：同样的手指距离翻更多张，
    /// 用来在大歌单里快速巡航。松手即退出。
    @State private var fastScroll = false
    /// 背景取色用的曲目。只在播放器真的有当前曲目时才更新，
    /// 浏览牌堆不会改它 —— 所以背景是一块稳定的氛围底，不是跟着手指跑的灯。
    @State private var backdropTrack: Track?

    // MARK: 歌词模式（按住封面往左滑）

    /// 歌词面板是否处于展开状态（松手吸附后的稳定值）。
    @State private var lyricsOpen = false
    /// 展开进度 0~1，拖动时实时跟手，松手后带动画吸附到 0 或 1。
    @State private var lyricsProgress: CGFloat = 0
    /// 这一笔拖动定下的轴向。一旦定了横/竖就不再换，
    /// 避免斜着拖时牌堆和歌词面板来回打架。
    @State private var dragAxis: DragAxis?
    /// 进入横向拖动那一刻的展开进度（0 或 1），位移在此基础上累加。
    @State private var axisStartProgress: CGFloat = 0
    /// 当前曲目的歌词与加载状态。
    @State private var lyricLines: [LyricLine] = []
    @State private var lyricLoading = false
    @State private var lyricTrackID: Int?

    enum DragAxis {
        case vertical, horizontal
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // 背景只在「有当前曲目」时取封面色，并且只跟着 player 走。
                // 浏览时滑过十几张，背景一次都不换 —— 之前它绑在 index 上，
                // 每停一张就整屏换一次色，看久了很晃。
                //
                // 必须放在 overlay 里：`scaledToFill` 的模糊封面会按比例溢出，
                // 直接当 ZStack 的子视图会把整个页面撑宽（实测 675pt），
                // 页面里的东西会按超宽居中排版，左右被裁到屏幕外。
                AppBackground()
                    .overlay {
                        if let backdropTrack {
                            backdrop(backdropTrack)
                        }
                    }

                content
            }
            .navigationBarTitleDisplayMode(.inline)
            // 标题就是歌单切换入口：带一个向下的箭头，点开是歌单列表。
            // 铺导航栏底色会在下沿切出一条明暗分界，和模糊封面接不上，
            // 所以背景继续交给页面里的渐变压暗。
            .toolbar {
                ToolbarItem(placement: .principal) {
                    sourceButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    trailingStatus
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .sheet(isPresented: $showPicker) {
                HomeSourcePicker(current: source) { picked in
                    pick(picked)
                }
            }
        }
        .task {
            if tracks.isEmpty { await bootstrap() }
        }
        .onChange(of: player.queueSource) { _, newValue in
            syncWithPlayer(newValue)
        }
        .onChange(of: player.current?.id) { _, newValue in
            followPlayer(newValue)
            // 换歌了才换底色。暂停、浏览、拖动手势都不动它。
            if let playing = player.current {
                withAnimation(.easeOut(duration: 0.55)) {
                    backdropTrack = playing
                }
            }
            // 歌词面板开着时切了歌：跟着换歌词，面板保持展开。
            if lyricsOpen {
                lyricTrackID = nil   // 强制重取
                Task { await loadLyrics() }
            }
        }
        .onChange(of: lyricsOpen) { _, open in
            if open { Task { await loadLyrics() } }
        }
    }

    // MARK: - 顶部

    private var sourceButton: some View {
        Button {
            showPicker = true
        } label: {
            HStack(spacing: 4) {
                Text(source.name)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.62)
                    .offset(y: 0.5)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.55), radius: 8, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("选择歌单，当前是\(source.name)")
    }

    /// 换来源时转圈；漫游时给一个「换一批」。
    @ViewBuilder
    private var trailingStatus: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        } else if source.kind == .roam {
            Button {
                Task { await load(.roam, regenerate: true) }
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("换一批漫游")
        }
    }

    // MARK: - 状态分支

    @ViewBuilder
    private var content: some View {
        if isLoading && tracks.isEmpty {
            loadingState
        } else if let failed, tracks.isEmpty {
            failureState(failed)
        } else if tracks.isEmpty {
            emptyState
        } else {
            stage
        }
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView().tint(Theme.accent)
            Text("正在获取\(source.name)…")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .padding(.horizontal, 40)
        }
    }

    private func failureState(_ detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("加载失败").font(.system(size: 16, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                Task { await load(source, regenerate: true) }
            } label: {
                Text("重试")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.base)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .background(Theme.accent, in: Capsule())
            .padding(.top, 4)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("这个歌单里还没有曲目")
                .font(.system(size: 14, weight: .medium))
            Button {
                showPicker = true
            } label: {
                Text("换一个歌单")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .foregroundStyle(.white)
    }

    // MARK: - 舞台

    private var stage: some View {
        ZStack {
            // 牌堆单独一层、通屏铺满：卡片可以一路滑到状态栏和标签栏底下。
            GeometryReader { geo in
                let metrics = DeckMetrics(size: geo.size)
                ZStack {
                    deck(metrics, progress: CGFloat(index) - drag / metrics.step + debugShift)
                    // 点正中封面以上的空白 = 翻到上一张，以下 = 下一张。
                    //
                    // 只翻页、不播放 —— 相当于按了一下方向键，按了正中那张才是回车。
                    // 用户用它精确定位：点一下挪一张，看到想听的翻到正中再点它。
                        .onTapGesture(count: 1, coordinateSpace: .local) { loc in
                            slide(loc.y < metrics.centerY ? -1 : 1)
                        }

                    // 歌词面板：盖在封面原本的位置上 —— 系统材质做局部高斯模糊，
                    // 上面滚歌词。打开后才接收点击（点行跳进度）。
                    lyricsPanel(metrics)
                        .opacity(Double(lyricsProgress))
                        .allowsHitTesting(lyricsOpen)
                }
            }
            .ignoresSafeArea()

            infoLayer
        }
        // 顶边 / 底边的压暗交给系统的 soft 边缘效果（iOS 26 原生），不再自己画渐变。
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        // 吸附到新的一张时给一次稍重的撞击。
        .sensoryFeedback(.impact(weight: .light, intensity: 0.85), trigger: index)
        // 长按后没拖就松手时，拖动手势的 onEnded 不会跑，快速模式会残留 ——
        // 这里兜底：进入后 2.5s 内没有走到 onEnded（onEnded 会先把它置回 false）就自动退出。
        .onChange(of: fastScroll) { _, on in
            guard on else { return }
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                if fastScroll { fastScroll = false }
            }
        }
    }

    /// 信息区。放在安全区内，由系统保证它永远在标签栏 / 迷你播放条上方，
    /// 不依赖自己算安全区高度。
    private var infoLayer: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if let current = tracks[safe: liveSlot] {
                    infoPanel(current, width: min(geo.size.width - 60, 336))
                    counter(liveSlot)
                        .padding(.top, 10)
                }
            }
            .padding(.bottom, 14)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .allowsHitTesting(false)
    }

    /// 一摞卡片。只在正中那张附近渲染 9 张，其余靠 offset 推到屏外。
    /// 歌单有几千首也只创建这 9 张 —— 这是「大歌单不卡」的第一道闸。
    private func deck(_ m: DeckMetrics, progress: CGFloat) -> some View {
        let center = Int(progress.rounded())
        let lower = max(0, center - 4)
        let upper = min(tracks.count - 1, center + 4)
        // 牌堆中心对齐到 centerY：ZStack 自身居中，整体下移这么多即可。
        let shift = m.centerY - m.height / 2

        return ZStack {
            if lower <= upper {
                ForEach(lower...upper, id: \.self) { i in
                    let d = CGFloat(i) - progress

                    card(tracks[i], at: i, depth: d, side: m.side)
                        .offset(y: shift + m.travel(d))
                        // 歌词模式：正中那张挪到屏幕左侧并向内倾一点，
                        // 原位让给模糊面板 + 歌词。weight 只对正中附近生效，
                        // 翻到别的卡时归零，牌堆恢复原状。
                        .offset(x: -m.width * 0.28 * lyricsWeight(d))
                        .scaleEffect(1 - 0.22 * lyricsWeight(d))
                        // 正角绕 Y 轴：右边往里转（朝歌词面板的方向退进屏幕），
                        // 像一扇朝里开的门。之前是负角，右边翻向外了，方向反。
                        .rotation3DEffect(
                            .degrees(45 * Double(lyricsWeight(d))),
                            axis: (x: 0, y: 1, z: 0),
                            anchor: .center,
                            perspective: 0.6
                        )
                        .zIndex(-abs(d))
                }
            }
        }
        .frame(width: m.width, height: m.height)
        .mask(deckMask(m))
        .contentShape(Rectangle())
        // 高优先级：拖动必须赢过正中那张的 Button，否则「按住封面左滑」这一笔
        // 会被 Button 整个吃掉 —— 手感上就是按住左滑毫无反应。之前竖向翻牌
        // 能用纯属起手都落在上下空白处；左滑必须按在封面上，才暴露了这个坑。
        // DragGesture 要先走 8pt 才算成立，单击/长按依然归 Button，互不干扰。
        .highPriorityGesture(deckDrag(m))
        .simultaneousGesture(fastScrollGesture)
    }

    /// 只做底部渐隐。顶部不再遮罩 —— 卡片本来就该滑到状态栏底下，
    /// 那儿有渐变压暗，边缘才是连着的。
    private func deckMask(_ m: DeckMetrics) -> some View {
        func at(_ k: CGFloat) -> CGFloat {
            min(1.0, max(0.001, (m.centerY + m.side * k) / m.height))
        }

        return LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: at(0.58)),
                // 底部渐隐收着点：之前 0.62/0.18 淡得太狠，第二张就快看不见了。
                .init(color: .black.opacity(0.78), location: at(0.82)),
                .init(color: .black.opacity(0.46), location: at(1.00)),
                .init(color: .black.opacity(0.10), location: at(1.14)),
                .init(color: .clear, location: at(1.24)),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - 单张卡片

    private func card(_ track: Track, at i: Int, depth d: CGFloat, side: CGFloat) -> some View {
        let isCenter = abs(d) < 0.5
        // 交棒区间（0.5~0.85 张）两张都走 HDR —— 只在正中那 0.5 张里切的话，
        // 换手的一瞬间会一张亮一张暗，闪一下。
        let wantsHDR = abs(d) < 0.85
        let isCurrent = player.current?.id == track.id

        // 用 Button 而不是 onTapGesture：只有 Button 能把「按下」这个中间状态给出来，
        // 才做得出下沉回弹。外层有拖动手势，但手指一移动 Button 就让位，不会抢滑动。
        // 封面上不再画播放按钮 —— 底部播放条已经有一个，两张同时出现太吵。
        //
        // 只有正中那张可以按 —— 上下露出的封面一律不可点。
        // 之前试过「点旁边翻页」，结果想拖牌堆时手一抖就成了误触，得不偿失。
        return Button {
            if isCurrent {
                player.togglePlayPause()
            } else {
                player.play(track: track, in: tracks, source: source.queueSource)
            }
        } label: {
            Group {
                if wantsHDR {
                    // 正中这张走 EDR，亮部能突破纸白，在 HDR 屏上更透。
                    HDRArtworkView(url: track.coverURL, cornerRadius: 16)
                } else {
                    ArtworkView(url: track.coverURL, cornerRadius: 16)
                }
            }
            .frame(width: side, height: side)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.18), .white.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.7
                    )
            }
        }
        .buttonStyle(CardPressStyle())
        .scaleEffect(scale(d))
        .rotation3DEffect(
            .degrees(Double(tilt(d))),
            axis: (x: 1, y: 0, z: 0),
            anchor: .center,
            // 透视从 0.8 收到 0.56：0.8 的梯形变形太狠，卡片一斜就像贴到脸上，
            // 是「夸张」的另一半原因。0.56 还留着纵深，但边缘不再被拉爆。
            perspective: 0.56
        )
        .opacity(fade(d))
        .shadow(color: .black.opacity(shadowAlpha(d)), radius: 18, y: 10)
        // 只有正中那张接收点击，旁边的封面纯展示 —— 想翻页只能拖，杜绝误触。
        .allowsHitTesting(isCenter)
        .accessibilityLabel(isCenter ? "播放 \(track.name)" : track.name)
    }

    private func scale(_ d: CGFloat) -> CGFloat {
        // 正中那张 1.08；往后每一张乘 0.75 —— 紧挨着的那张正好是中间的 75%，
        // 再往外继续按同比例收缩，牌堆往上/往下看起来就是逐级变小的。
        let n = min(abs(d), 4)
        let base = 1.08 * pow(0.75, n)
        // 交棒瞬间（正停在两张之间）两张卡大小一样、都接近正面，叠着像双重曝光。
        // 让它们一起退 7%，谁都别在那一刻「等于中心那张」。两端导数为 0，不会抖。
        return base * (1 - 0.07 * transit(d))
    }

    /// 0 = 正好停在一张上，1 = 正停在两张正中间。
    private func transit(_ d: CGFloat) -> CGFloat {
        let f = abs(d - d.rounded()) / 0.5
        return f * f
    }

    /// 翻转角：正中 0°，紧邻那张约 37°，第二张 59°，再往外 62° 封顶。
    ///
    /// 之前是线性的 `d * 60`，问题不在「上限 80°」而在**斜率**：
    /// 相邻两张之间只挪 `step = 0.34 × 卡片宽`，却要转 60°，
    /// 换算下来整摞牌是绕一根半径不到卡片对角线的细轴卷起来的 ——
    /// 手指刚离开中心，正中那张就「啪」地侧翻，看着当然夸张。
    ///
    /// 现在用 smoothstep 把「开始转」推迟到偏离 0.10 张之后，
    /// 中心那一段几乎保持正面，角度等卡片已经拉开距离了才追上来：
    /// 中间是摊开的，两头才卷起来。两端导数为 0，所以过渡处没有折角。
    private func tilt(_ d: CGFloat) -> CGFloat {
        let n = min(abs(d), 3)
        let start: CGFloat = 0.10        // 离开中心这么多才开始有角度
        let full: CGFloat = 1.70         // 到这里到达最大角
        let maxAngle: CGFloat = 62       // 侧立的上限：再大会缩成一条板

        guard n > start else { return 0 }
        let t = min((n - start) / (full - start), 1)
        let eased = t * t * (3 - 2 * t)  // smoothstep
        let angle = maxAngle * eased
        return d < 0 ? -angle : angle
    }

    /// 越往外越淡。前两张保持全实 —— 它们才是「一摞牌」的轮廓，
    /// 再往后已经开始侧立，全部实心叠起来像一扇百叶窗而不是一叠专辑。
    private func fade(_ d: CGFloat) -> Double {
        let n = abs(d)
        guard n > 1.6 else { return 1 }
        return max(0, 1 - Double(n - 1.6) * 0.62)
    }

    /// 阴影随距离轻轻衰减。原来是 `abs(d) < 0.5 ? 0.45 : 0.28`，
    /// 卡在跨过 0.5 的那一帧会硬跳一下，滑起来像闪了一下。
    private func shadowAlpha(_ d: CGFloat) -> Double {
        0.42 - 0.16 * Double(min(abs(d), 1))
    }

    // MARK: - 信息区

    /// 按估算字宽截断。中文标题加英文副标题一混排就特别长，
    /// SwiftUI 的 Text 在固定 frame 下偶尔仍会把字画出边界，索性自己量一遍。
    private func ellipsized(_ text: String, fontSize: CGFloat, width: CGFloat) -> String {
        let limit = max(24, width - fontSize)
        var result = ""
        var used: CGFloat = 0
        for ch in text {
            let isWide = ch.unicodeScalars.first.map { $0.value >= 0x2E80 } ?? false
            let advance = isWide ? fontSize : fontSize * 0.56
            if used + advance > limit {
                return result.trimmingCharacters(in: .whitespaces) + "…"
            }
            result.append(ch)
            used += advance
        }
        return text
    }

    private func infoPanel(_ track: Track, width: CGFloat) -> some View {
        VStack(spacing: 5) {
            Text(ellipsized(track.name, fontSize: 19, width: width))
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: width)

            Text(ellipsized(track.artistLine, fontSize: 12.5, width: width))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .frame(width: width)

            HStack(spacing: 6) {
                if let reason = track.recommendReason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.13), in: Capsule())
                }
                if track.needsVip {
                    Text("VIP")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.13), in: Capsule())
                }
            }
            .frame(width: width)
        }
        .multilineTextAlignment(.center)
    }

    private func counter(_ slot: Int) -> some View {
        HStack(spacing: 5) {
            Text("\(min(max(slot, 0), max(tracks.count - 1, 0)) + 1)")
                .foregroundStyle(.white.opacity(0.85))
            Text("/ \(tracks.count)")
                .foregroundStyle(.white.opacity(0.28))
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .monospacedDigit()
    }

    // MARK: - 背景

    private func backdrop(_ track: Track) -> some View {
        ZStack {
            AsyncImage(url: track.coverURL, transaction: Transaction(animation: .easeOut(duration: 0.5))) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 64, opaque: true)
                        .scaleEffect(1.4)
                }
            }
            .id(track.id)
            .transition(.opacity)

            LinearGradient(
                stops: [
                    .init(color: Theme.base.opacity(0.26), location: 0),
                    .init(color: Theme.base.opacity(0.50), location: 0.42),
                    .init(color: Theme.base.opacity(0.86), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// 歌词模式下第 d 张的位移/倾斜权重：正中那张 1，往外一张线性衰减到 0。
    /// 乘上全局展开进度，拖到一半时牌堆跟着走到一半。
    private func lyricsWeight(_ d: CGFloat) -> CGFloat {
        max(0, 1 - abs(d)) * lyricsProgress
    }

    /// 歌词面板：无边界的一团柔和模糊 + 上面滚歌词。
    ///
    /// 不是一张带描边阴影的「卡片」—— 那种有棱有角的东西和整个页面的气质不合，
    /// 用户点名要 `.soft` 边缘效果那种同款：没有边界，只有一团雾。
    /// 做法是材质铺满整块区域，然后用「上下 + 左右」两条羽化渐变做 mask，
    /// 边缘一路淡到零，和系统 scroll edge effect 是同一种观感。
    /// 歌词的上下渐隐用的也是这同一层 mask —— 文字不是被裁在面板里，
    /// 是溶进模糊里去的。
    private func lyricsPanel(_ m: DeckMetrics) -> some View {
        LyricsPanel(
            lines: lyricLines,
            isLoading: lyricLoading,
            currentTime: player.currentTime
        ) { time in
            player.seek(to: time)
        }
        .frame(width: m.width * 0.62,
               height: min(m.side * 1.35, m.height * 0.62))
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                // 材质已经是最低档（ultraThin），再压到一成 ——
                // 要的是几乎察觉不到的一层雾，不是一块深色玻璃。
                .opacity(0.10)
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.20),
                    .init(color: .black, location: 0.80),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.14),
                    .init(color: .black, location: 0.86),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        // ZStack 居中，整体右移到封面原位。注意纵向也要跟着挪：
        // 牌堆的封面中心在 40% 屏高处（centerY），而 ZStack 的中线在 50% ——
        // 不补这段差，面板会比封面低一截，两边的羽化对不上。
        .offset(x: m.width * 0.12, y: m.centerY - m.height / 2)
        .gesture(lyricsPanelDrag)
    }

    // MARK: - 手势

    /// 把牌堆翻到正中那张的上/下一张（`delta` 为 -1 / +1），只挪位置、不播放。
    /// 点上下空白处走这里 —— 定位用，按了正中封面才开始播。
    ///
    /// 歌词展开时禁用：牌堆整个冻结，上下点按不做任何事，
    /// 先把面板收回来才能翻歌。不然翻着牌歌词还是旧的，两边各走各的。
    private func slide(_ delta: Int) {
        guard !tracks.isEmpty, !lyricsOpen else { return }
        let target = min(max(index + delta, 0), tracks.count - 1)
        guard target != index else { return }
        tickSlot = nil
        liveSlot = target
        withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
            index = target
            drag = 0
        }
    }

    private func deckDrag(_ m: DeckMetrics) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !tracks.isEmpty else { return }
                let h = value.translation.height
                let w = value.translation.width

                // 轴向判定：这一笔先动过 8pt 时定死横/竖，此后不再换向 ——
                // 斜着拖不会出现牌堆和歌词面板来回抢。
                // 歌词展开期间不认竖向：牌堆整个冻结，想翻歌先收回面板。
                if dragAxis == nil {
                    if abs(w) > 8, abs(w) > abs(h) * 1.15 {
                        dragAxis = .horizontal
                        axisStartProgress = lyricsOpen ? 1 : 0
                        DeckHaptics.prepare()
                    } else if abs(h) > 10, !lyricsOpen {
                        dragAxis = .vertical
                    }
                }

                switch dragAxis {
                case .horizontal:
                    // 往左滑展开歌词，往右收回。170pt 走完全程。
                    lyricsProgress = min(max(axisStartProgress - w / 170, 0), 1)

                case .vertical:
                    if tickSlot == nil { DeckHaptics.prepare() }

                    var offset = h
                    // 到头了给一点阻尼，别让整摞牌直接滑出屏幕。
                    if index == 0 && offset > 0 { offset *= 0.35 }
                    if index >= tracks.count - 1 && offset < 0 { offset *= 0.35 }

                    // 长按后的快速模式：同样的手指距离翻接近两倍的牌。
                    let gain: CGFloat = fastScroll ? 1.9 : 1.0
                    drag = offset * gain

                    // 每越过一张卡就打一个轻点 —— 手指滑动的过程中就该有反馈，
                    // 而不是等松手吸附那一下才震。
                    let slot = Int((CGFloat(index) - offset * gain / m.step).rounded())
                    let clamped = min(max(slot, 0), tracks.count - 1)
                    if clamped != tickSlot {
                        tickSlot = clamped
                        liveSlot = clamped
                        DeckHaptics.tick()
                    }

                case nil:
                    break
                }
            }
            .onEnded { value in
                switch dragAxis {
                case .horizontal:
                    finishLyricsDrag(value)
                case .vertical:
                    endVerticalDrag(value, step: m.step)
                case nil:
                    break
                }
                dragAxis = nil
            }
    }

    /// 歌词面板上的拖动：只管横向收回（面板里竖向留给歌词滚动）。
    private var lyricsPanelDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard dragAxis == nil || dragAxis == .horizontal else { return }
                if dragAxis == nil {
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    dragAxis = .horizontal
                    axisStartProgress = lyricsOpen ? 1 : 0
                }
                lyricsProgress = min(max(axisStartProgress - value.translation.width / 170, 0), 1)
            }
            .onEnded { value in
                guard dragAxis == .horizontal else { return }
                finishLyricsDrag(value)
                dragAxis = nil
            }
    }

    /// 松手时按进度吸附：过半就算开，另外轻扫速度也认。
    private func finishLyricsDrag(_ value: DragGesture.Value) {
        let wantOpen = lyricsProgress > 0.5
            || (!lyricsOpen && value.velocity.width < -900)
            || (lyricsOpen && value.velocity.width > 900)

        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            lyricsProgress = wantOpen ? 1 : 0
        }
        guard wantOpen != lyricsOpen else { return }
        lyricsOpen = wantOpen
        DeckHaptics.tick(intensity: 0.8)
        if wantOpen { Task { await loadLyrics() } }
    }

    /// 竖向拖动的松手结算（从 deckDrag 拆出来，让横向/竖向各管各的）。
    private func endVerticalDrag(_ value: DragGesture.Value, step: CGFloat) {
        guard !tracks.isEmpty else { return }

        // 回到预测位移：松手那一刻系统会预测手指的落点，轻扫也能稳稳翻一张，
        // 比只看实际位移顺手。灵敏度靠两层压住 ——
        // 普通模式一次最多 2 张；慢拖必须真的越过半张才算数（预测值小，取整后是 0）。
        let raw = -(value.predictedEndTranslation.height * (fastScroll ? 1.9 : 1.0)) / step
        var stepCount = Int(raw.rounded())
        if !fastScroll, abs(stepCount) < 1 {
            // 慢拖没过半张，但手上有明显的快扫速度 → 认 1 张。
            if value.velocity.height < -1300 { stepCount = 1 }
            else if value.velocity.height > 1300 { stepCount = -1 }
        }
        let limit = fastScroll ? 8 : 2
        stepCount = min(max(stepCount, -limit), limit)

        let target = min(max(index + stepCount, 0), tracks.count - 1)

        tickSlot = nil
        liveSlot = target
        fastScroll = false
        withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
            index = target
            drag = 0
        }
    }

    /// 长按进入快速翻牌：按住别动约半秒（打一次重触感），然后直接拖，
    /// 同样的距离能连着翻好几张，松手恢复。对付几百首的大歌单用。
    ///
    /// 用 simultaneous 而不是 sequenced：后者会让普通拖动先被长按阶段
    /// 卡住 0.4s，拖起来就「黏」了。残留状态靠 onEnded + 计时兜底清掉。
    private var fastScrollGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.42, maximumDistance: 14)
            .onEnded { _ in
                guard !fastScroll else { return }
                fastScroll = true
                DeckHaptics.tick(intensity: 1.0)
            }
    }

    // MARK: - 来源切换

    private func pick(_ picked: HomeSource) {
        showPicker = false
        // 点的还是当前这个：漫游就换一批，其余什么也不做。
        if picked == source {
            if picked.kind == .roam {
                Task { await load(.roam, regenerate: true) }
            }
            return
        }
        Task { await load(picked) }
    }

    /// 播放器换了歌单 → 封面流跟过去。
    ///
    /// 只认「歌单」类来源：单曲和搜索结果不算，首页不会因为随手点了一首歌
    /// 就把整摞牌换掉。
    private func syncWithPlayer(_ queueSource: PlayerService.QueueSource) {
        guard !player.queue.isEmpty,
              let incoming = HomeSource(queueSource: queueSource),
              incoming != source else { return }
        // 之前可能正在加载另一张歌单，那条请求回来时不许把画面盖回去。
        generation += 1
        failed = nil
        isLoading = false
        adopt(player.queue, as: incoming)
    }

    private func followPlayer(_ id: Int?) {
        guard let id, drag == 0,
              let pos = tracks.firstIndex(where: { $0.id == id }),
              pos != index else { return }
        liveSlot = pos
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            index = pos
        }
    }

    // MARK: - 数据

    /// 拉当前曲目的歌词。切歌时 `lyricTrackID` 被清空，这里会重取；
    /// 同一首歌重复打开面板走 LyricsStore 的缓存，不发请求。
    private func loadLyrics() async {
        guard let track = player.current else {
            lyricLines = []
            lyricTrackID = nil
            return
        }
        guard lyricTrackID != track.id else { return }
        lyricLoading = lyricLines.isEmpty
        defer { lyricLoading = false }
        lyricLines = await LyricsStore.shared.lines(for: track.id)
        lyricTrackID = track.id
    }

    private func bootstrap() async {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["HOME_SOURCE"] == "roam" {
            await load(.roam)
            applyDebugHooks()
            if env["HOME_PICKER"] == "1" { showPicker = true }
            return
        }
        #endif

        if let playing = HomeSource(queueSource: player.queueSource), !player.queue.isEmpty {
            // 冷启动时先在放某个歌单：直接摆它，不再多打一次接口。
            adopt(player.queue, as: playing)
            isLoading = false
            failed = nil
        } else {
            await load(source)
        }

        #if DEBUG
        applyDebugHooks()
        if ProcessInfo.processInfo.environment["HOME_PICKER"] == "1" { showPicker = true }
        #endif
    }

    private func load(_ target: HomeSource, regenerate: Bool = false) async {
        generation += 1
        let gen = generation

        source = target
        failed = nil

        // 正在放的就是这个歌单：直接用播放器的队列。
        // 既省一次请求，也保证「标题、牌堆、正在放的」三者是同一份东西。
        if !regenerate,
           let playing = HomeSource(queueSource: player.queueSource),
           playing == target,
           !player.queue.isEmpty {
            isLoading = false
            adopt(player.queue, as: target)
            return
        }

        isLoading = true
        do {
            let list = try await fetch(target)
            guard gen == generation else { return }
            isLoading = false
            if list.isEmpty {
                tracks = []
                index = 0
                liveSlot = 0
                failed = "这个歌单里还没有可播放的曲目"
            } else {
                adopt(list, as: target)
            }
        } catch {
            guard gen == generation else { return }
            isLoading = false
            tracks = []
            index = 0
            liveSlot = 0
            failed = error.localizedDescription
        }
    }

    private func fetch(_ target: HomeSource) async throws -> [Track] {
        switch target.kind {
        case .daily:
            return try await MusicAPI.dailyRecommendations()
        case .roam:
            return try await RoamPlaylist.build()
        case .playlist:
            guard let id = target.playlistID else { return [] }
            return try await MusicAPI.playlistDetail(id: id).tracks
        }
    }

    /// 换一摞牌。序号尽量落在正在放的那首上，这样点开就能接着听。
    private func adopt(_ list: [Track], as target: HomeSource) {
        source = target
        tracks = list
        drag = 0
        tickSlot = nil
        debugShift = 0

        var pos = 0
        if let id = player.current?.id,
           let found = list.firstIndex(where: { $0.id == id }) {
            pos = found
        }
        index = pos
        liveSlot = pos

        if let current = player.current {
            // 背景始终跟着「正在放的」走。切歌单只是换牌堆，
            // 只要还在放歌，底色就不该被浏览行为改掉。
            backdropTrack = current
        } else {
            backdropTrack = list.first
        }
    }

    #if DEBUG
    /// 调试钩子：`HOME_START_INDEX` 停在指定卡位，`HOME_AUTOPLAY` 播首曲。
    private func applyDebugHooks() {
        let env = ProcessInfo.processInfo.environment

        if let raw = env["HOME_START_INDEX"],
           let slot = Double(raw), !tracks.isEmpty {
            let whole = min(max(Int(slot), 0), tracks.count - 1)
            index = whole
            liveSlot = whole
            debugShift = CGFloat(slot - Double(whole))
        }

        if env["HOME_AUTOPLAY"] == "1",
           player.current == nil,
           let first = tracks.first {
            player.play(track: first, in: tracks, source: source.queueSource)
        }

        // 调试：直接进入歌词模式（模拟器无法合成拖动手势）。
        if env["HOME_LYRICS"] == "1" {
            lyricsOpen = true
            lyricsProgress = 1
            Task { await loadLyrics() }
        }
    }
    #endif
}

// MARK: - 牌堆几何

/// 把「离正中多远」换算成位移 / 缩放。
///
/// 位移用等比衰减累加：相邻两张靠得开，越往后越挤，于是后半摞牌会叠得更紧，
/// 屏幕上看起来就是一摞由疏到密的卡片，而不是等间距的一列。
private struct DeckMetrics {
    let width: CGFloat
    let height: CGFloat
    let side: CGFloat
    let centerY: CGFloat
    let step: CGFloat

    init(size: CGSize) {
        width = size.width
        height = size.height
        // 牌堆比之前大一圈，左右各留 30pt 左右，接近通屏。
        side = max(150, min(size.width - 62, size.height * 0.38, 340))
        centerY = size.height * 0.40
        // 间距拉开：相邻两张露出的卡边更宽，才看得出「一摞」而不是「一张」。
        step = max(58, side * 0.34)
    }

    func travel(_ d: CGFloat) -> CGFloat {
        let n = abs(d)
        guard n > 0.0001 else { return 0 }
        let falloff: CGFloat = 0.84
        var distance = step * (1 - pow(falloff, n)) / (1 - falloff)
        // 交棒时两张卡各往外让 26% 的步长，把重叠从 64% 压到 40% 左右 ——
        // 角度收小之后卡片投影变高，不让这一步就会在同一位置叠死。
        let f = abs(d - d.rounded()) / 0.5
        distance += step * 0.26 * f * f
        return d > 0 ? distance : -distance
    }
}

// MARK: - 按压反馈

/// 手指按住封面时整张卡「沉」下去一点：缩 4.5%、往下挪 3pt、压暗 5%。
/// 松手用一档偏硬的弹簧弹回来（damping 0.62），有回弹但不哆嗦。
/// 幅度刻意做小 —— 卡片本身已经带 3D 旋转，再大就不像被按住，像被拍扁。
private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.955 : 1)
            .offset(y: configuration.isPressed ? 3 : 0)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.spring(response: 0.26, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

// MARK: - 小工具

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
