import Foundation

/// 全部可变参数都从这里取：接口域名、伪装标识、音质档位、端点路径。
/// 网易改协议时只需要改 `config.json`，不用动代码。
struct AppConfig: Decodable {

    struct Upstream: Decodable {
        let webHost: String
        let interfaceHost: String
        let referer: String
    }

    struct Client: Decodable {
        let clientName: String
        let userAgent: String
        let appVersion: String
        let osVersion: String
        let versionCode: String
        let channel: String
        let resolution: String
    }

    struct QualityLevel: Decodable, Identifiable, Hashable {
        let id: String
        let name: String
    }

    struct Quality: Decodable {
        let defaultLevel: String
        let encodeType: String
        let levels: [QualityLevel]
    }

    struct Endpoints: Decodable {
        let search: String
        let toplists: String
        let playlistDetail: String
        let songURL: String
        let lyric: String
        let qrUnikey: String
        let qrCheck: String
        let account: String
        let dailyRecommend: String
        /// `/user/playlist`：账号里的全部歌单（含「我喜欢的音乐」）。
        /// 写成可选：老配置文件里没有这一项时整份 config 还能正常解码，
        /// 不会连带把音质档位之类的设置一起退回内置默认值。
        let userPlaylist: String?
    }

    struct QR: Decodable {
        let type: Int
        let pollInterval: Double
    }

    /// 取流方案。曲库、歌词、封面仍然走官方接口，
    /// 这里只决定「播放地址从哪儿拿」。
    struct Playback: Decodable {

        struct Script: Decodable, Identifiable {
            let name: String
            let url: String
            var id: String { name }
        }

        struct Luoxue: Decodable {
            /// 用落雪脚本里的哪个源取流，网易云曲目对应 `wy`
            let sourceKey: String
            /// 我们的音质档位 → 落雪脚本的音质标识
            let qualityMap: [String: String]
            /// 按顺序尝试的在线脚本，第一个能初始化的就被启用
            let scripts: [Script]
        }

        /// `netease` = 官方取流接口；`luoxue` = 自定义源脚本
        let engine: String
        /// 落雪取不到时是否回退官方接口
        let fallbackToNetease: Bool
        let luoxue: Luoxue?

        var usesLuoxue: Bool { engine.lowercased() == "luoxue" }
    }

    let upstream: Upstream
    let client: Client
    let quality: Quality
    let endpoints: Endpoints
    let qr: QR
    /// 老配置文件里没有这一段时整个 config 仍能解码，回退到官方取流。
    let playback: Playback?

    static let shared: AppConfig = load()

    private static func load() -> AppConfig {
        guard let url = Bundle.main.url(forResource: "config", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AppConfig.self, from: data)
        else {
            NSLog("[3YE] config.json 未能从 Bundle 加载，回退到内置默认值")
            return fallback
        }
        return decoded
    }

    static let fallback = AppConfig(
        upstream: Upstream(webHost: "music.163.com",
                           interfaceHost: "interface.music.163.com",
                           referer: "https://music.163.com"),
        client: Client(clientName: "NetEaseMusic",
                       userAgent: "NetEaseMusicDesktop 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)",
                       appVersion: "3.1.17.204416",
                       osVersion: "Microsoft-Windows-10-Professional-build-19045-64bit",
                       versionCode: "140",
                       channel: "netease",
                       resolution: "1920x1080"),
        quality: Quality(defaultLevel: "exhigh",
                         encodeType: "flac",
                         levels: [QualityLevel(id: "exhigh", name: "极高")]),
        endpoints: Endpoints(search: "/cloudsearch/pc",
                             toplists: "/toplist/detail",
                             playlistDetail: "/v6/playlist/detail",
                             songURL: "/song/enhance/player/url/v1",
                             lyric: "/song/lyric",
                             qrUnikey: "/login/qrcode/unikey",
                             qrCheck: "/login/qrcode/client/login",
                             account: "/nuser/account/get",
                             dailyRecommend: "/v3/discovery/recommend/songs",
                             userPlaylist: "/user/playlist"),
        qr: QR(type: 3, pollInterval: 2.0),
        playback: nil
    )
}
