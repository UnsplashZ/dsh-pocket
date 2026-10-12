import DSHKit
import SwiftUI

@main
struct DSHPocketApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
                .task { await model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            Task {
                switch phase {
                case .active: await model.handleForeground()
                case .background: await model.handleBackground()
                default: break
                }
            }
        }
    }
}
