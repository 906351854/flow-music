import SwiftUI

/// 迷你播放条。
///
/// `embedded = true` 时用于 `.tabViewBottomAccessory`：玻璃由系统的标签栏容器提供，
/// 这里不能再自己套一层玻璃，否则会出现「玻璃里还有一块玻璃」的重影，
/// 而且会破坏下滑时和标签栏一起下沉的动画。
struct PlayerBar: View {
    let track: Track
    var embedded: Bool = false
    let onTap: () -> Void

    @EnvironmentObject private var player: PlayerService

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(url: track.coverURL, cornerRadius: embedded ? 7 : 9)
                .frame(width: embedded ? 32 : 36, height: embedded ? 32 : 36)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artistLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if player.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.accent)
                    .frame(width: 36, height: 36)
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

            // 上一曲 / 下一曲对称摆放。上一曲沿用系统语义：播过 3 秒先回到开头。
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
        // 嵌入标签栏时系统容器只留了很窄的边，自己再补一段，封面才不会贴着屏幕边。
        .padding(.leading, embedded ? 16 : 10)
        .padding(.trailing, embedded ? 4 : 8)
        .padding(.vertical, embedded ? 0 : 7)
        .modifier(PlayerBarGlass(embedded: embedded))
        .contentShape(.rect)
        .onTapGesture(perform: onTap)
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
