import Foundation

/// 落雪音源的对外门面：负责「找脚本 → 跑起来 → 取一条能播的地址」。
///
/// 设计上有意做成「按顺序试」：音源失效太频繁，把候选脚本排成一个列表，
/// 第一个能初始化的就启用，用户不用关心是哪一个在工作。
final class LuoxueMusicSource {

    static let shared = LuoxueMusicSource()

    private let runtime = LuoxueRuntime()
    private let store = LuoxueScriptStore.shared
    private let lock = NSLock()

    private var info: LuoxueScriptInfo?
    private var loading: Task<LuoxueScriptInfo, Error>?
    private(set) var lastError: String?

    private var config: AppConfig.Playback.Luoxue? {
        AppConfig.shared.playback?.luoxue
    }

    /// 当前生效的脚本名与它支持的源，设置页要显示。
    var activeDescription: String {
        lock.lock(); defer { lock.unlock() }
        guard let info else { return "未加载" }
        let sources = info.sources.keys.sorted().joined(separator: "/")
        return "\(info.scriptName) · \(sources)"
    }

    // MARK: - 加载

    func ensureLoaded() async throws -> LuoxueScriptInfo {
        lock.lock()
        if let info {
            lock.unlock()
            return info
        }
        if let loading {
            lock.unlock()
            return try await loading.value
        }
        let task = Task<LuoxueScriptInfo, Error> { try await self.performLoad() }
        loading = task
        lock.unlock()

        do {
            let result = try await task.value
            lock.lock()
            info = result
            loading = nil
            lastError = nil
            lock.unlock()
            return result
        } catch {
            lock.lock()
            loading = nil
            lastError = error.localizedDescription
            lock.unlock()
            throw error
        }
    }

    /// 强制换脚本重来（设置页「重新加载音源」用）。
    func reload() async throws -> LuoxueScriptInfo {
        lock.lock()
        info = nil
        loading = nil
        lock.unlock()
        return try await ensureLoaded()
    }

    /// 手动指定启用某个已安装脚本。
    func activate(scriptNamed name: String) async throws -> LuoxueScriptInfo {
        store.activeName = name
        return try await reload()
    }

    private func performLoad() async throws -> LuoxueScriptInfo {
        let candidates = await candidateScripts()
        guard !candidates.isEmpty else {
            throw LuoxueError.scriptFailed("没有可用的音源脚本（下载失败或列表为空）")
        }

        var failures: [String] = []
        for (name, script) in candidates {
            do {
                let loaded = try await runtime.load(script: script, scriptName: name)
                store.activeName = name
                NSLog("[luoxue] 已启用脚本 \(name)，支持源：\(loaded.sources.keys.sorted())")
                return loaded
            } catch {
                let message = "\(name)：\(error.localizedDescription)"
                failures.append(message)
                NSLog("[luoxue] 加载失败 \(message)")
            }
        }

        throw LuoxueError.scriptFailed("所有音源都不可用\n" + failures.joined(separator: "\n"))
    }

    /// 内置脚本的落盘名。打包时带一份已验证可用的脚本，
    /// 这样首次启动（或 GitHub 不可达）也能直接播，不用先等下载。
    private static let bootstrapName = "bootstrap"

    /// 本地已装的优先，缺的按配置里的地址下载。
    private func candidateScripts() async -> [(String, String)] {
        var result: [(String, String)] = []
        var seen = Set<String>()

        // 1. 用户当前选中的脚本
        if let active = store.activeName,
           let text = store.script(named: active),
           !text.isEmpty {
            result.append((active, text))
            seen.insert(active)
        }

        // 2. 内置脚本兜底
        seedBundledScriptIfNeeded()
        if !seen.contains(Self.bootstrapName),
           let text = store.script(named: Self.bootstrapName),
           !text.isEmpty {
            result.append((Self.bootstrapName, text))
            seen.insert(Self.bootstrapName)
        }

        // 3. 配置里的候选脚本
        for entry in (config?.scripts ?? []) {
            let name = LuoxueScriptStore.sanitize(entry.name)
            if seen.contains(name) { continue }

            if let text = store.script(named: name), !text.isEmpty {
                result.append((name, text))
                seen.insert(name)
                continue
            }

            do {
                let saved = try await store.download(urlString: entry.url, name: name)
                if let text = store.script(named: saved), !text.isEmpty {
                    result.append((saved, text))
                    seen.insert(saved)
                }
            } catch {
                NSLog("[luoxue] 下载 \(entry.name) 失败：\(error.localizedDescription)")
            }
        }

        return result
    }

    private func seedBundledScriptIfNeeded() {
        guard !store.hasScript(named: Self.bootstrapName) else { return }
        guard let url = Bundle.main.url(forResource: "luoxue-bootstrap", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              text.count > 200 else { return }
        try? store.save(script: text, named: Self.bootstrapName)
        NSLog("[luoxue] 已释放内置脚本到 \(store.directoryPath)")
    }

    // MARK: - 取流

    func musicURL(for track: Track, level: String) async throws -> String {
        let loaded = try await ensureLoaded()
        let key = config?.sourceKey ?? "wy"
        guard let qualities = loaded.sources[key] else {
            throw LuoxueError.noSource(key)
        }
        let wanted = config?.qualityMap[level] ?? "320k"
        let quality = Self.pickQuality(wanted: wanted, available: qualities)
        let musicInfo = Self.musicInfo(for: track)
        return try await runtime.musicURL(source: key, quality: quality, musicInfo: musicInfo)
    }

    /// 音质从高到低。落雪脚本只认这几个标识。
    private static let qualityRank = ["128k", "320k", "flac", "flac24bit", "master"]

    /// 要的那档没有时，退到「不超过它的最高一档」；全都比它低就取最低可用。
    static func pickQuality(wanted: String, available: [String]) -> String {
        let valid = available
            .filter { qualityRank.contains($0) }
            .sorted { rank($0) < rank($1) }
        guard !valid.isEmpty else { return wanted }

        guard let want = qualityRank.firstIndex(of: wanted) else {
            return valid.last ?? wanted
        }
        let lower = valid.filter { (qualityRank.firstIndex(of: $0) ?? -1) <= want }
        return lower.last ?? valid.first ?? wanted
    }

    private static func rank(_ quality: String) -> Int {
        qualityRank.firstIndex(of: quality) ?? -1
    }

    /// 落雪脚本拿到的 `musicInfo`。字段名沿用 LX 的约定：
    /// 网易云源认 `songmid`，其它平台认 `hash`，两个都给上更稳。
    static func musicInfo(for track: Track) -> [String: Any] {
        var info: [String: Any] = [
            "songmid": String(track.id),
            "songId": track.id,
            "id": track.id,
            "name": track.name,
            "singer": track.artistLine,
            "albumName": track.album.name,
            "albumId": track.album.id,
            "interval": track.durationMS / 1000,
            "duration": track.durationMS,
        ]
        if let pic = track.album.picUrl, !pic.isEmpty {
            info["picUrl"] = pic
        }
        return info
    }
}
