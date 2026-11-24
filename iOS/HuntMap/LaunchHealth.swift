import Foundation

/// Minimal privacy-safe boot watchdog marker. Records timing and an interrupted
/// previous launch without capturing coordinates, track data or identifiers.
@MainActor enum LaunchHealth {
    private static let pendingKey = "hunt.launch.pending"
    private static var startedAt: TimeInterval?

    static func started() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: pendingKey) {
            AppDiagnosticLog.shared.record(
                severity: "warning", subsystem: "Запуск",
                operation: "Предыдущий запуск не завершён",
                code: "PREVIOUS_LAUNCH_INTERRUPTED",
                rootCause: "Предыдущее приложение закрылось до отметки готовности",
                nextAction: "Проверить iOS Analytics и журнал завершения процесса")
        }
        startedAt = ProcessInfo.processInfo.systemUptime
        defaults.set(true, forKey: pendingKey)
    }

    static func firstScreenReady() {
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - (startedAt ?? ProcessInfo.processInfo.systemUptime))
        UserDefaults.standard.set(elapsed, forKey: "hunt.diag.launchSeconds")
        UserDefaults.standard.set(false, forKey: pendingKey)
        AppDiagnosticLog.shared.record(
            severity: "info", subsystem: "Запуск",
            operation: "Главный экран готов", code: "READY",
            rootCause: "Интерфейс загружен",
            nextAction: "Не требуется",
            details: String(format: "First-screen readiness: %.2f s", elapsed))
    }
}
