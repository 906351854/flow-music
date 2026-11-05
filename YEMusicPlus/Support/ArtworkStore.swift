import UIKit

/// 封面图的内存缓存。
///
/// 存在的理由是「滚出去再滚回来」：歌单动辄几百首，列表往下滑十屏再滑回来，
/// 如果用 `AsyncImage`，每一张重新出现都要再走一遍 URLSession + 解码。
/// 大歌单快速滑动时几十次解码排在主线程上，手感立刻就钝了。
///
/// 这里做三件事：
/// 1. 解码后的 `UIImage` 进 `NSCache`（数量 + 字节双上限），命中时同步出图，不闪；
/// 2. 下载和解码全在后台，主线程只贴图；
/// 3. 同一个 URL 的并发请求合并成一个 Task —— 预取和显示同时要同一张图时不会下两遍。
final class ArtworkStore: @unchecked Sendable {

    static let shared = ArtworkStore()

    /// 统一降到这个边长。封面流最大也就 340pt（@3x ≈ 1020px），
    /// 但 600px 在 3x 屏上已经看不出差别，内存只要 1/3。
    private static let pixelSize: CGFloat = 600

    private let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 240
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    private let session: URLSession
    private let lock = NSLock()
    private var inflight: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        let conf = URLSessionConfiguration.default
        conf.timeoutIntervalForRequest = 20
        conf.timeoutIntervalForResource = 40
        // 封面 URL 带 CDN 签名，同一次运行内不会变，交给 URLCache 兜一层。
        conf.requestCachePolicy = .returnCacheDataElseLoad
        conf.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024,
                                 diskCapacity: 128 * 1024 * 1024)
        session = URLSession(configuration: conf)
    }

    /// 同步取。命中时直接返回，视图可以第一帧就画出来，不会先闪一下占位。
    func cached(_ url: URL?) -> UIImage? {
        guard let url else { return nil }
        return cache.object(forKey: url as NSURL)
    }

    /// 异步取。同一个 URL 同时被多个视图请求时只下载一次。
    func image(for url: URL?) async -> UIImage? {
        guard let url else { return nil }
        if let hit = cached(url) { return hit }

        lock.lock()
        let task: Task<UIImage?, Never>
        if let existing = inflight[url] {
            task = existing
        } else {
            task = Task.detached(priority: .utility) { [weak self] in
                await self?.download(url)
            }
            inflight[url] = task
        }
        lock.unlock()

        let image = await task.value

        lock.lock()
        inflight[url] = nil
        lock.unlock()

        return image
    }

    private func download(_ url: URL) async -> UIImage? {
        guard let (data, _) = try? await session.data(from: url),
              let raw = UIImage(data: data) else { return nil }

        // 降采样也在后台做。`preparingThumbnail` 走的是 ImageIO 的缩略图路径，
        // 比把原图解码再缩放省一半以上的内存峰值。
        let image = raw.preparingThumbnail(of: CGSize(width: Self.pixelSize,
                                                      height: Self.pixelSize)) ?? raw

        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
        return image
    }
}
