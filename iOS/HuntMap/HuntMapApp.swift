import SwiftUI

@main struct HuntMapApp: App {
    @StateObject private var state = FieldModel()
    var body: some Scene {
        WindowGroup { StartupRecoveryView().environmentObject(state) }
    }
}

/// Keep the first screen independent of map services and local file decoding.
private struct StartupRecoveryView: View {
    @EnvironmentObject private var state: FieldModel
    @State private var enter = false
    @State private var recovery = UserDefaults.standard.bool(forKey: "hunt.launch.initializing")
    private let key = "hunt.launch.initializing"

    var body: some View {
        Group {
            if enter && state.startupLoaded {
                MainView()
                    .onAppear { UserDefaults.standard.set(false, forKey: key) }
            } else {
                VStack(spacing: 20) {
                    Text("QAZ TRAIL").font(.largeTitle.bold())
                    if recovery {
                        Text("Предыдущий запуск не завершился. Сохранённые данные не удалены.")
                            .multilineTextAlignment(.center)
                        Button("Повторить запуск") { recovery = false; enter = true }
                            .buttonStyle(.borderedProminent)
                    } else {
                        ProgressView("Восстановление локальных данных")
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
                .foregroundStyle(.white)
                .task {
                    guard !recovery else { return }
                    enter = true
                }
            }
        }
        .task(id: enter) {
            guard enter else { return }
            UserDefaults.standard.set(true, forKey: key)
            await state.loadAtStartup()
        }
    }
}
