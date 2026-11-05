import SwiftUI

/// 液态玻璃需要「底下有东西可折射」，否则玻璃只会是一块灰。
/// 所以底色之外铺三团径向光斑，滚动时玻璃会有颜色流动的感觉。
struct AppBackground: View {
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
        }
        .ignoresSafeArea()
    }
}
