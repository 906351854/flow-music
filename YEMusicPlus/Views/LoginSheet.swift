import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

struct LoginSheet: View {
    var onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var qrImage: UIImage?
    @State private var status = "正在获取二维码…"
    @State private var failed: String?
    @State private var isPolling = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                VStack(spacing: 22) {
                    qrBlock
                    Text(status)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)

                    if let failed {
                        Text(failed)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.red.opacity(0.85))
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        Task { await restart() }
                    } label: {
                        Text("刷新二维码")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Theme.base)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .background(Theme.accent, in: Capsule())

                    Text("二维码内容为 music.163.com 登录链接，\n只用你自己的账号登录，不保存密码。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                        .multilineTextAlignment(.center)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 26)
                .padding(.top, 20)
            }
            .navigationTitle("扫码登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .task { await restart() }
    }

    private var qrBlock: some View {
        Group {
            if let qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 216, height: 216)
                    .padding(14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .frame(width: 216, height: 216)
                    .overlay { ProgressView().tint(Theme.accent) }
            }
        }
        .padding(.top, 8)
    }

    // MARK: - 流程

    private func restart() async {
        qrImage = nil
        failed = nil
        status = "正在获取二维码…"

        do {
            let unikey = try await MusicAPI.qrKey()
            guard let url = MusicAPI.qrContentURL(unikey: unikey) else {
                failed = "登录链接生成失败"
                return
            }
            qrImage = Self.makeQR(from: url.absoluteString)
            status = "请用手机网易云音乐扫描"
            await poll(unikey: unikey)
        } catch {
            failed = error.localizedDescription
            status = "二维码获取失败"
        }
    }

    private func poll(unikey: String) async {
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        let interval = AppConfig.shared.qr.pollInterval
        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(interval))
            if Task.isCancelled { return }

            do {
                let check = try await MusicAPI.qrCheck(unikey: unikey)
                switch check.state {
                case .waiting:
                    status = "等待扫码…"
                case .scanned:
                    status = "已扫码，请在手机上确认登录"
                case .success:
                    // 803 的登录态在响应体的 `cookie` 字段里（`;;` 分隔的非标准格式），
                    // 不是标准 Set-Cookie，必须手动吸收。
                    if let cookie = check.cookie, !cookie.isEmpty {
                        MusicClient.shared.ingestRawCookieString(cookie)
                    }
                    if MusicClient.shared.isLoggedIn {
                        status = "登录成功"
                        onFinished()
                        try? await Task.sleep(for: .milliseconds(500))
                        dismiss()
                    } else {
                        status = "登录返回成功但未拿到登录态"
                        failed = "服务端未下发 MUSIC_U，请重试"
                    }
                    return
                case .expired:
                    status = "二维码已过期，请刷新"
                    return
                case .other(let code):
                    status = "登录状态异常"
                    failed = "接口返回 \(code) \(check.message ?? "")"
                    return
                }
            } catch {
                failed = error.localizedDescription
                status = "轮询失败"
                return
            }
        }
        status = "二维码已超时，请刷新"
    }

    /// 用系统 CIFilter 生成二维码，不引第三方库。
    private static func makeQR(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
