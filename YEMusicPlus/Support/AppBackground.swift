import SwiftUI

/// 当前封面糊成的环境雾 —— 主页底色的辨识度全在这一层。
/// 现在所有界面共用同一个渲染组件，色调天然统一。
/// 全部自绘、不依赖系统玻璃采样，不会出现「模糊消失」。
/// 歌词层的轻雾也用它（blur 传小值），两层雾和页面背景永远接得上。
struct AmbientFog: View {
    let track: Track
    var blur: CGFloat = 64

    var body: some View {
        // ⚠️ scaledToFill 的图会把自己巨大的理想尺寸一路向上传 ——
        // 直接当 ZStack 子视图时，整个页面会被撑到屏幕外（实测全 App 布局拉爆）。
        // 所以这里用 GeometryReader 把尺寸「锁定」为调用方实际给的空间，
        // 并 clipped 裁掉溢出：无论谁用它、以什么方式嵌，都不可能撑宽页面。
        GeometryReader { geo in
            ZStack {
                AsyncImage(url: track.coverURL, transaction: Transaction(animation: .easeOut(duration: 0.5))) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                            .blur(radius: blur, opaque: true)
                            // 半径越大边缘漏得越多，放大倍数跟着半径走，盖住漏边。
                            .scaleEffect(blur >= 32 ? 1.4 : 1.18)
                    }
                }
                .id(track.id)
                .transition(.opacity)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()

                LinearGradient(
                    stops: [
                        .init(color: Theme.base.opacity(0.26), location: 0),
                        .init(color: Theme.base.opacity(0.50), location: 0.42),
                        .init(color: Theme.base.opacity(0.86), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// 液态玻璃需要「底下有东西可折射」，否则玻璃只会是一块灰。
/// 所以底色之外铺三团径向光斑，滚动时玻璃会有颜色流动的感觉。
/// 上面再叠当前封面糊成的环境雾（跟随正在播放的曲目）——
/// 主页和其他界面由此共用同一套底色。
struct AppBackground: View {
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        ZStack {
            Theme.base

            RadialGradient(
                colors: [Theme.accentDeep.opacity(0.55), .clear],
                center: UnitPoint(x: 0.80, y: 0.06),
                startRadius: 0,
                endRadius: 420
            )

            RadialGradient(
                colors: [Theme.violet.opacity(0.42), .clear],
                center: UnitPoint(x: 0.08, y: 0.38),
                startRadius: 0,
                endRadius: 380
            )

            RadialGradient(
                colors: [Theme.ocean.opacity(0.40), .clear],
                center: UnitPoint(x: 0.62, y: 0.90),
                startRadius: 0,
                endRadius: 440
            )

            // 主页那层封面雾：有歌在放才出现，只跟着 player 走。
            // 浏览、暂停、切标签页都不动它 —— 之前绑在浏览位置上，
            // 每停一张就整屏换一次色，看久了很晃。
            if let current = player.current {
                AmbientFog(track: current)
                    .id(current.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.55), value: player.current?.id)
        .ignoresSafeArea()
    }
}
