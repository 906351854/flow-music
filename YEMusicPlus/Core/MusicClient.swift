import Foundation
import os.log

enum MusicAPIError: LocalizedError {
    case http(Int)
    case business(code: Int, message: String?)
    case needLogin
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .http(let code):
            return "网络错误（HTTP \(code)）"
        case .business(let code, let message):
            if let message, !message.isEmpty { return message }
            switch code {
            case -110: return "该曲目暂无可用播放地址（可能需要登录或会员）"
            case -460: return "被风控拦截（-460），请更换网络后重试"
            case 301: return "需要登录"
            default: return "接口错误（\(code)）"
            }
        case .needLogin:
            return "请先在「资料库」里扫码登录"
        case .decoding(let detail):
            return "数据解析失败：\(detail)"
        case .transport(let detail):
            return "请求失败：\(detail)"
        }
    }
}

/// 传输层：自己管 Cookie jar，负责 eapi 加密请求。
///
/// 刻意关掉 URLSession 的自动 Cookie 处理 —— 需要把 `MUSIC_U` 手动塞进
/// Cookie 头、并从 `Set-Cookie` 里手动吸收，否则扫码登录后的会话拿不到。
final class MusicClient {

    static let shared = MusicClient()

    private static let log = Logger(subsystem: "com.zed.yemusicplus", category: "api")

    let config: AppConfig

    private let session: URLSession
    private let lock = NSLock()
    private var cookies: [String: String] = [:]

    private(set) var deviceID: String
    private let deviceIDFileURL: URL?
    private let cookieFileURL: URL?

