import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject private var player: PlayerService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(spacing: 20) {
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
                .padding(.top, 56)
                .padding(.bottom, 40)
            }
            .softTopEdge()
        }
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 20)
            .padding(.top, 6)
        }
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
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.14))
                        .frame(height: 5)
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(5, geo.size.width * player.progress), height: 5)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            player.seek(fraction: value.location.x / max(geo.size.width, 1))
                        }
                )
            }
            .frame(height: 22)

            HStack {
                Text(Self.timeText(player.currentTime))
                Spacer()
                Text(Self.timeText(player.duration))
            }
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(Theme.tertiaryText)
            .monospacedDigit()
        }
    }

    private var transportControls: some View {
        HStack(spacing: 34) {
            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 23))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 68, height: 68)
                    if player.isLoading {
                        ProgressView().tint(Theme.base)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Theme.base)
                    }
                }
            }
            .buttonStyle(.plain)

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 23))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private var secondaryControls: some View {
        HStack(spacing: 10) {
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

    private static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
