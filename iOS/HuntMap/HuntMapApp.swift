import SwiftUI
@main struct HuntMapApp: App {
    init() { _ = HuntPerformance.shared }
    @StateObject private var state = FieldModel()
    var body: some Scene { WindowGroup { MainView().environmentObject(state) } }
}
