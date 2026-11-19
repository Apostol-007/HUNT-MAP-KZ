import SwiftUI
@main struct HuntMapApp: App {
    @StateObject private var state = FieldModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            MainView().environmentObject(state)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { state.flushPendingRoute() }
                }
        }
    }
}
