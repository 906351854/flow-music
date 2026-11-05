import UIKit
import QuartzCore

/// 拖动牌堆时的连续触感。
///
/// `sensoryFeedback` 只能挂在某个状态值变化上，一次手势里最多给一次反馈；
/// 但翻卡片的手感需要「手指每拨过一张就轻轻顿一下」，所以这里直接用
/// UIKit 的 impact generator 主动打点。
///
/// 甩得快时一秒可能越过好几张，打点太密会糊成一串震动，所以两次之间
/// 留 60ms 的间隔；强度也比吸附那一下更轻，避免抢戏。
@MainActor
enum DeckHaptics {
    private static let impact = UIImpactFeedbackGenerator(style: .light)
    private static var lastTick: CFTimeInterval = 0

    /// 手指按下前先唤醒引擎，第一次打点的延迟会小很多。
    static func prepare() {
        impact.prepare()
    }

    static func tick(intensity: CGFloat = 0.5) {
        let now = CACurrentMediaTime()
        guard now - lastTick >= 0.06 else { return }
        lastTick = now
        impact.impactOccurred(intensity: intensity)
        // 连续拖动时保持引擎热着，别每次重新启动。
        impact.prepare()
    }
}
