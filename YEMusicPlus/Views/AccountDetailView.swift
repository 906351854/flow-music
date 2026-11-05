import SwiftUI

/// 账号二级页。资料库首页只留一张可点的账号卡，
/// 身份详情、「关于」和退出登录都收进来 —— 首页就不会被参数类信息占掉半屏。
struct AccountDetailView: View {
    let profile: AccountResponse.Profile?
    var onSignOut: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmSignOut = false

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(spacing: 16) {
                    identityCard
                    aboutCard
                    signOutButton
                    disclaimer
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .softTopEdge()
        }
        .navigationTitle("账号")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("退出登录", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                onSignOut()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后需要重新扫码，才能同步歌单。")
        }
    }

    // MARK: - 身份

    private var identityCard: some View {
        VStack(spacing: 10) {
            ArtworkView(url: avatarURL, cornerRadius: 44)
                .frame(width: 88, height: 88)
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1)
                }

            Text(nickname)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.top, 2)

            HStack(spacing: 8) {
                Text(uidText)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)

                if let badge = vipBadge {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.16), in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var nickname: String {
        if let name = profile?.nickname, !name.isEmpty { return name }
        return "已登录"
    }

    private var uidText: String {
        if let uid = profile?.userId { return "UID \(uid)" }
        return "登录态已保存在本机"
    }

    private var vipBadge: String? {
        guard let vip = profile?.vipType, vip > 0 else { return nil }
        return "会员"
    }

    private var avatarURL: URL? {
        guard let raw = profile?.avatarUrl, !raw.isEmpty,
              var components = URLComponents(string: raw) else { return nil }
        components.scheme = "https"
        components.queryItems = [URLQueryItem(name: "param", value: "300y300")]
        return components.url
    }

    // MARK: - 关于

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "关于")

            infoRow("版本", AppVersion.display)
            infoRow("接口", AppConfig.shared.upstream.interfaceHost)
            infoRow("加密", "eapi · AES-128-ECB")
            infoRow("设备 ID", String(MusicClient.shared.deviceID.prefix(12)) + "…")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - 退出

    private var signOutButton: some View {
        Button {
            confirmSignOut = true
        } label: {
            Text("退出登录")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(red: 0.98, green: 0.45, blue: 0.45))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(Color.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var disclaimer: some View {
        Text("非官方客户端，仅在本机使用。音乐版权归各权利人所有。")
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }
}
