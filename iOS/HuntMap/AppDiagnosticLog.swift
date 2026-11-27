import Foundation

struct AppDiagnosticEvent: Codable, Identifiable, Sendable {
    let id: UUID
    let recordedAt: Date
    let severity: String
    let subsystem: String
    let operation: String
    let code: String
    let rootCause: String
    let nextAction: String
    let details: String
    let endpoint: String
}

@MainActor final class AppDiagnosticLog: ObservableObject {
    static let shared = AppDiagnosticLog()
    @Published private(set) var events: [AppDiagnosticEvent] = []
    private let limit = 250
    private let storage: URL

    private init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        storage = folder.appendingPathComponent("events.json")
        if let data = try? Data(contentsOf: storage),
           let value = try? JSONDecoder().decode([AppDiagnosticEvent].self, from: data) {
            events = Array(value.suffix(limit))
        }
    }

    func record(severity: String = "error", subsystem: String, operation: String,
                code: String, rootCause: String, nextAction: String,
                details: String = "", endpoint: String = "") {
        // No exact GPS, tokens, URLs with query strings or user data in diagnostic events.
        let record = AppDiagnosticEvent(id: UUID(), recordedAt: Date(), severity: severity,
                                        subsystem: subsystem, operation: operation, code: code,
                                        rootCause: rootCause, nextAction: nextAction,
                                        details: String(details.prefix(300)),
                                        endpoint: String(endpoint.prefix(120)))
        events.append(record)
        if events.count > limit { events.removeFirst(events.count - limit) }
        if let data = try? JSONEncoder().encode(events) {
            try? data.write(to: storage, options: .atomic)
        }
    }

    func recordHTTP(subsystem: String, operation: String, code: Int,
                    responseData: Data, path: String, usedCache: Bool) {
        let (cause, action): (String, String)
        switch code {
        case 400: (cause, action) = ("Некорректные параметры погодного API", "Проверить временной диапазон, координаты и поля запроса")
        case 401, 403: (cause, action) = ("Доступ к сервису запрещён", "Проверить права доступа, тариф и ограничения провайдера")
        case 404: (cause, action) = ("Адрес API не найден", "Проверить путь endpoint и версию API")
        case 408, 504: (cause, action) = ("Превышено время ожидания сервера", "Повторить запрос и проверить задержку сети")
        case 429: (cause, action) = ("Превышен лимит запросов провайдера", "Сократить частоту запросов и ограничить параллелизм")
        case 500...599: (cause, action) = ("Ошибка сервера погодного провайдера", "Повторить позднее; использовать сохранённый кеш")
        default: (cause, action) = ("Неожиданный HTTP-ответ", "Проверить код и ответ сервера")
        }
        // Extract only standardized short reason from a JSON API error object.
        var reason = ""
        if let payload = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let text = payload["reason"] as? String {
            reason = text
        }
        // Avoid carrying query strings or arbitrary response bodies into a shareable log.
        reason = String(reason.prefix(180))
        record(subsystem: subsystem, operation: operation, code: "HTTP \(code)",
               rootCause: cause, nextAction: action,
               details: "Provider reason: \(reason.isEmpty ? "not provided" : reason); cache: \(usedCache ? "available" : "empty")",
               endpoint: path)
    }

    func recordError(subsystem: String, operation: String, error: Error,
                     endpoint: String = "", usedCache: Bool = false) {
        let ns = error as NSError
        let (cause, action): (String, String)
        if error is CancellationError || (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) { return }
        if ns.domain == "kCLErrorDomain" && ns.code == 0 {
            (cause, action) = ("Координаты временно недоступны", "Дождаться следующего GPS-сигнала")
        } else if ns.domain == NSCocoaErrorDomain && ns.code == 260 {
            (cause, action) = ("Локальный файл отсутствует", "Проверить установку необходимого пакета")
        } else if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet:
                (cause, action) = ("Нет доступа к интернету", "Показать кеш и повторить при восстановлении сети")
            case NSURLErrorTimedOut:
                (cause, action) = ("Тайм-аут обращения к серверу", "Проверить качество сети и время ответа")
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                (cause, action) = ("Ошибка DNS или недоступен домен", "Проверить DNS, VPN и адрес API")
            case NSURLErrorSecureConnectionFailed:
                (cause, action) = ("Ошибка TLS", "Проверить сертификат сервера и системное время")
            case NSURLErrorCancelled:
                (cause, action) = ("Запрос отменён при смене области или часа", "Повторять не нужно, если начат новый запрос")
            case NSURLErrorBadServerResponse:
                (cause, action) = ("HTTP-ответ не соответствует ожиданиям", "Проверить HTTP-код в предыдущем событии журнала")
            default:
                (cause, action) = ("Сетевая ошибка iOS", "Сверить код NSError и состояние подключения")
            }
        } else {
            (cause, action) = ("Сбой обработки данных или локальной операции", "Проверить схему, размер файла и декодирование")
        }
        record(severity: ns.domain == "kCLErrorDomain" && ns.code == 0 ? "warning" : "error", subsystem: subsystem, operation: operation,
               code: "\(ns.domain) \(ns.code)", rootCause: cause, nextAction: action,
               details: "iOS: \(String(ns.localizedDescription.prefix(150))); cache: \(usedCache ? "available" : "empty")",
               endpoint: endpoint)
    }

    func export() -> String {
        let formatter = ISO8601DateFormatter()
        return events.reversed().map { e in
            """
            [\(formatter.string(from: e.recordedAt))] \(e.severity.uppercased()) \(e.subsystem) / \(e.operation)
            Code: \(e.code)
            Cause: \(e.rootCause)
            Action: \(e.nextAction)
            Endpoint: \(e.endpoint)
            Details: \(e.details)
            """
        }.joined(separator: "\n---\n")
    }

    func clear() {
        events = []
        try? FileManager.default.removeItem(at: storage)
    }
}