    init() {
        let cfg = AppConfig.shared
        config = cfg

        let conf = URLSessionConfiguration.default
        conf.httpShouldSetCookies = false
        conf.httpCookieAcceptPolicy = .never
        conf.timeoutIntervalForRequest = 20
        conf.timeoutIntervalForResource = 40
        session = URLSession(configuration: conf)

        // deviceId 必须稳定且唯一：全装共用一个常量会被判定成「根本不是设备」。
        // 它不是密钥，所以存普通文件、不进钥匙串。
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let deviceURL = support.appendingPathComponent("device-id")
        deviceIDFileURL = deviceURL
        if let data = try? Data(contentsOf: deviceURL),
           let stored = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           stored.count == 52, stored.allSatisfy(\.isHexDigit) {
            deviceID = stored
        } else {
            let hex = Array("0123456789ABCDEF")
            let generated = String((0..<52).map { _ in hex.randomElement()! })
            try? Data(generated.utf8).write(to: deviceURL, options: .atomic)
            deviceID = generated
        }

        let cookeURL = support.appendingPathComponent("cookies.json")
        cookieFileURL = cookeURL
        if let data = try? Data(contentsOf: cookeURL),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            cookies = stored
        }
    }

    // MARK: - 设备标识

    /// 被 -460 风控后换一个设备标识再试。
    /// 风控按 deviceId 累积，换标识比反复重试同一个 ID 有效得多。
    func rotateDeviceID() {
        let hex = Array("0123456789ABCDEF")
        let generated = String((0..<52).map { _ in hex.randomElement()! })
        lock.lock()
        deviceID = generated
        lock.unlock()
        if let url = deviceIDFileURL {
            try? Data(generated.utf8).write(to: url, options: .atomic)
        }
        Self.log.notice("deviceId 已轮换（风控恢复）")
    }

    // MARK: - Cookies

    var isLoggedIn: Bool { cookie("MUSIC_U") != nil }

    func cookie(_ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return cookies[name]
    }

    private func mergeCookies(_ new: [String: String]) {
        lock.lock()
        for (k, v) in new where !v.isEmpty { cookies[k] = v }
        let snapshot = cookies
        lock.unlock()

        if let cookieFileURL, let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: cookieFileURL, options: .atomic)
        }
    }

    func clearAuth() {
        lock.lock()
        cookies.removeValue(forKey: "MUSIC_U")
        cookies.removeValue(forKey: "__csrf")
        let snapshot = cookies
        lock.unlock()

        if let cookieFileURL, let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: cookieFileURL, options: .atomic)
        }
    }

    /// 扫码登录返回的是一串 `;;` 分隔的原始 cookie，不是标准 Set-Cookie。
    func ingestRawCookieString(_ raw: String) {
        var parsed: [String: String] = [:]
        for chunk in raw.components(separatedBy: ";;") {
            guard let first = chunk.components(separatedBy: ";").first,
                  let eq = first.firstIndex(of: "=") else { continue }
            let name = first[..<eq].trimmingCharacters(in: .whitespaces)
            let value = first[first.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !value.isEmpty, value != "\"\"" { parsed[name] = value }
        }
        mergeCookies(parsed)
    }

    private func cookieHeaderValue(extra: [String: Any] = [:]) -> String {
        lock.lock()
        var all = cookies
        lock.unlock()
        for (k, v) in extra {
            if all[k] == nil, let s = v as? String, !s.isEmpty { all[k] = s }
        }
        return all.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private func absorb(response: HTTPURLResponse, url: URL) {
        guard let fields = response.allHeaderFields as? [String: String] else { return }
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !parsed.isEmpty else { return }
        var new: [String: String] = [:]
        for c in parsed where !c.value.isEmpty && c.value != "\"\"" { new[c.name] = c.value }
        mergeCookies(new)
    }

    // MARK: - Requests

    /// POST 到 `https://<interfaceHost>/eapi<path>`，body 为加密后的 `params`。
    func eapi(path: String, payload: [String: Any] = [:]) async throws -> Data {
        let apiPath = "/api" + path
        guard let url = URL(string: "https://\(config.upstream.interfaceHost)/eapi\(path)") else {
            throw MusicAPIError.transport("接口地址非法")
        }

        var body = payload
        body["header"] = makeHeader()
        body["e_r"] = false

        guard JSONSerialization.isValidJSONObject(body),
              let json = try? JSONSerialization.data(withJSONObject: body, options: []),
              let jsonText = String(data: json, encoding: .utf8) else {
            throw MusicAPIError.transport("参数序列化失败")
        }

        let form = RequestCrypto.eapi(apiPath: apiPath, payloadJSON: jsonText)
        guard let params = form["params"] else {
            throw MusicAPIError.transport("加密失败")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(config.upstream.referer, forHTTPHeaderField: "Referer")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let header = makeHeader()
        request.setValue(cookieHeaderValue(extra: header), forHTTPHeaderField: "Cookie")
        request.httpBody = Data("params=\(params)".utf8)

        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MusicAPIError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MusicAPIError.transport("响应非法")
        }
        if let url = request.url { absorb(response: http, url: url) }

        guard (200..<300).contains(http.statusCode) else {
            Self.log.error("HTTP \(http.statusCode) \(request.url?.path ?? "?", privacy: .public)")
            throw MusicAPIError.http(http.statusCode)
        }
        return data
    }

    /// 解出业务错误码，再交给 Decodable。
    ///
    /// `allowing` 用来放行「非 200 但属于正常流程」的码 —— 扫码登录就是典型：
    /// 800 过期 / 801 等待扫码 / 802 已扫码待确认 / 803 成功，这几个都得当成
    /// 正常结果交给上层判断，否则第一次轮询就会抛错。
    func decoded<T: Decodable>(_ type: T.Type,
                               from data: Data,
                               allowing allowedCodes: Set<Int> = []) throws -> T {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = obj["code"] as? Int, code != 200, !allowedCodes.contains(code) {
            if code == 301 { throw MusicAPIError.needLogin }
            let message = (obj["message"] as? String) ?? (obj["msg"] as? String)
            throw MusicAPIError.business(code: code, message: message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Self.log.error("解码 \(String(describing: T.self)) 失败: \(error.localizedDescription, privacy: .public)")
            throw MusicAPIError.decoding(String(describing: error))
        }
    }

    /// eapi 的 `header`：把自己描述成桌面客户端的一台具体设备。
    private func makeHeader() -> [String: Any] {
        let now = Date().timeIntervalSince1970
        var header: [String: Any] = [
            "osver": config.client.osVersion,
            "deviceId": deviceID,
            "os": "pc",
            "appver": config.client.appVersion,
            "versioncode": config.client.versionCode,
            "mobilename": "",
            "buildver": String(Int(now)),
            "resolution": config.client.resolution,
            "channel": config.client.channel,
            "requestId": String(format: "%lld_%04d", Int64(now * 1000), Int(now * 1_000_000) % 1000),
            "__csrf": cookie("__csrf") ?? "",
        ]
        if let token = cookie("MUSIC_U") { header["MUSIC_U"] = token }
        if let nmtid = cookie("NMTID") { header["NMTID"] = nmtid }
        return header
    }
}
