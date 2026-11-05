import SwiftUI

/// 滚动歌词面板。
///
/// 视觉上和首页的封面流一个路子：当前行最大最亮，往外每一行
/// 按距离逐级缩小、变淡，像一张摊开的牌堆 —— 只是没有翻转。
/// 上下渐隐不在这里做：面板的材质和歌词共用同一层羽化 mask
/// （在 HomeView 里），文字是溶进那团无边界的模糊里去的。
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
    }

    private var scrollView: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                // 上下留白约 1/4 面板高，首尾行才有可能滚到正中间。
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(lines) { line in
                        row(line)
                    }
                }
                .padding(.vertical, 160)
                .padding(.horizontal, 6)
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

    /// 一行歌词。离当前行越远，越小越淡 —— 封面流的衰减曲线搬到文字上：
    /// 相邻行缩 10%、再往外每级递减，五级以外封底，只留一点余光。
    private func row(_ line: LyricLine) -> some View {
        let isActive = line.id == activeIndex
        let distance = activeIndex.map { abs(line.id - $0) } ?? 3
        let falloff = pow(0.90, CGFloat(min(distance, 5)))
        let dimness: Double = isActive
            ? 1.0
            : max(0.16, 0.46 - Double(distance) * 0.09)
        let text = line.text.isEmpty ? "♪" : line.text

        return Text(text)
            .font(.system(size: isActive ? 17 : 15,
                          weight: isActive ? .semibold : .regular))
            .foregroundStyle(isActive ? Color.white : Color.white.opacity(dimness))
            .lineLimit(3)
            // 锚在行首缩放，左对齐不散架 —— 行本身的占位不变，
            // 缩小只是视觉上的退后，不会把下面的行顶来顶去。
            .scaleEffect(falloff, anchor: .leading)
            .animation(.easeInOut(duration: 0.3), value: activeIndex)
            .onTapGesture {
                // 点击任意一行跳到那句 —— 歌词本来就是最好的进度条。
                onSeek(line.time)
            }
    }
}
