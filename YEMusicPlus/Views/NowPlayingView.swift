import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject private var player: PlayerService

    /// 拖动进度条期间的本地值：手指位置优先于播放时钟，
    /// 否则 time observer 每秒更新会和拖动抢滑块，来回跳。
    @State private var isScrubbing = false
    @State private var scrubProgress: Double = 0

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(spacing: 20) {
                    header
                    artwork
                    titleBlock
                    progressBlock
                    transportControls
                    secondaryControls
                    if let notice = player.notice {
                        Text(notice)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.accent.opacity(0.9))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Theme.accent.opacity(0.12), in: Capsule())
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 46)
                .padding(.bottom, 40)
            }
        }
        // 和「选择歌单」同款的弹出样式：大档 sheet + 拖拽指示条，
        // 往下一滑就能关 —— 不再是钉死在全屏上的整页。
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 组件

    /// 头部：标题居中（关闭全靠下滑/拖拽指示条，不设关闭钮）。
    private var header: some View {
        VStack(spacing: 4) {
            Text("正在播放")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            // 副标题不重复歌手名（下面 titleBlock 已经有了），显示队列来源。
            Text(player.queueSource.name.isEmpty ? "来自播放队列" : "来自「\(player.queueSource.name)」")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 组件

    private var artwork: some View {
        ArtworkView(url: player.current?.coverURL, cornerRadius: 26)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 330)
            .shadow(color: .black.opacity(0.45), radius: 28, y: 16)
    }

    private var titleBlock: some View {
        VStack(spacing: 5) {
            Text(player.current?.name ?? "未在播放")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(player.current?.artistLine ?? "")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)

            if let level = player.streamLevel {
                Text(level.uppercased())
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
                    .padding(.top, 2)
            }
        }
    }

    private var progressBlock: some View {
        VStack(spacing: 7) {
            // 原生 Slider：iOS 26+ 自动获得液态玻璃滑块（弹性拇指、按压高亮、
            // 跟手插值），不用自绘。拖动时走本地 scrubProgress，松手才真正 seek ——
            // 之前自绘进度条只响应「点击落点」，既不能拖、也一步跳到位，所以生硬。
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubProgress : player.progress },
                    set: { newValue in
                        scrubProgress = newValue
                        isScrubbing = true
                    }
                ),
                in: 0...1
            ) { editing in
                if !editing {
                    player.seek(fraction: scrubProgress)
                    isScrubbing = false
                }
            }
            .tint(Theme.accent)

            HStack {
                Text(Self.timeText(isScrubbing ? scrubProgress * player.duration : player.currentTime))
                Spacer()
                Text(Self.timeText(player.duration))
            }
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(Theme.tertiaryText)
            .monospacedDigit()
        }
    }

    private var transportControls: some View {
        HStack(spacing: 24) {
            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    // 液态玻璃：interactive 才有按压回弹的玻璃手感。
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)

            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    if player.isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 25, weight: .semibold))
                            // 主题色图标压在玻璃上 —— 主按钮的层级感。
                            .foregroundStyle(Theme.accent)
                            // 符号替换过渡：播放↔暂停不是生硬换图，
                            // 是 SF Symbols 的 dissolve/位移替换动画。
                            .contentTransition(.symbolEffect(.replace))
                            .animation(.spring(duration: 0.32), value: player.isPlaying)
                    }
                }
                .frame(width: 68, height: 68)
                // 主按钮更大，图标用主题色压在玻璃上做层级。
                .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var secondaryControls: some View {
        HStack(spacing: 10) {
            // 一键单曲循环：不用在轮换按钮上点两趟才能到。
            // 开着再点一次回到之前的模式（见 toggleRepeatOne）。
            iconPillButton(
                icon: "repeat.1",
                highlighted: player.repeatMode == .one
            ) {
                player.toggleRepeatOne()
            }

            pillButton(
                icon: player.repeatMode.symbol,
                label: player.repeatMode.label,
                highlighted: player.repeatMode != .off
            ) {
                player.cycleRepeatMode()
            }

            pillButton(
                icon: "shuffle",
                label: player.isShuffled ? "随机开" : "随机关",
                highlighted: player.isShuffled
            ) {
                player.isShuffled.toggle()
            }

            Menu {
                ForEach(AppConfig.shared.quality.levels) { level in
                    Button {
                        player.qualityLevel = level.id
                    } label: {
                        Label(level.name, systemImage: player.qualityLevel == level.id ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .semibold))
                    Text(player.qualityLabel)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: Capsule())
            }
        }
    }

    private func pillButton(icon: String, label: String, highlighted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(highlighted ? Theme.accent : .white.opacity(0.65))
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 纯图标的玻璃圆钮 —— 行宽放不下第四枚带字胶囊时用这个。
    private func iconPillButton(icon: String, highlighted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(highlighted ? Theme.accent : .white.opacity(0.65))
                .padding(10)
                .glassEffect(.regular, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
