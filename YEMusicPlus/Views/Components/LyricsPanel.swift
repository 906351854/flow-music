import SwiftUI

/// 滚动歌词面板。
///
/// 高亮当前行并自动把它滚到面板中部，点击任意一行跳转到那句。
/// 行内容随 `currentTime` 每 0.4s 刷新一次，做卡拉 OK 级逐字动画不值当，
/// 行级高亮 + 平滑滚动足够看着舒服。
struct LyricsPanel: View {
    let lines: [LyricLine]
    let isLoading: Bool
    let currentTime: Double
    let onSeek: (Double) -> Void

    /// 当前该高亮的行：最后一条 `time <= 当前播放时间` 的歌词。
    private var activeIndex: Int? {
        var result: Int?
        for line in lines where line.time <= currentTime + 0.25 {
            result = line.id
        }
        return result
    }

    var body: some View {
        Group {
            if isLoading {
                Spacer()
                ProgressView()
                    .controlSize(.regular)
                    .tint(Theme.accent)
                Spacer()
            } else if lines.isEmpty {
                Spacer()
                Text("暂无歌词")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
            } else {
                scrollView
            }
        }
        // 上下淡出，行滚进边缘时自然消失。
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.16),
                    .init(color: .black, location: 0.84),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var scrollView: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                // 上下留白约半个面板高，首尾行才有可能滚到正中间。
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(lines) { line in
                        row(line)
                    }
                }
                .padding(.vertical, 150)
                .padding(.horizontal, 4)
            }
            .onChange(of: activeIndex) { _, newValue in
                guard let id = newValue else { return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onAppear {
                // 打开面板时先跳到正在唱的那句，别从第一行开始干瞪眼。
                if let id = activeIndex {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func row(_ line: LyricLine) -> some View {
        let isActive = line.id == activeIndex
        let text = line.text.isEmpty ? "♪" : line.text

        return Text(text)
            .font(.system(size: isActive ? 16.5 : 14.5,
                          weight: isActive ? .semibold : .regular))
            .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.42))
            .lineLimit(3)
            .animation(.easeInOut(duration: 0.28), value: isActive)
            .onTapGesture {
                // 点击任意一行跳到那句 —— 歌词本来就是最好的进度条。
                onSeek(line.time)
            }
    }
}
