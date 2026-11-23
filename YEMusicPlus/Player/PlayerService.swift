import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import UserNotifications
import os.log

@MainActor
final class PlayerService: ObservableObject {

    enum RepeatMode: String, CaseIterable {
        case off, all, one

        var symbol: String {
            switch self {
            case .off: return "arrow.forward.to.line"
            case .all: return "repeat"
            case .one: return "repeat.1"
            }
        }

        var label: String {
            switch self {
            case .off: return "顺序播放"
            case .all: return "列表循环"
            case .one: return "单曲循环"
            }
        }
    }

    /// 当前播放队列是从哪儿来的。
    ///
    /// 首页的封面流靠它决定「摆哪一摞牌」：正在放哪个歌单，
    /// 封面流就显示哪个歌单 —— 每日推荐、漫游、资料库里的歌单都算歌单，
    /// 单曲和搜索结果不算，首页不会被它们拽走。
    struct QueueSource: Equatable {
        enum Kind: Equatable {
            case single          // 单曲
            case recommendation  // 每日推荐
            case roam            // 漫游歌单（现场生成的一批）
            case search          // 搜索结果
            case playlist        // 普通歌单（榜单、别人分享的）
            case ownedPlaylist   // 自己资料库里的歌单
        }

        var kind: Kind = .single
        var name: String = ""
        var playlistID: Int?

        static let single = QueueSource(kind: .single)
        static let recommendation = QueueSource(kind: .recommendation, name: "每日推荐")
        static let search = QueueSource(kind: .search, name: "搜索结果")

        static func roam(name: String = "漫游歌单") -> QueueSource {
            QueueSource(kind: .roam, name: name)
        }

        static func playlist(_ summary: PlaylistSummary, owned: Bool) -> QueueSource {
            QueueSource(kind: owned ? .ownedPlaylist : .playlist,
                        name: summary.name,
                        playlistID: summary.id)
        }
    }

    // MARK: - 对外状态

