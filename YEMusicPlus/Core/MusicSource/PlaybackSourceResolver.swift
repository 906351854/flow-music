import Foundation

/// 取流总入口。
///
/// 曲库、歌词、封面、登录都还是官方接口 —— 这一层只决定
/// 「播放地址从哪儿拿」。换成落雪只是为了绕开官方取流接口的风控，
/// 不牵动其它任何数据。
final class PlaybackSourceResolver {

    static let shared = PlaybackSourceResolver()

    private var playback: AppConfig.Playback? { AppConfig.shared.playback }

    /// 设置页显示的当前取流方案。
    var engineName: String {
        guard let playback else { return "官方接口" }
        return playback.usesLuoxue ? "落雪音源" : "官方接口"
    }

    var isUsingLuoxue: Bool { playback?.usesLuoxue ?? false }

    /// 我们的音质档位 → 落雪脚本的音质标识。
    /// 降级链里 `exhigh` / `higher` 都落在这一个值上，所以调用方要按它去重。
    func mappedQuality(for level: String) -> String {
        playback?.luoxue?.qualityMap[level] ?? "320k"
    }

    func streamURL(for track: Track, level: String) async throws -> SongURLData? {
        guard isUsingLuoxue else {
            return try await MusicAPI.songURL(id: track.id, level: level)
        }

        do {
            let url = try await LuoxueMusicSource.shared.musicURL(for: track, level: level)
            return SongURLData(id: track.id,
                               url: url,
                               br: nil,
                               size: nil,
                               md5: nil,
                               code: 200,
                               type: nil,
                               level: level,
                               freeTrialInfo: nil)
        } catch {
            let sourceError = error
            guard playback?.fallbackToNetease ?? true else { throw sourceError }
            NSLog("[playback] 落雪取流失败（\(sourceError.localizedDescription)），回退官方接口")
            do {
                return try await MusicAPI.songURL(id: track.id, level: level)
            } catch {
                // 官方也失败时，报音源的错更有用：官方那条大概率还是 -460 风控，
                // 而音源的错（脚本没初始化 / 取流超时）才是用户能动手解决的。
                NSLog("[playback] 官方接口同样失败：\(error.localizedDescription)")
                throw sourceError
            }
        }
    }
}
