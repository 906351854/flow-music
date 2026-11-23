import Foundation
import JavaScriptCore
import CryptoKit
import Security

enum LuoxueError: LocalizedError {
    case engineUnavailable
    case scriptFailed(String)
    case initTimeout
    case noSource(String)
    case emptyURL(String)

    var errorDescription: String? {
        switch self {
        case .engineUnavailable:
            return "JS 引擎不可用"
        case .scriptFailed(let msg):
            return "音源脚本出错：\(msg)"
        case .initTimeout:
            return "音源脚本初始化超时"
        case .noSource(let key):
            return "音源不支持 \(key) 源"
        case .emptyURL(let msg):
            return "音源没有返回播放地址" + (msg.isEmpty ? "" : "：\(msg)")
        }
    }
}

/// 一个音源脚本的落地形态。
struct LuoxueScriptInfo {
    /// 源 key → 支持音质列表，例如 `["wy": ["128k", "320k", "flac"]]`
    let sources: [String: [String]]
    let scriptName: String
}

/// 跑一个落雪自定义源脚本。
///
/// 线程模型：`JSContext` 不是线程安全的，所以**所有** JS 调用都串行在 `queue` 上。
/// HTTP 在 URLSession 的线程上跑，完成后跳回 `queue` 再回调 JS。
final class LuoxueRuntime: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.zed.flowmusic.luoxue", qos: .userInitiated)
    private var context: JSContext?

    /// 脚本初始化完成后由 `__lxSend("inited", …)` 填上。
    private var initedSources: [String: [String]] = [:]
    private var initWaiter: CheckedContinuation<LuoxueScriptInfo, Error>?

    /// 取流请求：id → continuation
    private var pendingMusicURL: [String: CheckedContinuation<String, Error>] = [:]

    /// 每次 load 递增。旧脚本迟到的 HTTP 回调按这个号丢弃，
    /// 否则换源之后旧回调会把结果写进新 context。
    private var generation = 0

    private var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 45
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    // MARK: - 加载

    func load(script: String, scriptName: String) async throws -> LuoxueScriptInfo {
        // 1) 在 JS 队列上建 context、注入原生通道、执行脚本
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.evaluateLocked(script: script, scriptName: scriptName)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        // 2) 等脚本上报 inited —— 有些源要先请求一次初始化接口，所以是异步的
        return try await waitForInit()
    }

    private func evaluateLocked(script: String, scriptName: String) throws {
        guard let ctx = JSContext() else { throw LuoxueError.engineUnavailable }

        generation += 1
        let gen = generation
        initedSources = [:]
        initWaiter = nil
        pendingMusicURL.forEach { $0.value.resume(throwing: LuoxueError.scriptFailed("脚本已重载")) }
        pendingMusicURL = [:]

        ctx.exceptionHandler = { _, exception in
            let message = exception?.toString() ?? "unknown"
            NSLog("[luoxue] JS 异常: \(message)")
        }

        context = ctx
        installNatives(ctx: ctx, generation: gen)

        ctx.evaluateScript(LuoxueGlue.source, withSourceURL: URL(string: "lx://glue.js"))
        if let exc = ctx.exception {
            ctx.exception = nil
            throw LuoxueError.scriptFailed(exc.toString() ?? "glue 执行失败")
        }

        // 脚本头部注释里的 `@name` 才是它的真名（LX 就是这么显示的），
        // 先写进 currentScriptInfo，脚本自己不会设置这个字段。
        let displayName = LuoxueScriptStore.guessName(from: script) ?? scriptName
        ctx.evaluateScript("lx.currentScriptInfo.name = \(jsString(displayName));")

        ctx.evaluateScript(script, withSourceURL: URL(string: "lx://\(scriptName).js"))
        if let exc = ctx.exception {
            ctx.exception = nil
            throw LuoxueError.scriptFailed(exc.toString() ?? "脚本执行失败")
        }
    }

    private func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let text = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(text.dropFirst().dropLast())
    }

    private func waitForInit(timeout: TimeInterval = 20) async throws -> LuoxueScriptInfo {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<LuoxueScriptInfo, Error>) in
            queue.async {
                if !self.initedSources.isEmpty {
                    cont.resume(returning: self.makeInfo())
                    return
                }
                self.initWaiter = cont
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    guard let waiter = self.initWaiter else { return }
                    self.initWaiter = nil
                    waiter.resume(throwing: LuoxueError.initTimeout)
                }
            }
        }
    }

    private func makeInfo() -> LuoxueScriptInfo {
        let name = context?.objectForKeyedSubscript("lx")?
            .objectForKeyedSubscript("currentScriptInfo")?
            .objectForKeyedSubscript("name")?.toString() ?? ""
        return LuoxueScriptInfo(sources: initedSources, scriptName: name)
    }

    // MARK: - 取流

    func musicURL(source: String, quality: String, musicInfo: [String: Any], timeout: TimeInterval = 40) async throws -> String {
        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: musicInfo),
           let text = String(data: data, encoding: .utf8) {
            json = text
        } else {
            json = "{}"
        }

        let requestID = UUID().uuidString

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            queue.async {
                guard let ctx = self.context,
                      let fn = ctx.objectForKeyedSubscript("__lxGetMusicUrl"),
                      !fn.isUndefined else {
                    cont.resume(throwing: LuoxueError.scriptFailed("脚本未就绪"))
                    return
                }

                self.pendingMusicURL[requestID] = cont

                fn.call(withArguments: [requestID, source, quality, json])

                if let exc = ctx.exception {
                    ctx.exception = nil
                    if let waiter = self.pendingMusicURL.removeValue(forKey: requestID) {
                        waiter.resume(throwing: LuoxueError.scriptFailed(exc.toString() ?? "取流异常"))
                    }
                    return
                }

                self.queue.asyncAfter(deadline: .now() + timeout) {
                    guard let waiter = self.pendingMusicURL.removeValue(forKey: requestID) else { return }
                    waiter.resume(throwing: LuoxueError.scriptFailed("取流超时"))
                }
            }
        }
    }

    private func finishMusicURL(id: String, error: String, url: String) {
        guard let waiter = pendingMusicURL.removeValue(forKey: id) else { return }
        if !error.isEmpty {
            waiter.resume(throwing: LuoxueError.scriptFailed(error))
        } else if url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            waiter.resume(throwing: LuoxueError.emptyURL(""))
        } else {
            waiter.resume(returning: url)
        }
    }

    // MARK: - 原生通道

    private func installNatives(ctx: JSContext, generation gen: Int) {
        let send: @convention(block) (String, String) -> Void = { [weak self] event, json in
            guard let self, gen == self.generation else { return }
            self.handleSend(event: event, json: json)
        }
        set(ctx, "__lxSend", send)

        let log: @convention(block) (String, String) -> Void = { level, message in
            NSLog("[luoxue][%@] %@", level, message)
        }
        set(ctx, "__lxLog", log)

        let http: @convention(block) (String, String, String) -> Void = { [weak self] id, url, spec in
            guard let self, gen == self.generation else { return }
            self.startHTTP(id: id, url: url, spec: spec, generation: gen)
        }
        set(ctx, "__lxHTTP", http)

        let done: @convention(block) (String, String, String) -> Void = { [weak self] id, error, url in
            guard let self, gen == self.generation else { return }
            self.finishMusicURL(id: id, error: error, url: url)
        }
        set(ctx, "__lxMusicUrlDone", done)

        let timer: @convention(block) (Int, Double, Bool) -> Void = { [weak self] id, ms, repeatable in
            guard let self, gen == self.generation else { return }
            let delay = max(0, ms) / 1000.0
            self.queue.asyncAfter(deadline: .now() + delay) {
                guard gen == self.generation, let ctx = self.context else { return }
                ctx.objectForKeyedSubscript("__lxTimerFire")?.call(withArguments: [id, repeatable])
            }
        }
        set(ctx, "__lxTimer", timer)

        let md5: @convention(block) (String) -> String = { text in
            let digest = Insecure.MD5.hash(data: Data(text.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        set(ctx, "__lxMD5", md5)

        let random: @convention(block) (Int) -> String = { size in
            let count = max(1, min(size, 4096))
            var bytes = [UInt8](repeating: 0, count: count)
            _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        set(ctx, "__lxRandomHex", random)
    }

    /// JSC 只认 Objective-C 对象，Swift 闭包要先按 block 布好再 bitCast 进去。
    /// 名字必须和 `LuoxueGlue` 里调用的完全一致（大小写敏感）。
    private func set<B>(_ ctx: JSContext, _ key: String, _ block: B) {
        ctx.setObject(unsafeBitCast(block, to: AnyObject.self), forKeyedSubscript: key as NSString)
    }

    private func handleSend(event: String, json: String) {
        guard event == "inited" else {
            if event == "updateAlert" { NSLog("[luoxue] 脚本提示更新: \(json)") }
            return
        }

        var sources: [String: [String]] = [:]
        if let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = obj["sources"] as? [String: Any] {
            for (key, value) in raw {
                guard let dict = value as? [String: Any] else { continue }
                let qualities = (dict["qualitys"] as? [String]) ?? []
                sources[key] = qualities
            }
        }
        initedSources = sources

        if let waiter = initWaiter {
            initWaiter = nil
            if sources.isEmpty {
                waiter.resume(throwing: LuoxueError.scriptFailed("脚本初始化后没有声明任何源"))
            } else {
                waiter.resume(returning: makeInfo())
            }
        }
    }

    // MARK: - HTTP

    private func startHTTP(id: String, url: String, spec: String, generation gen: Int) {
        guard let specData = spec.data(using: .utf8),
              let options = try? JSONSerialization.jsonObject(with: specData) as? [String: Any] else {
            callHTTPDone(ctx: context, id: id, error: "请求参数错误", status: 0, headers: [:], body: "", binary: false)
            return
        }

        guard let target = URL(string: url) else {
            callHTTPDone(ctx: context, id: id, error: "URL 非法", status: 0, headers: [:], body: "", binary: false)
            return
        }

        var request = URLRequest(url: target)
        request.httpMethod = (options["method"] as? String) ?? "GET"

        let timeout = (options["timeout"] as? Double) ?? 0
        if timeout > 0 {
            request.timeoutInterval = max(1, timeout / 1000)
        }

        if let headers = options["headers"] as? [String: String] {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        let bodyKind = (options["bodyKind"] as? String) ?? "none"
        let bodyValue = (options["bodyValue"] as? String) ?? ""

        switch bodyKind {
        case "text":
            request.httpBody = Data(bodyValue.utf8)
        case "json":
            request.httpBody = Data(bodyValue.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        case "base64":
            request.httpBody = Data(base64Encoded: bodyValue)
        case "form":
            request.httpBody = Data(bodyValue.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        case "formData":
            let boundary = "----FlowMusic\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.multipartBody(fieldsJSON: bodyValue, boundary: boundary)
        default:
            break
        }

        let binary = (options["binary"] as? Bool) ?? false

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self, gen == self.generation else { return }

            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            http?.allHeaderFields.forEach { key, value in
                if let k = key as? String { headers[k] = String(describing: value) }
            }
            let headersJSON = (try? JSONSerialization.data(withJSONObject: headers))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

            let payload = data ?? Data()
            let bodyText: String
            if binary {
                bodyText = payload.base64EncodedString()
            } else if let text = String(data: payload, encoding: .utf8) {
                bodyText = text
            } else {
                bodyText = String(data: payload, encoding: .isoLatin1) ?? ""
            }

            self.queue.async {
                guard gen == self.generation else { return }
                self.callHTTPDone(
                    ctx: self.context,
                    id: id,
                    error: error?.localizedDescription ?? "",
                    status: http?.statusCode ?? 0,
                    headersJSON: headersJSON,
                    body: bodyText,
                    binary: binary
                )
            }
        }.resume()
    }

    private func callHTTPDone(ctx: JSContext?, id: String, error: String, status: Int,
                              headers: [String: String]? = nil, headersJSON: String = "{}",
                              body: String, binary: Bool) {
        guard let ctx else { return }
        var payload = headersJSON
        if let headers,
           let data = try? JSONSerialization.data(withJSONObject: headers),
           let text = String(data: data, encoding: .utf8) {
            payload = text
        }
        ctx.objectForKeyedSubscript("__lxHTTPDone")?
            .call(withArguments: [id, error, status, payload, body, binary])
    }

    private static func multipartBody(fieldsJSON: String, boundary: String) -> Data {
        var body = Data()
        guard let data = fieldsJSON.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return body
        }
        for field in fields {
            guard let name = field["name"] as? String,
                  let value = field["value"] as? String else { continue }
            let filename = field["filename"] as? String
            let isFile = (field["kind"] as? String) == "base64"

            body.append(Data("--\(boundary)\r\n".utf8))
            if isFile {
                let file = filename ?? name
                body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(file)\"\r\n".utf8))
                body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
                body.append(Data(base64Encoded: value) ?? Data())
            } else {
                body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
                body.append(Data(value.utf8))
            }
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }
}
