import Foundation

enum AppVersion {
    /// 界面上的版本号一律从 Bundle 读，避免工程里改了、界面还写着旧值。
    static var display: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "v\(marketing) (\(build))"
    }

    static var name: String {
        Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "Flow Music"
    }
}
