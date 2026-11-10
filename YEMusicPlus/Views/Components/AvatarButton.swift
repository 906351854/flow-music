import SwiftUI

/// 右上角的头像入口：玻璃圆钮 + 当前账号头像（未登录时是人形占位）。
/// 点开是资料库，设置也收在那里。
///
/// 用 `.interactive()` 的玻璃：按下时玻璃会跟着手指轻微收缩、抬起回弹，
/// 「动态」的手感来自这层原生材质，而不是自己加缩放动画。
struct AvatarButton: View {
    @ObservedObject private var account = AccountStore.shared

    let action: () -> Void

    /// 只用 Debug 调试：截图给官网/README 用的时候把账号头像换成占位图标，
    /// 免得把自己的头像发到公开页面上。发布包里这个分支不存在。
    private var forceAnonymous: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["HOME_ANON"] == "1"
        #else
        false
        #endif
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if let url = account.avatarURL, !forceAnonymous {
                    ArtworkView(url: url, cornerRadius: 15)
                        .frame(width: 29, height: 29)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: 33, height: 33)
            .glassEffect(.regular.interactive(), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("资料库与设置")
    }
}
