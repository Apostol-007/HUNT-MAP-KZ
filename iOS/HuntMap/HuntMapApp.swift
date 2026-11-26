import SwiftUI
import UIKit

@main struct HuntMapApp: App {
    var body: some Scene {
        WindowGroup { StartupRecoveryView() }
    }
}

private struct StartupRecoveryView: View {
    @State private var state: FieldModel?
    @State private var enter = false
    @State private var recovery = UserDefaults.standard.bool(forKey: "hunt.launch.initializing")
    @State private var stage = "Ожидание"
    @State private var recoveryMode = false
    @State private var showMain = false
    private let key = "hunt.launch.initializing"
    private let stageKey = "hunt.launch.stage"
    private var previousStage: String { UserDefaults.standard.string(forKey: stageKey) ?? "неизвестно" }

    var body: some View {
        Group {
            if showMain, let state, enter && state.startupLoaded {
                MainView().environmentObject(state)
                    .onAppear {
                        checkpoint("Главный экран появился")
                        UserDefaults.standard.set(false, forKey: key)
                    }
            } else {
                VStack(spacing: 18) {
                    Text("QAZ TRAIL").font(.largeTitle.bold())
                    if recovery && !enter {
                        Text("Предыдущий запуск прерван. Этап: " + previousStage)
                            .multilineTextAlignment(.center)
                        Button("Безопасный режим") { recoveryMode = true; enter = true }
                            .buttonStyle(.borderedProminent)
                        Button("Обычный запуск") { enter = true }
                        ShareLink(item: diagnosticText) { Label("Отправить диагностику", systemImage: "square.and.arrow.up") }
                    } else if recoveryMode && state?.startupLoaded == true {
                        Text("Локальные данные прочитаны. Карты и сетевые сервисы не запущены.")
                            .multilineTextAlignment(.center)
                        if let state {
                            Text("Маршруты: \(state.tracks.count) · Метки: \(state.markers.count) · Угодья: \(state.zones.count)")
                            if !state.lastError.isEmpty { Text(state.lastError).foregroundStyle(.orange) }
                        }
                        Button("Открыть основной интерфейс") { checkpoint("Создание MainView"); showMain = true }
                            .buttonStyle(.borderedProminent)
                        ShareLink(item: diagnosticText) { Label("Отправить диагностику", systemImage: "square.and.arrow.up") }
                    } else {
                        ProgressView(stage)
                        ShareLink(item: diagnosticText) { Label("Отправить диагностику", systemImage: "square.and.arrow.up") }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
                .foregroundStyle(.white)
                .task {
                    if !recovery { enter = true }
                }
            }
        }
        .task(id: enter) {
            guard enter, state == nil else { return }
            UserDefaults.standard.set(true, forKey: key)
            checkpoint("Создание FieldModel")
            let model = FieldModel()
            state = model
            checkpoint("Чтение field.json и журнала маршрутов")
            await model.loadAtStartup()
            checkpoint("Локальные данные прочитаны")
            if !recoveryMode {
                checkpoint("Создание MainView")
                showMain = true
            }
        }
    }

    private func checkpoint(_ value: String) {
        stage = value
        UserDefaults.standard.set(value, forKey: stageKey)
    }

    private var diagnosticText: String {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("field.json")
        let size = file.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
        return "QAZ TRAIL startup diagnostics\nVersion: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?")\nBuild: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?")\niOS: \(UIDevice.current.systemVersion)\nStage: \(stage)\nLast stage: \(previousStage)\nfield.json bytes: \(size)\nError: \(state?.lastError ?? "")"
    }
}