    @Published private(set) var queue: [Track] = []
    @Published private(set) var index: Int = -1
    @Published private(set) var queueSource: QueueSource = .single
    /// 播放期间挂一个「禁止系统空闲睡眠」断言：
    /// iPad App 跑在 Mac 上时，换歌空档 / 缓冲的短暂静音会让 macOS 认为没事干
    /// 而触发空闲睡眠，一睡播放就断。停止播放时立刻放开断言。
    @Published private(set) var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            if isPlaying {
                if sleepAssertion == nil {
                    sleepAssertion = ProcessInfo.processInfo.beginActivity(
                        options: [.idleSystemSleepDisabled, .userInitiated],
                        reason: "Flow Music 正在播放"
                    )
                }
            } else if let activity = sleepAssertion {
                ProcessInfo.processInfo.endActivity(activity)
                sleepAssertion = nil
            }
        }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var streamLevel: String?

    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var isShuffled = false
    @Published var repeatMode: RepeatMode = .all
    @Published var qualityLevel: String = AppConfig.shared.quality.defaultLevel

    var current: Track? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    /// 给界面显示用的中文音质名。
    var qualityLabel: String {
        AppConfig.shared.quality.levels.first { $0.id == qualityLevel }?.name ?? qualityLevel
    }

    // MARK: - 私有

    private let player = AVPlayer()
    private var sleepAssertion: NSObjectProtocol?
    /// seek 进行中：观察器回报的旧时间在闸外排队（见 seek(to:)）。
    private var isSeeking = false
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var artworkImage: UIImage?

    private static let log = Logger(subsystem: "com.zed.yemusicplus", category: "player")

    init() {
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true
        configureAudioSession()
        observeInterruptions()
        observeEndOfTrack()
        addTimeObserver()
        setupRemoteCommands()
    }

    // MARK: - 音频会话

    /// 后台播放需要两个条件同时成立：Info.plist 的 UIBackgroundModes=audio，
    /// 以及这里的 .playback + setActive。少任何一个都表现为「退到后台立刻静音」且不报错。
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try session.setActive(true)
        } catch {
            Self.log.error("音频会话配置失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func observeInterruptions() {
        let center = NotificationCenter.default

        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .began:
                    self.player.pause()
                    self.isPlaying = false
                case .ended:
                    let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                    if options.contains(.shouldResume) {
                        try? AVAudioSession.sharedInstance().setActive(true)
                        self.player.play()
                        self.isPlaying = true
                    }
                @unknown default:
                    break
                }
                self.pushNowPlayingInfo()
            }
        }

        // 拔耳机 / 断开蓝牙时暂停，和系统播放器行为一致。
        routeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.player.pause()
                self.isPlaying = false
                self.pushNowPlayingInfo()
            }
        }
    }

    // MARK: - 播放进度

    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.4, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = time.seconds
                // seek 进行中观察器只会拿到旧位置（见 seek(to:)），忽略这次的回报。
                guard !self.isSeeking else { return }
                self.currentTime = seconds.isFinite ? max(seconds, 0) : 0
                if let item = self.player.currentItem {
                    let total = item.duration.seconds
                    if total.isFinite, total > 0 { self.duration = total }
                }
                self.pushNowPlayingInfo()
                self.watchdogTick()
            }
        }
    }

    /// 后台存活的关键：AVPlayer 因为网络抖动进入 waiting 时，
    /// iOS 只容忍几秒「该响没响」就把 App 挂起 —— 挂起后网络恢复也救不回来。
    /// 这里周期性巡检，先原地拉起；约 10 秒还不出声就判定断流，重取地址重播。
    private func watchdogTick() {
        guard isPlaying else {
            stallTicks = 0
            return
        }
        switch player.timeControlStatus {
        case .playing:
            stallTicks = 0
        case .waitingToPlayAtSpecifiedRate, .paused:
            stallTicks += 1
            if stallTicks == 8 { // 0.4s × 8 ≈ 3.2s 没出声，先续一口
                try? AVAudioSession.sharedInstance().setActive(true)
                player.play()
            } else if stallTicks >= 25 { // ≈10s 还不行，多半是连接断了
                stallTicks = 0
                // 冷却期重新取流只会加深风控；等冷却结束的自动续播即可。
                guard MusicClient.shared.rateLimitCooldown == 0 else { return }
                if let track = current {
                    streamCache.removeValue(forKey: "\(track.id)-\(qualityLevel)")
                    Task { await loadCurrent(autoPlay: true, autoSkip: true) }
                }
            }
        @unknown default:
            break
        }
    }

    private func observeEndOfTrack() {
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleTrackEnded() }
        }
    }

    private func handleTrackEnded() {
        if repeatMode == .one {
            seek(to: 0)
            player.play()
            isPlaying = true
            return
        }
        let isLast = index >= queue.count - 1
        if isLast && repeatMode == .off {
            player.pause()
            isPlaying = false
            currentTime = duration
            pushNowPlayingInfo()
            return
        }
        // 换歌的空档也要让会话保持活跃 —— 后台加载下一首的几秒里，
        // 会话一断 iOS 就可能把 App 挂起，表现就是「放完一首后台就停了」。
        try? AVAudioSession.sharedInstance().setActive(true)
        advance(forward: true)
    }

    // MARK: - 对外控制

    /// 播放一首歌。
    ///
    /// `source` 只在队列真的换了的时候生效：
    /// 在同一个队列里点另一首不该把「这是哪个歌单」这个身份弄丢，
    /// 否则每换一首歌，封面流都会以为自己被切走了。
    func play(track: Track, in tracks: [Track]? = nil, source: QueueSource? = nil) {
        // 用户主动点歌：作废上一轮「等冷却再播」的计划，交给这次重新判断。
        rateLimitRetryTask?.cancel()
        if let tracks, !tracks.isEmpty {
            let sameQueue = tracks.count == queue.count
                && zip(tracks, queue).allSatisfy { $0.id == $1.id }

            queue = tracks
            index = tracks.firstIndex(of: track) ?? 0

            if let source {
                queueSource = source
            } else if !sameQueue {
                queueSource = .single
            }
        } else if let existing = queue.firstIndex(of: track) {
            index = existing
        } else {
            queue = [track]
            index = 0
            queueSource = .single
        }
        Task { await loadCurrent(autoPlay: true, autoSkip: false) }
    }

    func togglePlayPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
            pushNowPlayingInfo()
            return
        }
        if player.currentItem == nil {
            rateLimitRetryTask?.cancel()
            Task { await loadCurrent(autoPlay: true, autoSkip: false) }
        } else {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            isPlaying = true
            pushNowPlayingInfo()
        }
    }

    func next() { advance(forward: true) }

    func previous() {
        // 和系统一致：播放超过 3 秒先回到开头，否则切上一首
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        advance(forward: false)
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), max(duration, 0))
        // seek 完成前，周期性时间观察器会拿「旧时间」回报一次 ——
        // 界面上就是滑块松手后瞬间闪回原位、再跳回来。加闸：
        // seek 进行中观察器的回报一律忽略，完成后放行。
        isSeeking = true
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600)) { [weak self] _ in
            MainActor.assumeIsolated { self?.isSeeking = false }
        }
        currentTime = clamped
        pushNowPlayingInfo()
    }

    func seek(fraction: Double) {
        guard duration > 0 else { return }
        seek(to: duration * min(max(fraction, 0), 1))
    }

    func cycleRepeatMode() {
        let all = RepeatMode.allCases
        let nextIndex = (all.firstIndex(of: repeatMode).map { $0 + 1 } ?? 0) % all.count
        repeatMode = all[nextIndex]
        if repeatMode != .one { lastNonOneRepeat = repeatMode }
    }

    /// 「单曲循环前的模式」：关掉单曲循环时回到它，不粗暴跳回列表循环。
    /// 轮换按钮和一键开关都会维护它。
    @Published private(set) var lastNonOneRepeat: RepeatMode = .all

    /// 一键开/关单曲循环：开着就回到之前的模式，没开就切到单曲循环。
    func toggleRepeatOne() {
        if repeatMode == .one {
            repeatMode = lastNonOneRepeat
        } else {
            lastNonOneRepeat = repeatMode
            repeatMode = .one
        }
    }

    private func advance(forward: Bool) {
        guard !queue.isEmpty else { return }
        rateLimitRetryTask?.cancel()

        if isShuffled && queue.count > 1 {
            var candidate = index
            while candidate == index { candidate = Int.random(in: 0..<queue.count) }
            index = candidate
        } else {
            var target = forward ? index + 1 : index - 1
            if target >= queue.count { target = 0 }
            if target < 0 { target = queue.count - 1 }
            index = max(0, min(target, queue.count - 1))
        }
        Task { await loadCurrent(autoPlay: true, autoSkip: true) }
    }

    // MARK: - 取流

    /// 取流地址缓存：同一次运行里来回切歌不该反复打 `song/url` 接口。
    /// 连接本身有有效期，10 分钟足够覆盖一次正常收听，过期就重新取。
    private var streamCache: [String: (data: SongURLData, at: Date)] = [:]
    private static let streamTTL: TimeInterval = 10 * 60

    /// 连续自动跳过的次数。数字别太大 —— 队列一半都不能播时，
    /// 静默跳完一整个歌单比停下来告诉用户更糟。
    private var consecutiveFailures = 0
    private var autoSkipTask: Task<Void, Never>?

    /// 卡顿看门狗计数：isPlaying 却连续多个 tick 没出声就拉一次。
    /// 后台里 AVPlayer 停在网络缓冲时 iOS 会很快挂起 App，挂起后永远回不来。
    private var stallTicks = 0

    /// 下一首取流地址的预取任务。
    private var prefetchTask: Task<Void, Never>?

    /// 限流冷却结束后的自动续播任务，以及本轮已经重试了几次。
    /// 重试次数封顶，避免在长时间风控里无限循环。
    private var rateLimitRetryTask: Task<Void, Never>?
    private var rateLimitRetries = 0
    /// 载入代次：连续点歌时用来丢弃过期结果。
    private var loadGeneration = 0

    /// 同一首歌同一档位的并发请求合并表。
    /// 预取和用户点歌撞在一起时会各打一次 `song/url`，
    /// 重复请求正是把 deviceId 推进 -460 风控的主要原因之一。
    private var inflightStream: [String: Task<SongURLData?, Error>] = [:]

    /// 取播放地址。
    ///
    /// 这里**不再**在 -460 时换 deviceId 就地重试：一次播放最多因此变成两个请求，
    /// 而降级链又会把每一档都走一遍，最坏 5 档 × 2 = 10 个请求在一秒内打出去 ——
    /// 风控只会越修越死。设备标识的轮换交给 `MusicClient.noteRateLimit()`，
    /// 它在冷却第二次命中时做一次，且有频率上限。
    private func fetchStreamURL(for track: Track, level: String) async throws -> SongURLData? {
        let key = "\(track.id)-\(level)"
        if let hit = streamCache[key], Date().timeIntervalSince(hit.at) < Self.streamTTL {
            return hit.data
        }
        // 已经有同样的请求在飞，就等它的结果，不再发一次。
        if let running = inflightStream[key] {
            return try await running.value
        }

        let task = Task<SongURLData?, Error> {
            // 具体走官方接口还是落雪音源，由 config 的 playback 段决定。
            try await PlaybackSourceResolver.shared.streamURL(for: track, level: level)
        }
        inflightStream[key] = task
        defer { inflightStream[key] = nil }

        let data = try await task.value
        if let data, data.url?.isEmpty == false {
            streamCache[key] = (data, Date())
        }
        return data
    }

    /// 音质降级链：从用户选的档位一路降到标准。
    /// config 里 levels 按低 → 高排列，反转后就是「从当前档往下」。
    private func qualityDowngradeChain() -> [String] {
        let ids = AppConfig.shared.quality.levels.map(\.id)
        guard let idx = ids.firstIndex(of: qualityLevel) else { return [qualityLevel] }
        return Array(ids[...idx].reversed())
    }

    /// 拿一个**真的能播**的地址：请求的音质没有音源（VIP / 版权 / 该歌没这档）时
    /// 自动往下降档重试，而不是直接把错误甩给用户。
    /// 大多数「播放错误」都是这个原因 —— 歌在，只是你要的那档音质没有。
    private func fetchPlayableStream(for track: Track) async throws -> (data: SongURLData, url: URL) {
        // 只有「接口成功但没有可用地址」才降一档。
        // 任何错误（限流、传输失败）都直接抛出去 —— 换档重试只会制造请求风暴。
        //
        // -110 是「这首曲子对当前账号不可播」：无版权，或者需要会员/单曲购买。
        // 它跟音质无关，换档不会有任何变化。以前这里会继续往下试，
        // 一首 VIP 歌就要打 3～5 个请求 —— 每日推荐整列都是 VIP 曲目时，
        // 点几首就够把账号推到服务端限流阈值上，随后所有歌都报风控。
        // 落雪音源里 `exhigh` 和 `higher` 映射到同一个 320k，
        // 不去重的话一次失败会朝同一个接口连发两次 —— 音源脚本自己带限流
        // （「2 秒内最多 4 次」那种），白白吃掉额度。
        var triedQualities = Set<String>()

        for level in qualityDowngradeChain() {
            if PlaybackSourceResolver.shared.isUsingLuoxue {
                let mapped = PlaybackSourceResolver.shared.mappedQuality(for: level)
                if triedQualities.contains(mapped) { continue }
                triedQualities.insert(mapped)
            }
            guard let data = try await fetchStreamURL(for: track, level: level) else { continue }
            if let url = MusicAPI.playableURL(from: data.url) {
                if level != qualityLevel {
                    notice = "「\(track.name)」没有\(qualityLabel)音源，已降到「\(levelName(level))」"
                }
                return (data, url)
            }
            if data.code == -110 {
                throw MusicAPIError.business(code: -110, message: nil)
            }
        }
        throw MusicAPIError.business(code: -110, message: nil)
    }

    private func levelName(_ id: String) -> String {
        AppConfig.shared.quality.levels.first { $0.id == id }?.name ?? id
    }

    /// 趁当前歌还在放，把下一首的取流地址提前拉好塞进缓存。
    /// 歌与歌的衔接从「现发请求等响应」缩成「直接装」，
    /// 后台里那个容易被系统挂起的空档窗口就基本归零了。
    private func schedulePrefetch() {
        prefetchTask?.cancel()
        let next: Track?
        if queue.indices.contains(index + 1) {
            next = queue[index + 1]
        } else if repeatMode != .off, let first = queue.first {
            next = first
        } else {
            next = nil
        }
        guard let next, next.id != current?.id else { return }
        // 冷却期不预取：这不是「必须马上要」的请求，白送一个风控计数没有意义。
        guard MusicClient.shared.rateLimitCooldown == 0 else { return }
        // 落雪音源不预取：取一条直链只要几百毫秒，而音源脚本自己带限流
        // （有的明写「2 秒内最多 4 次」）。预取等于把额度提前花掉，
        // 用户快速切歌时反而更容易被拒。
        guard !PlaybackSourceResolver.shared.isUsingLuoxue else { return }
        let level = qualityLevel
        prefetchTask = Task { [weak self] in
            // 快速连续切歌时只预取最后停下的那首 —— 前面几次直接取消掉，
            // 否则每划一下就打一次 song/url，同样是喂给风控的。
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            _ = try? await self.fetchStreamURL(for: next, level: level)
        }
    }

    /// 后台里彻底播不动时发一条本地通知 —— 不然用户只会觉得「它悄悄停了」，
    /// 回到前台才知道是这歌没音源。授权请求在拿到结果前不会打扰人。
    private func notifyStopInBackground(reason: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Flow Music 已停止播放"
            content.body = reason
            let request = UNNotificationRequest(identifier: "playback-stopped",
                                                content: content, trigger: nil)
            center.add(request)
        }
    }

    /// 把接口错误翻译成用户能看懂的话。弹 Alert 之前先过这一道。
    private func friendlyMessage(_ error: Error, track: Track) -> String {
        if case MusicAPIError.rateLimited(let retryAfter) = error {
            return "服务端限流，约 \(max(1, Int(retryAfter.rounded(.up)))) 秒后自动重试。"
        }
        if case MusicAPIError.business(let code, let message) = error {
            switch code {
            case -110:
                return "「\(track.name)」暂时无法播放：可能需要 VIP，或暂无音源。"
            case -460:
                return "操作太频繁，被服务端限流了，稍等片刻再试。"
            default:
                return message ?? "播放出错（\(code)）"
            }
        }
        return error.localizedDescription
    }

    /// 载入当前曲目。
    ///
    /// `autoSkip`：自动切歌（advance / 播完下一首）带来的失败应该静默跳过 ——
    /// 歌单里混几首没音源的，不能每首都弹一个 Alert 拦住人。
    /// 用户主动点歌的失败仍然弹窗说清楚。
    private func loadCurrent(autoPlay: Bool, autoSkip: Bool) async {
        guard let track = current else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        notice = nil
        autoSkipTask?.cancel()
        // 只有「最新一代」才负责收尾，否则先发的请求返回时会把
        // 后一次载入的 loading 状态提前关掉。
        defer { if generation == loadGeneration { isLoading = false } }

        // 缓存命中就用本地文件播放：连取流接口都不打。
        // 取流是所有请求里最容易被 -460 风控盯上的，缓存命中等于整体绕开。
        //
        // 沿降级链从高到低找：上次可能因为没有高音源被降档缓存，
        // 只认当前档位的话会出现「明明缓存了却当没缓存」。
        var cachedHit: (level: String, url: URL)?
        for level in qualityDowngradeChain() {
            if let url = AudioCacheStore.shared.cachedURL(forKey: "\(track.id)-\(level)") {
                cachedHit = (level, url)
                break
            }
        }
        var usedCacheKey: String?

        do {
            let data: SongURLData?
            let url: URL
            if let cachedHit {
                data = nil
                url = cachedHit.url
                usedCacheKey = "\(track.id)-\(cachedHit.level)"
            } else {
                let fetched = try await fetchPlayableStream(for: track)
                data = fetched.data
                url = fetched.url
            }

            // 用户在这期间点了别的歌：这次的结果已经过期，直接丢弃。
            // 不丢的话，先发的请求后到，会把新歌替换成旧歌。
            guard generation == loadGeneration, current?.id == track.id else { return }

            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)

            duration = Double(track.durationMS) / 1000
            currentTime = 0
            // 命中缓存时汇报缓存里的实际档位，而不是用户设置的那档。
            streamLevel = cachedHit?.level ?? data?.level ?? qualityLevel
            consecutiveFailures = 0
            rateLimitRetries = 0
            stallTicks = 0

            if let data, data.isTrialOnly {
                notice = "会员曲目，当前仅提供试听片段"
            }

            // 试听片段一律不进缓存：缓存下来以后命中就只能永远听 30 秒。
            // level 是可选值，必须先解包再拼 key —— 直接插值会写出
            // `Optional("exhigh")` 这种永远命中不了的脏 key。
            if let data, !data.isTrialOnly {
                let level = data.level ?? qualityLevel
                AudioCacheStore.shared.cache(url: url, key: "\(track.id)-\(level)")
            }

            if autoPlay {
                try? AVAudioSession.sharedInstance().setActive(true)
                player.play()
                isPlaying = true
            } else {
                isPlaying = false
            }

            loadArtwork(for: track)
            pushNowPlayingInfo()
            schedulePrefetch()
        } catch MusicAPIError.rateLimited(let retryAfter) {
            guard generation == loadGeneration else { return }
            // 限流不弹窗：它是暂时的，弹窗只会让人反复点「好」再试，
            // 每试一次就等于再往风控计数里添一笔，永远恢复不了。
            // 这里只挂一条轻提示，冷却结束自动接上。
            player.replaceCurrentItem(with: nil)
            isPlaying = false
            duration = 0
            currentTime = 0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

            if MusicClient.shared.rateLimitIsNetworkRisk {
                // IP 级风控：同一个网络里重试多少次结果都一样，
                // 不自动重试、不换 deviceId，直接说清楚该怎么做。
                notice = "当前网络被网易云判定为风险环境，换 Wi-Fi / 蜂窝后再试"
            } else {
                let wait = max(1, Int(retryAfter.rounded(.up)))
                notice = "服务端限流，约 \(wait) 秒后自动接上"
                scheduleRateLimitRetry(after: TimeInterval(wait), track: track, autoPlay: autoPlay)
            }
        } catch {
            guard generation == loadGeneration else { return }
            // 本地缓存文件坏了（半截、容器异常）：删掉它改走网络重来一次。
            // 不这么做的话，这首歌唱到一半断掉、下次还是同一个坏文件。
            if let usedCacheKey {
                AudioCacheStore.shared.remove(forKey: usedCacheKey)
                await loadCurrent(autoPlay: autoPlay, autoSkip: autoSkip)
                return
            }

            player.replaceCurrentItem(with: nil)
            isPlaying = false
            duration = 0
            currentTime = 0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

            consecutiveFailures += 1
            let canSkip = autoSkip && queue.count > 1 && consecutiveFailures < 4
            if canSkip {
                notice = "「\(track.name)」无法播放，自动跳到下一首"
                autoSkipTask = Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    guard !Task.isCancelled else { return }
                    advance(forward: true)
                }
            } else {
                consecutiveFailures = 0
                let message = friendlyMessage(error, track: track)
                errorMessage = message
                notifyStopInBackground(reason: message)
            }
        }
    }

    /// 冷却结束自动接上当前这首。
    ///
    /// 只认「还是这首歌」且当前没有装好的播放项 —— 期间用户切了歌就作废。
    /// 连续失败封顶 4 次：如果是账号级的长时限流，无限重试只会一直撞墙，
    /// 到那时才给一次明确的弹窗，比每隔十几秒偷偷重试有用。
    private func scheduleRateLimitRetry(after delay: TimeInterval, track: Track, autoPlay: Bool) {
        rateLimitRetryTask?.cancel()
        guard rateLimitRetries < 4 else {
            rateLimitRetries = 0
            errorMessage = "服务端持续限流，请过几分钟再试。"
            return
        }
        rateLimitRetries += 1
        rateLimitRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay + 0.5))
            guard !Task.isCancelled, let self else { return }
            guard self.current?.id == track.id, self.player.currentItem == nil else { return }
            await self.loadCurrent(autoPlay: autoPlay, autoSkip: false)
        }
    }

    // MARK: - 锁屏 / 耳机控制

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.player.play()
                self.isPlaying = true
                self.pushNowPlayingInfo()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.player.pause()
                self.isPlaying = false
                self.pushNowPlayingInfo()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            MainActor.assumeIsolated { self?.seek(to: positionEvent.positionTime) }
            return .success
        }
    }

    private func pushNowPlayingInfo() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.name,
            MPMediaItemPropertyArtist: track.artistLine,
            MPMediaItemPropertyAlbumTitle: track.album.name,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artworkImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artworkImage.size) { _ in
                artworkImage
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for track: Track) {
        artworkImage = nil
        guard let url = track.coverURL else { return }
        let trackID = track.id
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            guard self.current?.id == trackID else { return }
            self.artworkImage = image
            self.pushNowPlayingInfo()
        }
    }
}
