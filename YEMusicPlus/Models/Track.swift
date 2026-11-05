import Foundation

struct Track: Identifiable, Hashable, Decodable {

    struct Artist: Hashable, Decodable {
        let id: Int
        let name: String

        init(id: Int, name: String) {
            self.id = id
            self.name = name
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.flexInt(.id)
            name = (try? c.decode(String.self, forKey: .name)) ?? ""
        }

        private enum CodingKeys: String, CodingKey { case id, name }
    }

    struct Album: Hashable, Decodable {
        let id: Int
        let name: String
        let picUrl: String?

        init(id: Int, name: String, picUrl: String?) {
            self.id = id
            self.name = name
            self.picUrl = picUrl
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.flexInt(.id)
            name = (try? c.decode(String.self, forKey: .name)) ?? ""
            picUrl = try? c.decodeIfPresent(String.self, forKey: .picUrl)
        }

        private enum CodingKeys: String, CodingKey { case id, name, picUrl }
    }

    let id: Int
    let name: String
    let artists: [Artist]
    let album: Album
    let durationMS: Int
    let fee: Int
    /// 每日推荐会带一句推荐理由（`reason`），其它端点没有。
    let recommendReason: String?

    init(id: Int, name: String, artists: [Artist], album: Album,
         durationMS: Int, fee: Int, recommendReason: String? = nil) {
        self.id = id
        self.name = name
        self.artists = artists
        self.album = album
        self.durationMS = durationMS
        self.fee = fee
        self.recommendReason = recommendReason
    }

    /// 网易的字段名短且类型不稳定（同一个字段有时 Int、有时 String、有时缺失），
    /// 而且不同端点命名还不一致：`/cloudsearch/pc`、`/v6/playlist/detail` 用
    /// `ar` / `al` / `dt`，而 `/song/detail` 用 `artists` / `album` / `duration`。
    /// 所以逐字段容错解码，两种命名都认，任何一个字段坏掉都不该让整页白屏。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexInt(.id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "未知曲目"

        if let list = try? c.decode([Artist].self, forKey: .ar) {
            artists = list
        } else if let list = try? c.decode([Artist].self, forKey: .artists) {
            artists = list
        } else {
            artists = []
        }

        if let decodedAlbum = try? c.decode(Album.self, forKey: .al) {
            album = decodedAlbum
        } else if let decodedAlbum = try? c.decode(Album.self, forKey: .album) {
            album = decodedAlbum
        } else {
            album = Album(id: 0, name: "", picUrl: nil)
        }

        durationMS = c.contains(.dt) ? c.flexInt(.dt) : c.flexInt(.duration)
        fee = c.flexInt(.fee)
        recommendReason = try? c.decodeIfPresent(String.self, forKey: .reason)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, fee, reason
        case ar, al, dt
        case artists, album, duration
    }

    var artistLine: String {
        let names = artists.map(\.name).filter { !$0.isEmpty }
        return names.isEmpty ? "未知歌手" : names.joined(separator: " / ")
    }

    var subtitleLine: String {
        album.name.isEmpty ? artistLine : "\(artistLine) — \(album.name)"
    }

    /// 封面地址：统一升到 https，并让服务端裁到合适尺寸。
    var coverURL: URL? {
        guard let raw = album.picUrl, !raw.isEmpty,
              var components = URLComponents(string: raw) else { return nil }
        components.scheme = "https"
        components.queryItems = [URLQueryItem(name: "param", value: "500y500")]
        return components.url
    }

    var durationText: String {
        guard durationMS > 0 else { return "--:--" }
        let total = durationMS / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// fee: 0 免费 / 1 VIP / 4 付费专辑 / 8 低音质免费
    var needsVip: Bool { fee == 1 || fee == 4 }
}

private extension KeyedDecodingContainer {
    /// 容忍 Int / Double / String 三种形态。
    func flexInt(_ key: Key) -> Int {
        if let v = try? decode(Int.self, forKey: key) { return v }
        if let v = try? decode(Double.self, forKey: key) { return Int(v) }
        if let v = try? decode(String.self, forKey: key) { return Int(v) ?? 0 }
        return 0
    }
}
