import Foundation
import SwiftUI

/// `/song/enhance/player/url/v1` 的返回项。
/// 关键点：`url` 可能是 null（无版权/无会员），`freeTrialInfo` 非空表示只给了试听片段。
struct SongURLData: Decodable {
    struct FreeTrial: Decodable {
        let start: Double?
        let end: Double?
    }

    let id: Int
    let url: String?
    let br: Int?
    let size: Int?
    let md5: String?
    let code: Int?
    let type: String?
    let level: String?
    let freeTrialInfo: FreeTrial?

    var isTrialOnly: Bool { freeTrialInfo != nil }
}

struct SongURLResponse: Decodable {
    let data: [SongURLData]?
}

struct LyricResponse: Decodable {
    struct Body: Decodable {
        let lyric: String?
    }
    let lrc: Body?
    let tlyric: Body?
}

/// `/v3/discovery/recommend/songs` 的返回结构：歌在 `data.dailySongs` 里，
/// 不是常见的 `result` / `songs`，所以要单独包一层。
struct DailySongsResponse: Decodable {
    struct Payload: Decodable {
        let dailySongs: [Track]?
    }
    let data: Payload?
    let code: Int?
}

struct QRKeyResponse: Decodable {
    let unikey: String
    let code: Int?
}

struct QRCheckResponse: Decodable {
    let code: Int
    let message: String?
    let nickname: String?
    let avatarUrl: String?
    /// 803 成功时服务端会把登录态放在这个字段里，是一串 `;;` 分隔的原始 cookie。
    /// 不取它就会「提示登录成功但没有登录态」。
    let cookie: String?

    enum State {
        case expired      // 800
        case waiting      // 801
        case scanned      // 802
        case success      // 803
        case other(Int)

        init(code: Int) {
            switch code {
            case 800: self = .expired
            case 801: self = .waiting
            case 802: self = .scanned
            case 803: self = .success
            default: self = .other(code)
            }
        }
    }

    var state: State { State(code: code) }
}

struct AccountResponse: Decodable {
    struct Profile: Decodable {
        let userId: Int?
        let nickname: String?
        let avatarUrl: String?
        let vipType: Int?
    }
    let profile: Profile?
    let code: Int?
}

/// `.soft` 滚动边缘效果要等系统 26 才有的 API，这里统一收敛成一个修饰器，
/// 方便以后要给老系统兜底时只改一处。
struct SoftScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        content.scrollEdgeEffectStyle(.soft, for: .top)
    }
}

extension View {
    func softTopEdge() -> some View { modifier(SoftScrollEdge()) }
}
