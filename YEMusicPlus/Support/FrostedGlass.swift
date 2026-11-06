import SwiftUI
import UIKit

/// 一块真的会模糊的磨砂玻璃 —— 硬边直角，别给它套任何 mask / alpha。
///
/// 实测教训：SwiftUI 的 Material 和 UIKit 的 UIVisualEffectView 是一个脾气 ——
/// mask、opacity、compositingGroup 之类会把所在图层拍平的操作，
/// 都会打断对背景的采样，模糊直接消失，只剩一层若有若无的平色。
/// 所以这里保持裸的 effect view（模糊 guaranteed），
/// 羽化交给外面用「同源环境羽化罩」把硬边溶进背景（见 HomeView.lyricsLayer）。
struct FrostedGlass: UIViewRepresentable {
    /// 模糊强度：1.0 = 完整玻璃，越小越透。
    /// 用 UIKit 原生的 view.alpha 衰减整层玻璃 —— 采样照常进行，
    /// 只是合成时按透明度混回去；SwiftUI 层的 .opacity 才会拍平采样，别用那个。
    var intensity: CGFloat = 1.0

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(
            effect: UIBlurEffect(style: .systemUltraThinMaterialDark)
        )
        view.isUserInteractionEnabled = false
        view.alpha = intensity
        return view
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        if abs(view.alpha - intensity) > 0.001 {
            view.alpha = intensity
        }
    }
}
