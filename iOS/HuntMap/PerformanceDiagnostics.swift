import Foundation
import MetricKit
import UIKit

/// System diagnostics are delivered by iOS asynchronously, not a live crash detector.
final class PerformanceDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = PerformanceDiagnostics()
    private override init() { super.init() }
    private var started = false

    @MainActor func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let hangs = payload.hangDiagnostics ?? []
            let crashes = payload.crashDiagnostics ?? []
            let duration = hangs.reduce(0.0) { $0 + $1.hangDuration.converted(to: .seconds).value }
            let count = hangs.count
            let crashCount = crashes.count
            guard count + crashCount > 0 else { continue }
            Task { @MainActor in
                AppDiagnosticLog.shared.record(
                    subsystem: "Производительность",
                    operation: "Системная диагностика MetricKit",
                    code: "SYSTEM_DIAGNOSTICS",
                    rootCause: "iOS зарегистрировала зависания или аварийные завершения",
                    nextAction: "Сопоставить с версией приложения и журналом операций",
                    details: "Зависания: \(count); суммарно: \(String(format: "%.2f", duration)) с; сбои: \(crashCount)"
                )
            }
        }
    }
}
