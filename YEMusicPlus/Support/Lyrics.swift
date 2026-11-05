import Foundation

/// 一行歌词：出现时间 + 文本。
struct LyricLine: Identifiable, Equatable {
    /// 在整份歌词里的序号，兼作滚动定位的 id。
    let id: Int
    /// 出现时间（秒）。
    let time: Double
    let text: String
}

/// 标准 LRC 解析。支持一行多个时间标签（`[00:12.00][01:30.00]同词`），
/// `[ti:][ar:]` 这类元数据不带时间，自然被跳过。
enum LRC {
    static func parse(_ raw: String) -> [LyricLine] {
        // 形如 [mm:ss]、[mm:ss.xx]、[mm:ss.xxx] 的时间标签。
        let pattern = #"\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var stamped: [(t: Double, text: String)] = []
        for rawLine in raw.components(separatedBy: .newlines) {
            let ns = rawLine as NSString
            let matches = regex.matches(in: rawLine,
                                        range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.upperBound)
                .trimmingCharacters(in: .whitespaces)

            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var fraction = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let digits = ns.substring(with: m.range(at: 3))
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                stamped.append((minutes * 60 + seconds + fraction, text))
            }
        }

        // 网易给的 LRC 偶尔乱序，按时间重排再编号。
        return stamped
            .sorted { $0.t < $1.t }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.t, text: $0.element.text) }
    }
}

/// 歌词的取回与内存缓存。同一首歌在一次运行里只打一次接口，
/// 并发请求合并成同一个 Task。
final class LyricsStore: @unchecked Sendable {
    static let shared = LyricsStore()

    private let cache = NSCache<NSNumber, NSArray>()
    private var inflight: [Int: Task<[LyricLine], Never>] = [:]
    private let lock = NSLock()

    func lines(for trackID: Int) async -> [LyricLine] {
        lock.lock()
        if let hit = cache.object(forKey: NSNumber(value: trackID)) as? [LyricLine] {
            lock.unlock()
            return hit
        }
        // 已经有人在路上 → 搭同一班车，不重复发请求。
        if let running = inflight[trackID] {
            lock.unlock()
            return await running.value
        }
        let task = Task { [trackID] in
            let raw = (try? await MusicAPI.lyric(id: trackID)) ?? ""
            return LRC.parse(raw)
        }
        inflight[trackID] = task
        lock.unlock()

        let lines = await task.value
        lock.lock()
        inflight[trackID] = nil
        // 没词的（纯音乐）也缓存，免得每开一次面板都重新打接口。
        cache.setObject(lines as NSArray, forKey: NSNumber(value: trackID))
        lock.unlock()
        return lines
    }
}
