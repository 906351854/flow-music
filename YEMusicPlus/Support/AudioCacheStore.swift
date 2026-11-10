import Foundation
import os.log

/// 音频磁盘缓存。
///
/// 目标很具体：让「听过一遍的歌」第二次播放时完全不碰网络，
/// 既省流量，也绕开最容易被 -460 风控盯上的取流接口。
///
/// 几条设计约束：
/// - **key = `trackID-音质档位`**：同一首歌不同音质是两个文件，换档位不会互相污染；
/// - **落盘在 Caches/audio-cache**：系统空间紧张时可回收，不进 iCloud 备份，
///   符合「临时缓存」而非「下载曲库」的定位；
/// - **只缓存完整文件**：先下到临时路径、校验大小后再原子搬进来，
///   半个文件留在缓存里会导致「这首歌永远播到一半就断」；
/// - **LRU 淘汰**：命中时刷新修改时间，超容量从最久未播放的开始删。
@MainActor
final class AudioCacheStore: ObservableObject {

    static let shared = AudioCacheStore()

    enum Key {
        static let enabled = "cache.audio.enabled"
        static let capMB = "cache.audio.capMB"
    }

    /// 已用空间（字节）。
    @Published private(set) var usedBytes: Int = 0
    /// 缓存的曲目数。
    @Published private(set) var fileCount: Int = 0

    private let fm = FileManager.default
    private let root: URL
    /// key → 本地文件。
    private var index: [String: URL] = [:]
    /// 正在下载的 key，避免同一首重复排队。
    private var inflight: Set<String> = []

    /// 只认这些扩展名，其余一律按 mp3 存 —— AVPlayer 靠扩展名判断容器格式，
    /// 存成 `.audio` 这类未知扩展名会直接播不了。
    private static let allowedExtensions: Set<String> = ["mp3", "flac", "m4a", "aac", "ogg", "wav"]

    init() {
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("audio-cache", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        scan()
    }

    // MARK: - 设置

    /// 关闭后不再缓存新歌；已经缓存下来的仍然可以播，由用户自己决定何时清空。
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true
    }

    var capMB: Int {
        UserDefaults.standard.object(forKey: Key.capMB) as? Int ?? 512
    }

    var capBytes: Int { capMB * 1024 * 1024 }

    // MARK: - 查询

    /// 命中返回可直接交给 AVPlayer 的本地文件。顺带刷新 LRU 时间戳。
    func cachedURL(forKey key: String) -> URL? {
        guard let url = index[key] else { return nil }
        guard fm.fileExists(atPath: url.path) else {
            index.removeValue(forKey: key)
            return nil
        }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    // MARK: - 写入

    /// 把一个**确认可完整播放**的音频地址排进下载队列。
    /// 调用点负责过滤试听片段 —— 试听进了缓存，以后就永远只能听 30 秒。
    func cache(url: URL, key: String) {
        guard isEnabled, index[key] == nil, !inflight.contains(key) else { return }
        inflight.insert(key)

        let ext = url.pathExtension.lowercased()
        let fileExt = Self.allowedExtensions.contains(ext) ? ext : "mp3"
        let dest = root.appendingPathComponent("\(key).\(fileExt)")

        var request = URLRequest(url: url)
        // 网易 CDN 对空 UA 的请求偶尔返回 403，带上和播放器一致的标识。
        request.setValue(AppConfig.shared.client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(AppConfig.shared.upstream.referer, forHTTPHeaderField: "Referer")
        request.timeoutInterval = 60

        Task {
            defer { inflight.remove(key) }
            do {
                let (tmp, response) = try await URLSession.shared.download(for: request)
                defer { try? fm.removeItem(at: tmp) }

                if let http = response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) {
                    return
                }

                let size = ((try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? Int) ?? 0
                // 小于 128KB 的响应基本是错误页或极短的试听，进缓存弊大于利。
                guard size > 128 * 1024 else { return }

                try? fm.removeItem(at: dest)
                try fm.moveItem(at: tmp, to: dest)
                index[key] = dest
                scan()
                evictIfNeeded()
            } catch {
                // 缓存失败不该影响正在进行的播放，静默即可。
                Self.log.debug("音频缓存失败 \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - 清理

    func remove(forKey key: String) {
        guard let url = index.removeValue(forKey: key) else { return }
        try? fm.removeItem(at: url)
        scan()
    }

    func clear() {
        let files = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? fm.removeItem(at: file)
        }
        index.removeAll()
        scan()
    }

    /// 容量被调小后调用；没超限时什么也不做。
    func enforceLimit() {
        evictIfNeeded()
    }

    // MARK: - 内部

    /// 重建索引与用量。文件数量是几十到几百的量级，全量扫一遍足够便宜。
    private func scan() {
        var total = 0
        var map: [String: URL] = [:]
        let keys: Set<URLResourceKey> = [.fileSizeKey]

        let files = (try? fm.contentsOfDirectory(at: root,
                                                 includingPropertiesForKeys: Array(keys))) ?? []
        for file in files {
            let size = (try? file.resourceValues(forKeys: keys))?.fileSize ?? 0
            total += size
            map[file.deletingPathExtension().lastPathComponent] = file
        }

        index = map
        usedBytes = total
        fileCount = map.count
    }

    private func evictIfNeeded() {
        guard usedBytes > capBytes else { return }

        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let files = (try? fm.contentsOfDirectory(at: root,
                                                 includingPropertiesForKeys: Array(keys))) ?? []
        let ordered = files
            .compactMap { file -> (URL, Date)? in
                let date = (try? file.resourceValues(forKeys: keys))?.contentModificationDate
                return (file, date ?? .distantPast)
            }
            .sorted { $0.1 < $1.1 }

        for (file, _) in ordered {
            guard usedBytes > capBytes else { break }
            let size = ((try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int) ?? 0
            try? fm.removeItem(at: file)
            usedBytes -= size
            index.removeValue(forKey: file.deletingPathExtension().lastPathComponent)
        }

        scan()
    }

    private static let log = Logger(subsystem: "com.zed.yemusicplus", category: "AudioCache")
}
