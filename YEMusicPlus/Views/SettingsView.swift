import SwiftUI

/// 设置页。从资料库右上角的齿轮进入。
///
/// 只放三类东西：缓存（这次新增）、播放（音质）、关于。
/// 风格和资料库一致 —— 雾底 + 玻璃卡片，不再引入新的视觉语言。
struct SettingsView: View {

    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var cache = AudioCacheStore.shared

    @AppStorage(AudioCacheStore.Key.enabled) private var cacheEnabled = true
    @AppStorage(AudioCacheStore.Key.capMB) private var capMB = 512

    @State private var confirmClear = false

    private let capOptions = [256, 512, 1024, 2048]

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(spacing: 16) {
                    cacheCard
                    playbackCard
                    aboutCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .softTopEdge()
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("清空缓存", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { cache.clear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已缓存的 \(cache.fileCount) 首歌会被删除，下次播放需要重新下载。")
        }
        .onChange(of: capMB) { _, _ in cache.enforceLimit() }
        .onAppear { cache.enforceLimit() }
    }

    // MARK: - 缓存

    private var cacheCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "缓存", subtitle: "听过的歌存本机")

            Toggle(isOn: $cacheEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("缓存播放过的歌曲")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.white)
                    Text("下次播放直接读本地，省流量，也少打扰服务端")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Theme.accent)

            if cacheEnabled {
                Divider().overlay(Theme.hairline)

                HStack {
                    Text("容量上限")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer(minLength: 12)
                    Picker("容量上限", selection: $capMB) {
                        ForEach(capOptions, id: \.self) { size in
                            Text("\(size) MB").tag(size)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.accent)
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("已用 \(byteText(cache.usedBytes))")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.white.opacity(0.78))
                        Spacer(minLength: 8)
                        Text("\(cache.fileCount) 首 · 上限 \(capMB) MB")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiaryText)
                    }

                    usageBar
                }

                Button {
                    confirmClear = true
                } label: {
                    Text("清空缓存")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(cache.fileCount > 0
                                         ? Color(red: 0.98, green: 0.45, blue: 0.45)
                                         : Theme.tertiaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(cache.fileCount == 0)
                .background(.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text("关闭后不再缓存新歌，已缓存的仍可播放。缓存放在系统「可清理」空间里，存储吃紧时可能被系统回收；清除 App 数据也会一并清掉。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var usageBar: some View {
        GeometryReader { geo in
            let ratio = cache.capBytes > 0
                ? min(Double(cache.usedBytes) / Double(cache.capBytes), 1)
                : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.10))
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(4, geo.size.width * ratio))
                    .animation(.easeOut(duration: 0.35), value: cache.usedBytes)
            }
        }
        .frame(height: 5)
    }

    // MARK: - 播放

    private var playbackCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "播放")

            ForEach(AppConfig.shared.quality.levels) { level in
                Button {
                    player.qualityLevel = level.id
                } label: {
                    HStack {
                        Text(level.name)
                            .font(.system(size: 13.5))
                            .foregroundStyle(.white.opacity(0.9))
                        Spacer(minLength: 12)
                        if player.qualityLevel == level.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(.vertical, 7)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }

            Text("没有对应音源时自动往下降档，不会直接报错。")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - 关于

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "关于")

            infoRow("版本", AppVersion.display)
            infoRow("音质", player.qualityLabel)

            Link(destination: URL(string: "https://github.com/906351854/flow-music")!) {
                HStack {
                    Text("项目主页")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                    Spacer(minLength: 12)
                    Text("GitHub")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.accent.opacity(0.8))
                }
            }
            .buttonStyle(.plain)

            Text("非官方客户端，仅在本机使用。音乐版权归各权利人所有。")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
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
        }
    }

    private func byteText(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
