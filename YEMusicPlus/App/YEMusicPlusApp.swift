import SwiftUI

@main
struct YEMusicPlusApp: App {
    @StateObject private var player = PlayerService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .preferredColorScheme(.dark)
        }
    }
}
