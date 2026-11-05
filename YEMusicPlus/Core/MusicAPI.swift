import Foundation

/// 只读接口封装。所有路径来自 `config.json` 的 `endpoints`，
/// 改协议时不用碰这里。
enum MusicAPI {

    private static var client: MusicClient { .shared }
    private static var config: AppConfig { .shared }

    // MARK: - 曲库

    /// `/cloudsearch/pc`，`type: 1` 为单曲。
    static func search(_ keyword: String, limit: Int = 30, offset: Int = 0) async throws -> [Track] {
        let data = try await client.eapi(path: config.endpoints.search, payload: [
            "s": keyword,
            "type": 1,
            "limit": limit,
            "offset": offset,
            "total": true,
        ])
        let response = try client.decoded(SearchResponse.self, from: data)
        return response.result?.songs ?? []
    }

    static func toplists() async throws -> [PlaylistSummary] {
        let data = try await client.eapi(path: config.endpoints.toplists)
        let response = try client.decoded(ToplistsResponse.self, from: data)
        return (response.list ?? []).map(PlaylistSummary.init(fromToplistDTO:))
    }

    static func playlistDetail(id: Int) async throws -> (summary: PlaylistSummary?, tracks: [Track]) {
        let data = try await client.eapi(path: config.endpoints.playlistDetail, payload: [
            "id": id,
            "n": 1000,
            "s": 8,
        ])
        let response = try client.decoded(PlaylistDetailResponse.self, from: data)
        guard let playlist = response.playlist else { return (nil, []) }
        return (PlaylistSummary(fromPlaylistDTO: playlist), playlist.tracks ?? [])
    }

    /// 取播放地址。`level` 与 `encodeType` 来自 config。
    static func songURL(id: Int, level: String) async throws -> SongURLData? {
        let data = try await client.eapi(path: config.endpoints.songURL, payload: [
            "ids": "[\(id)]",
            "level": level,
            "encodeType": config.quality.encodeType,
        ])
        let response = try client.decoded(SongURLResponse.self, from: data)
        return response.data?.first
    }

    static func lyric(id: Int) async throws -> String {
        let data = try await client.eapi(path: config.endpoints.lyric, payload: [
            "id": id, "lv": -1, "kv": -1, "tv": -1,
        ])
        let response = try client.decoded(LyricResponse.self, from: data)
        return response.lrc?.lyric ?? ""
    }

    /// 把接口返回的 http CDN 地址升到 https。
    /// ATS 会直接拦掉 http 音频且不给报错，表现为「点了没反应」。
    /// 签名在 path 里、不绑 scheme，所以换 scheme 后仍可访问（已实测 200）。
    static func playableURL(from raw: String?) -> URL? {
        guard let raw, !raw.isEmpty,
              var components = URLComponents(string: raw) else { return nil }
        components.scheme = "https"
        return components.url
    }

    // MARK: - 登录

    static func qrKey() async throws -> String {
        let data = try await client.eapi(path: config.endpoints.qrUnikey, payload: [
            "type": config.qr.type,
        ])
        let response = try client.decoded(QRKeyResponse.self, from: data)
        return response.unikey
    }

    /// 扫码页地址：手机网易云扫这个 URL 即可。码里带 codekey。
    static func qrContentURL(unikey: String) -> URL? {
        URL(string: "https://\(config.upstream.webHost)/login?codekey=\(unikey)")
    }

    static func qrCheck(unikey: String) async throws -> QRCheckResponse {
        let data = try await client.eapi(path: config.endpoints.qrCheck, payload: [
            "key": unikey,
            "type": config.qr.type,
        ])
        // 800/801/802/803 都是正常流程状态，不能当业务错误抛出去。
        return try client.decoded(QRCheckResponse.self, from: data,
                                  allowing: [800, 801, 802, 803])
    }

    // MARK: - 推荐

    /// 每日推荐。实测**未登录**也能返回 30 首（`data.dailySongs`），
    /// 所以首页在没登录时也有内容，不会白屏。
    ///
    /// 结果按天缓存：一天之内反复启动 App 只打一次接口。
    /// 这个接口没什么时效性（每天只换一批），缓存收益远大于「每次都最新」。
    static func dailyRecommendations(limit: Int = 30) async throws -> [Track] {
        // 登录前后推荐结果不一样，用两个缓存槽，登录完自然拿到自己那份。
        let slot = client.isLoggedIn ? "user" : "guest"
        let key = "daily-\(slot)-\(limit)"
        let cached = ResponseCache.data(for: key, maxAge: 6 * 60 * 60)

        let data: Data
        if let cached {
            data = cached
        } else {
            data = try await client.eapi(path: config.endpoints.dailyRecommend, payload: [
                "limit": limit,
                "offset": 0,
                "total": true,
                "n": 1000,
            ])
            ResponseCache.store(data, for: key)
        }

        let response = try client.decoded(DailySongsResponse.self, from: data)
        return response.data?.dailySongs ?? []
    }

    static func account() async throws -> AccountResponse.Profile? {
        let data = try await client.eapi(path: config.endpoints.account)
        let response = try client.decoded(AccountResponse.self, from: data)
        return response.profile
    }

    /// 账号里的全部歌单，**包含**「我喜欢的音乐」（`specialType == 5`）。
    ///
    /// 缓存 3 分钟：资料库是标签页，来回切换会反复触发 `.task`，
    /// 不缓存的话每次切回来都打一遍接口，风控很容易把 deviceId 拉黑。
    static func userPlaylists(uid: Int, forceRefresh: Bool = false) async throws -> [PlaylistSummary] {
        let path = config.endpoints.userPlaylist ?? "/user/playlist"
        let key = "user-playlist-\(uid)"
        let data: Data
        if !forceRefresh, let cached = ResponseCache.data(for: key, maxAge: 3 * 60) {
            data = cached
        } else {
            data = try await client.eapi(path: path, payload: [
                "uid": uid,
                "limit": 1000,
                "offset": 0,
            ])
            ResponseCache.store(data, for: key)
        }

        let response = try client.decoded(UserPlaylistsResponse.self, from: data)
        return (response.playlist ?? []).map(PlaylistSummary.init(fromPlaylistDTO:))
    }
}
