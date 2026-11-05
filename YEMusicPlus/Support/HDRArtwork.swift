import SwiftUI
import UIKit
import CoreImage

/// 把普通 SDR 封面提到 EDR（Extended Dynamic Range），让正中那张在 HDR 屏上真的更亮。
///
/// 网易云给的是 sRGB 封面，像素值上限就是 1.0，屏幕上最多显示到「纸白」。
/// 这里在 `extendedLinearDisplayP3` 里做一次曝光提升，亮部会算到 1.0 以上；
/// `CIContext.createCGImage` 在输出色彩空间是 HDR 时会自动给 **16 位浮点**像素，
/// 带宽出来的 headroom 才能被 EDR 屏真正点亮（普通 8 位图会被直接截到 1.0）。
///
/// 为什么不给每张卡都用：CoreImage 处理一张 500×500 只要几毫秒，
/// 但十来张同时做、还要和滑动抢主线程，就会在快速滑动时露馅 ——
/// 这个项目对卡顿零容忍，所以只在正中那一两张上开。
enum HDRArtwork {
    /// 曝光值。0.45 EV ≈ 1.37 倍亮度：高光进入 EDR，暗部只轻微抬起。
    /// 再大就压不住封面的黑，整张会发灰、像隔了层雾。
    static let exposure: Float = 0.45

    /// 真正的 EDR 画布。工作空间和输出空间都必须是 extended linear，
    /// 否则中间计算会被提前裁到 [0,1]，再怎么调曝光也白搭。
    private static let context: CIContext = {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            ?? CGColorSpaceCreateDeviceRGB()
        return CIContext(options: [
            .workingColorSpace: space,
            .outputColorSpace: space,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
        ])
    }()

    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 60
        return cache
    }()

    static func cached(_ url: URL?) -> UIImage? {
        guard let url else { return nil }
        return cache.object(forKey: url as NSURL)
    }

    /// 下载 → 解码 → 提升。整段都在后台，主线程只负责最后贴图。
    static func image(for url: URL?) async -> UIImage? {
        guard let url else { return nil }
        if let hit = cache.object(forKey: url as NSURL) { return hit }

        // 底图复用 ArtworkStore 的缓存：同一张封面不用为了 HDR 再下一次，
        // 600px 的降采样图也足够正中那张（最大 340pt）用。
        guard let raw = await ArtworkStore.shared.image(for: url) else { return nil }

        let lifted = await Task.detached(priority: .userInitiated) {
            boost(raw)
        }.value

        let result = lifted ?? raw
        cache.setObject(result, forKey: url as NSURL)
        return result
    }

    /// 同步提升，只能在后台线程调。
    private static func boost(_ image: UIImage) -> UIImage? {
        guard let source = image.cgImage else { return nil }
        let input = CIImage(cgImage: source)
        let output = input.applyingFilter("CIExposureAdjust", parameters: [
            kCIInputEVKey: exposure,
        ])
        guard let cg = context.createCGImage(output, from: output.extent) else { return nil }

        #if DEBUG
        if #available(iOS 26.0, *) {
            // headroom = 1 说明还是纯 SDR；> 1 才代表这张图真的带上了 EDR 高光。
            NSLog("[HDR] %dx%d headroom=%.2f",
                  cg.width, cg.height, cg.contentHeadroom)
        }
        #endif

        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }
}

/// 用了 EDR 提升的封面。视觉上和 `ArtworkView` 一致，只是图层允许高动态范围。
struct HDRArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 16

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
                        .interpolation(.high)
                        .scaledToFill()
                        // 不加这一句，系统会按 SDR 处理，headroom 被 tone map 掉，
                        // 前面那一整套 EDR 就白做了。
                        .allowedDynamicRange(.high)
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: url) {
                if let hit = HDRArtwork.cached(url) {
                    image = hit
                    return
                }
                let loaded = await HDRArtwork.image(for: url)
                withAnimation(.easeOut(duration: 0.22)) {
                    image = loaded
                }
            }
    }
}
