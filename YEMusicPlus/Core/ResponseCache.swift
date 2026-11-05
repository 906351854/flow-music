import Foundation

/// 极简磁盘缓存：把接口返回的原始 JSON 落到 Caches 目录。
///
/// 存在的唯一理由是**降低请求频率**。调试时 App 会被反复启动，
/// 每次启动都重新拉一遍每日推荐，既慢又容易把设备标识推进风控名单。
/// 缓存的是原始 data，所以不需要给模型再加 Encodable。
enum ResponseCache {

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("api-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 命中就返回，过期或不存在返回 nil。
    static func data(for key: String, maxAge: TimeInterval) -> Data? {
        let url = fileURL(key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < maxAge,
              let data = try? Data(contentsOf: url),
              !data.isEmpty
        else { return nil }
        return data
    }

    static func store(_ data: Data, for key: String) {
        guard !data.isEmpty else { return }
        try? data.write(to: fileURL(key), options: .atomic)
    }

    private static func fileURL(_ key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
        return directory.appendingPathComponent(safe).appendingPathExtension("json")
    }
}
