import SwiftUI
import UIKit

/// 统一封面视图：先铺占位色，图片到了叠上去，最后一起裁圆角。
/// 用 Rectangle 做底是为了让它在任何父容器里都能自适应尺寸。
///
/// 图片走 `ArtworkStore` 的内存缓存：滚出屏幕再滚回来时直接出图，
/// 不会重新下载解码 —— 大歌单快速滑动靠的就是这个。
struct ArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 12

    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.07))
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.22))
            }
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            // id 用 url：同一格换了歌（List 复用行）时重新取图。
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            image = nil
            return
        }
        // 命中缓存就同步出图，避免先闪一帧占位。
        if let hit = ArtworkStore.shared.cached(url) {
            image = hit
            return
        }
        image = nil
        let loaded = await ArtworkStore.shared.image(for: url)
        guard !Task.isCancelled else { return }
        image = loaded
    }
}
