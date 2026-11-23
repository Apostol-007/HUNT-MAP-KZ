import SwiftUI
@main struct HuntMapApp: App {
    @StateObject private var state = FieldModel()
    var body: some Scene { WindowGroup { MainView().environmentObject(state) } }
}
