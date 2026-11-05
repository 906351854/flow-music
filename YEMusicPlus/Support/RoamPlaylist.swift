import Foundation

/// 「漫游歌单」的现场生成器。
///
/// 没有专门的漫游接口，就拿手头现成的三块内容拼一摞：
/// 每日推荐（保底，未登录也有）+「我喜欢的音乐」里随机抽一段 +
/// 自建歌单里随机挑两个各抽几首。去重、打散、截断。
///
/// 每次调用顺序都不一样，所以「换一批」是真的换一批，
/// 也正因为不便宜，它只在你按下漫游 / 换一批时跑一次，不在滚动里反复算。
enum RoamPlaylist {

    /// 一摞牌最多这么多张。再多也没人翻得完，还平白多存一队封面地址。
    static let maxCount = 120

    static func build() async throws -> [Track] {
        var pool: [Track] = []
        var dailyError: Error?

        do {
            pool += try await MusicAPI.dailyRecommendations(limit: 30)
        } catch {
            dailyError = error
        }

        if MusicClient.shared.isLoggedIn {
            pool += await librarySample()
        }

        var seen = Set<Int>()
        let unique = pool.filter { seen.insert($0.id).inserted }
        if unique.isEmpty, let dailyError { throw dailyError }
        return Array(unique.shuffled().prefix(maxCount))
    }

    /// 从资料库抽样：喜欢的音乐最多 40 首，两个自建歌单各 14 首。
    /// 任何一步失败都只是少一块素材，不影响整摞牌。
    private static func librarySample() async -> [Track] {
        var uid = UserDefaults.standard.integer(forKey: "library.lastUID")
        if uid <= 0,
           let profile = try? await MusicAPI.account(),
           let id = profile.userId {
            uid = id
            UserDefaults.standard.set(id, forKey: "library.lastUID")
        }
        guard uid > 0 else { return [] }

        let playlists = (try? await MusicAPI.userPlaylists(uid: uid)) ?? []
        guard !playlists.isEmpty else { return [] }

        var result: [Track] = []
        let liked = playlists.first(where: \.isLikedMusic)
            ?? playlists.first { $0.name.contains("喜欢的音乐") }

        if let liked, let detail = try? await MusicAPI.playlistDetail(id: liked.id) {
            result += detail.tracks.shuffled().prefix(40)
        }

        let created = playlists.filter {
            $0.id != liked?.id && !$0.isLikedMusic && $0.subscribed != true
        }
        for item in created.shuffled().prefix(2) {
            if let detail = try? await MusicAPI.playlistDetail(id: item.id) {
                result += detail.tracks.shuffled().prefix(14)
            }
        }
        return result
    }
}
