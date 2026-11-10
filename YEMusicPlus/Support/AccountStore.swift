import Foundation

/// 账号信息的轻量共享源。
///
/// 右上角的头像需要昵称/头像，资料库页也需要同一份数据 ——
/// 两处各自打一次 `/nuser/account/get` 没有必要，这里合并成一次。
/// 只做「读」，登录/退出仍然由资料库页驱动，改完调 `refresh()` / `reset()`。
@MainActor
final class AccountStore: ObservableObject {

    static let shared = AccountStore()

    @Published private(set) var profile: AccountResponse.Profile?

    /// 是否已经查过一次。未登录时不重复请求，避免每次冷启动都白打接口。
    private var loaded = false

    var avatarURL: URL? {
        guard let raw = profile?.avatarUrl, !raw.isEmpty,
              var components = URLComponents(string: raw) else { return nil }
        components.scheme = "https"
        components.queryItems = [URLQueryItem(name: "param", value: "200y200")]
        return components.url
    }

    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        guard MusicClient.shared.isLoggedIn else { return }
        profile = try? await MusicAPI.account()
    }

    func refresh() async {
        loaded = false
        await loadIfNeeded()
    }

    /// 退出登录时调用：头像立即回到占位图，下次登录重新取。
    func reset() {
        profile = nil
        loaded = false
    }
}
