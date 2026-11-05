import SwiftUI

struct TrackRow: View {
    let track: Track
    var index: Int?
    let isCurrent: Bool
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                if let index {
                    Text("\(index)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(isCurrent ? Theme.accent : Theme.tertiaryText)
                        .frame(width: 24, alignment: .center)
                        .monospacedDigit()
                }

                ArtworkView(url: track.coverURL, cornerRadius: 8)
                    .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(track.name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(isCurrent ? Theme.accent : .white)
                            .lineLimit(1)
                        if track.needsVip {
                            Text("VIP")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Theme.accent.opacity(0.16), in: Capsule())
                        }
                    }
                    Text(track.subtitleLine)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(track.durationText)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.tertiaryText)
                    .monospacedDigit()
            }
            .padding(.vertical, 7)
            // 不给这个 HStack 一个「填满可用宽度」的约束时，SwiftUI 会按
            // 最长那行文字的理想宽度去排版 —— 中英混排的长副标题能把整行
            // 撑到屏幕外，结果是左边的序号和封面被裁掉、右边时长跑出边界。
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
