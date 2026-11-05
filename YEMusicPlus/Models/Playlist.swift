import Foundation

/// 榜单与歌单共用的概要模型（`/toplist/detail` 的 list 项、
/// `/v6/playlist/detail` 的 playlist 都能映射到它）。
struct PlaylistSummary: Identifiable, Hashable {
    let id: Int
    let name: String
    let cover: String?
    let trackCount: Int
    let updateFrequency: String?
    /// 系统歌单标记。`5` = 「我喜欢的音乐」——它不是自建歌单，
    /// 资料库里要单独拎出来放第一行。
    let specialType: Int?
    /// 是否为「收藏的别人的歌单」。`false` / `nil` 都按自建处理。
    let subscribed: Bool?

    var isLikedMusic: Bool { specialType == 5 }

    var coverURL: URL? {
        guard let raw = cover, !raw.isEmpty,
              var components = URLComponents(string: raw) else { return nil }
        components.scheme = "https"
        components.queryItems = [URLQueryItem(name: "param", value: "400y400")]
        return components.url
    }

    init(id: Int,
         name: String,
         cover: String?,
         trackCount: Int,
         updateFrequency: String?,
         specialType: Int? = nil,
         subscribed: Bool? = nil) {
        self.id = id
        self.name = name
        self.cover = cover
        self.trackCount = trackCount
        self.updateFrequency = updateFrequency
        self.specialType = specialType
        self.subscribed = subscribed
    }

    init(fromToplistDTO dto: ToplistDTO) {
        self.init(id: dto.id,
                  name: dto.name,
                  cover: dto.coverImgUrl,
                  trackCount: dto.trackCount ?? 0,
                  updateFrequency: dto.updateFrequency)
    }

    init(fromPlaylistDTO dto: PlaylistDTO) {
        self.init(id: dto.id,
                  name: dto.name,
                  cover: dto.coverImgUrl,
                  trackCount: dto.trackCount ?? dto.tracks?.count ?? 0,
                  updateFrequency: nil,
                  specialType: dto.specialType,
                  subscribed: dto.subscribed)
    }
}

// MARK: - 原始 DTO

struct ToplistDTO: Decodable {
    let id: Int
    let name: String
    let coverImgUrl: String?
    let trackCount: Int?
    let updateFrequency: String?
}

struct ToplistsResponse: Decodable {
    let list: [ToplistDTO]?
}

struct PlaylistDTO: Decodable {
    let id: Int
    let name: String
    let coverImgUrl: String?
    let trackCount: Int?
    let description: String?
    let tracks: [Track]?
    /// 5 = 「我喜欢的音乐」。
    let specialType: Int?
    /// true = 收藏的别人的歌单；false/缺省 = 自建。
    let subscribed: Bool?
}

struct PlaylistDetailResponse: Decodable {
    let playlist: PlaylistDTO?
}

/// `/user/playlist`：某个账号的全部歌单（含「我喜欢的音乐」）。
struct UserPlaylistsResponse: Decodable {
    let playlist: [PlaylistDTO]?
    let code: Int?
}

struct SearchResponse: Decodable {
    let result: SearchResult?

    struct SearchResult: Decodable {
        let songs: [Track]?
        let songCount: Int?
    }
}
