import SwiftUI

enum Theme {
    /// 主强调色：偏青的薄荷绿，和图标一致。
    static let accent = Color(red: 0.42, green: 0.92, blue: 0.84)
    static let accentDeep = Color(red: 0.13, green: 0.62, blue: 0.55)

    static let base = Color(red: 0.027, green: 0.047, blue: 0.086)
    static let violet = Color(red: 0.36, green: 0.24, blue: 0.72)
    static let ocean = Color(red: 0.10, green: 0.34, blue: 0.60)

    static let hairline = Color.white.opacity(0.08)
    static let secondaryText = Color.white.opacity(0.55)
    static let tertiaryText = Color.white.opacity(0.32)
}
