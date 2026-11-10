import SwiftUI

/// 迷你播放条。
///
/// `embedded = true` 时用于 `.tabViewBottomAccessory`：玻璃由系统的标签栏容器提供，
/// 这里不能再自己套一层玻璃，否则会出现「玻璃里还有一块玻璃」的重影，
/// 而且会破坏下滑时和标签栏一起下沉的动画。
struct PlayerBar: View {
    /// 当前曲目。为 nil 时播放条依然常驻（空态占位，控制键禁用）——
    /// 底部形态固定，开始/结束播放时整页布局不会跟着上下跳一格。
    let track: Track?
    var embedded: Bool = false
    let onTap: () -> Void

    @EnvironmentObject private var player: PlayerService

    private var artSide: CGFloat { embedded ? 32 : 36 }

    var body: some View {
        HStack(spacing: 10) {
            artwork

            VStack(alignment: .leading, spacing: 1) {
                Text(track?.name ?? "未在播放")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(track == nil ? 0.72 : 1))
                    .lineLimit(1)
                Text(track?.artistLine ?? "点这里挑一首歌")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // 控制区三键等距排列：两侧按键同宽（30），播放键（36）居中，
            // 播放键的圆心正好落在上一曲和下一曲的连线中点上。
            HStack(spacing: 7) {
                // 上一曲沿用系统语义：播过 3 秒先回到开头。
                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(width: 30, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)

                Group {
                    if player.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.accent)
                            .frame(width: 30, height: 30)
                            .padding(3)
                    } else {
                        Button {
                            player.togglePlayPause()
                        } label: {
                            // 进度不再画在底部当一条细线，改成绕着播放键的一圈：
                            // 底圈常驻（不然没播的时候按钮会飘着没轮廓），
                            // 进度弧从 12 点顺时针长出去，和 App Store 的下载圈一个路子。
                            ZStack {
                                Circle()
                                    .stroke(.white.opacity(0.16), lineWidth: 2)

                                Circle()
                                    .trim(from: 0, to: player.progress)
                                    .stroke(
                                        Theme.accent,
                                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                                    )
                                    .rotationEffect(.degrees(-90))
                                    // 播放器每 0.4s 报一次时间，这里用同样时长线性补间，
                                    // 弧才是匀速爬，而不是一格一格跳。
                                    .animation(.linear(duration: 0.4), value: player.progress)

                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 30, height: 30)
                            .padding(3)
                            .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(width: 30, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            // 空态下三键只做占位，不接事件：点整条都归外层的 onTap（去搜索）。
            .opacity(track == nil ? 0.38 : 1)
            .allowsHitTesting(track != nil)
        }
        // 嵌入标签栏时系统容器只留了很窄的边，自己再补一段，封面才不会贴着屏幕边。
        // 控制区整体再往左挪一点，别贴着胶囊右缘。
        .padding(.leading, embedded ? 16 : 10)
        .padding(.trailing, embedded ? 16 : 18)
        .padding(.vertical, embedded ? 0 : 7)
        .modifier(PlayerBarGlass(embedded: embedded))
        .contentShape(.rect)
        .onTapGesture(perform: onTap)
    }

    /// 封面。没有曲目时给一块占位玻璃砖 —— 高度和真封面一致，
    /// 常驻的播放条不会因为空态而变矮。
    @ViewBuilder
    private var artwork: some View {
        if let track {
            ArtworkView(url: track.coverURL, cornerRadius: embedded ? 7 : 9)
                .frame(width: artSide, height: artSide)
        } else {
            RoundedRectangle(cornerRadius: embedded ? 7 : 9, style: .continuous)
                .fill(.white.opacity(0.10))
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(width: artSide, height: artSide)
        }
    }
}

/// 只在非嵌入模式下自绘玻璃胶囊。
private struct PlayerBarGlass: ViewModifier {
    let embedded: Bool

    func body(content: Content) -> some View {
        if embedded {
            content
        } else {
            content
                .glassEffect(.regular.interactive(),
                             in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}
