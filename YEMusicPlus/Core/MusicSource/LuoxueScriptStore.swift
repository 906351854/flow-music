import Foundation

/// 音源脚本的本地仓库。
///
/// 脚本就是一个 .js 文件，放在 `Application Support/luoxue/` 下。
/// 这样「换音源」等于「换一个文件」，不需要重新发版 —— 音源失效是常态，
/// 社区通常几天就能修好，用户只要把新脚本丢进来就能继续用。
final class LuoxueScriptStore {

    static let shared = LuoxueScriptStore()

    private let fileManager = FileManager.default
    private let activeKey = "flow.luoxue.activeScript"

    private var directory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("luoxue", isDirectory: true)
    }

    private init() {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - 读

    var activeName: String? {
        get { UserDefaults.standard.string(forKey: activeKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: activeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: activeKey)
            }
        }
    }

    func script(named name: String) -> String? {
        let url = directory.appendingPathComponent("\(name).js")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func hasScript(named name: String) -> Bool {
        fileManager.fileExists(atPath: directory.appendingPathComponent("\(name).js").path)
    }

    /// 已安装的脚本名（按文件名排序）。
    func installedNames() -> [String] {
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "js" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    var directoryPath: String { directory.path }

    // MARK: - 写

    @discardableResult
    func save(script: String, named name: String) throws -> String {
        let safe = Self.sanitize(name)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(safe).js")
        try script.write(to: url, atomically: true, encoding: .utf8)
        return safe
    }

    func remove(named name: String) {
        let url = directory.appendingPathComponent("\(name).js")
        try? fileManager.removeItem(at: url)
        if activeName == name { activeName = nil }
    }

    // MARK: - 下载

    /// 在线导入：把一个 URL 上的脚本抓下来存盘。
    func download(urlString: String, name hint: String? = nil) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw LuoxueError.scriptFailed("脚本地址不合法")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("FlowMusic/luoxue", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LuoxueError.scriptFailed("下载失败（HTTP \(http.statusCode)）")
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw LuoxueError.scriptFailed("脚本内容为空")
        }
        guard text.count > 200 else {
            throw LuoxueError.scriptFailed("下载到的内容不像音源脚本")
        }

        let name = Self.sanitize(hint ?? Self.guessName(from: text) ?? url.lastPathComponent)
        try save(script: text, named: name)
        return name
    }

    /// 脚本头部注释里通常有 `@name`，用它当文件名更好认。
    static func guessName(from script: String) -> String? {
        let head = script.prefix(1200)
        for line in head.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("* @name") || trimmed.hasPrefix("@name") {
                let value = trimmed
                    .replacingOccurrences(of: "* @name", with: "")
                    .replacingOccurrences(of: "@name", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.isEmpty ? "source-\(Int(Date().timeIntervalSince1970))" : cleaned
    }
}
