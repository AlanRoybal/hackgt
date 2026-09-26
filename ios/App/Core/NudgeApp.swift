import DesignSystem
import SwiftUI

@main
struct NudgeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    private let app = AppModel.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if let screen = ScreenshotMode.current {
                    ScreenshotHost(screen: screen)
                } else {
                    RootView()
                        .task { await app.launch() }
                        .onOpenURL { app.open(url: $0) }
                }
            }
            .environment(app)
            .tint(Palette.lavenderStrong)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await app.foregrounded() } }
        }
    }
}
