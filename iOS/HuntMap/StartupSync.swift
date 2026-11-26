import Foundation
import SwiftUI
import Network

/// The launch gate never deletes installed content when the network or a manifest fails.
@MainActor final class StartupSync: ObservableObject {
    @Published private(set) var presented = true
    @Published private(set) var title = "Проверяем подключение"
    @Published private(set) var detail = "Локальные карты уже доступны"
    @Published private(set) var progress = 0.0
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var errors: [String] = []
    @Published private(set) var isDownloading = false
    private var started = false
    private var cancelled = false
    private var startupTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?

    func begin(hosting: HostingOfflineDownloads, tiles: OfflineTileStore,
               protomaps: ProtomapsOfflineStore, model: FieldModel,
               valhalla: ValhallaRoutingStore) {
        guard startupTask == nil, !cancelled else { return }
        isDownloading = true
        releaseTask = Task {
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            presented = false
        }
        startupTask = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { isDownloading = false; return }
            await start(hosting: hosting, tiles: tiles, protomaps: protomaps,
                        model: model, valhalla: valhalla)
        }
    }

    func skip() {
        cancelled = true
        startupTask?.cancel()
        releaseTask?.cancel()
        presented = false
    }

    /// NWPathMonitor gives an immediate offline bypass. The network call still decides
    /// whether the hosting actually responds, and errors never block app launch.
    private func internetAvailable() async -> Bool {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "kz.huntmap.startup-network")
        let box = NetworkGate()
        monitor.pathUpdateHandler = { path in box.set(path.status == .satisfied) }
        monitor.start(queue: queue)
        defer { monitor.cancel() }
        for _ in 0..<14 {
            if let status = box.get() { return status }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return false
    }

    func start(hosting: HostingOfflineDownloads, tiles: OfflineTileStore,
               protomaps: ProtomapsOfflineStore, model: FieldModel,
               valhalla: ValhallaRoutingStore) async {
        guard !started else { return }
        started = true
        defer { releaseTask?.cancel(); isDownloading = false; presented = false }
        guard !cancelled, !Task.isCancelled else { return }
        guard await internetAvailable() else {
            AppDiagnosticLog.shared.record(severity: "info", subsystem: "Загрузка",
                operation: "Проверка сети на старте", code: "OFFLINE",
                rootCause: "Сеть не подключена", nextAction: "Открыть сохранённые карты")
            title = "Нет интернета"
            detail = "Открываем сохранённые карты"
            presented = false
            return
        }
        guard !cancelled, !Task.isCancelled else { return }
        title = "Проверяем обновления"
        detail = "Каталоги карт и навигационных данных"
        // The host can be unavailable despite a live internet connection.
        await hosting.refresh()
        guard !cancelled else { return }
        await protomaps.refresh()
        guard !cancelled else { return }
        let maps = hosting.maps.filter { pack in
            !tiles.installed.contains { $0.sha256.lowercased() == pack.sha256.lowercased() }
        }
        var roads: [HostingRoutingPack] = []
        var zones: [HostingZonePack] = []
        for pack in hosting.routes {
            guard !cancelled, !Task.isCancelled else { return }
            if await hosting.needsRouteUpdate(pack) { roads.append(pack) }
        }
        for pack in hosting.zones {
            guard !cancelled, !Task.isCancelled else { return }
            if await hosting.needsZoneUpdate(pack) { zones.append(pack) }
        }
        let protos = protomaps.available.filter { pack in
            !protomaps.installed.contains { $0.id == pack.id && $0.sha256.lowercased() == pack.sha256.lowercased() }
        }
        // Valhalla checks its own manifest and SHA; it is a separate optional package.
        let wantsValhalla = true
        total = maps.count + roads.count + zones.count + protos.count + (wantsValhalla ? 1 : 0)
        if total == 0 {
            title = "Все данные актуальны"
            progress = 1
            presented = false
            return
        }
        isDownloading = true
        for pack in maps {
            guard !cancelled else { return }
            title = "Загружаем карты"
            detail = pack.name
            await hosting.installMap(pack, tiles: tiles)
            if !tiles.installed.contains(where: { $0.sha256.lowercased() == pack.sha256.lowercased() }) {
                errors.append("Карта «\(pack.name)»: \(hosting.status)")
            }
            tick()
        }
        for pack in roads {
            guard !cancelled else { return }
            title = "Загружаем дороги и тропы"
            detail = pack.name
            await hosting.installRoute(pack)
            if await hosting.needsRouteUpdate(pack) { errors.append("Маршрутная сеть «\(pack.name)»: \(hosting.status)") }
            tick()
        }
        for pack in zones {
            guard !cancelled else { return }
            title = "Загружаем охотугодья"
            detail = pack.name
            await hosting.installZones(pack, model: model)
            if await hosting.needsZoneUpdate(pack) { errors.append("Границы «\(pack.name)»: \(hosting.status)") }
            tick()
        }
        if !protos.isEmpty {
            guard !cancelled else { return }
            title = "Загружаем векторные карты"
            detail = "PMTiles: \(protos.count) пакетов"
            await protomaps.downloadAllAvailable()
            for item in protos where !protomaps.installed.contains(where: { $0.id == item.id && $0.sha256 == item.sha256 }) {
                errors.append("PMTiles «\(item.name)»: \(protomaps.status)")
            }
            completed += protos.count
            progress = Double(completed) / Double(max(total, 1))
        }
        if wantsValhalla && !cancelled {
            title = "Проверяем офлайн-навигацию"
            detail = "Данные Valhalla"
            await valhalla.downloadFromHosting()
            if !valhalla.tilesInstalled { errors.append("Valhalla: пакет пока недоступен") }
            tick()
        }
        for failure in errors {
            AppDiagnosticLog.shared.record(subsystem: "Синхронизация",
                operation: "Обновление каталога или пакета", code: "UPDATE_FAILED",
                rootCause: "Не удалось обновить один из наборов данных",
                nextAction: "Проверить доступность каталога на хостинге, SHA-256 и свободное место",
                details: failure, endpoint: "create.web-works.kz/maps")
        }
        AppDiagnosticLog.shared.record(severity: "info", subsystem: "Синхронизация",
            operation: "Итог проверки обновлений", code: errors.isEmpty ? "OK" : "PARTIAL",
            rootCause: errors.isEmpty ? "Данные актуальны" : "Некоторые пакеты не обновились",
            nextAction: errors.isEmpty ? "Не требуется" : "Изучить ошибки обновления",
            details: "Пакеты: \(completed)/\(total); ошибок: \(errors.count)",
            endpoint: "create.web-works.kz/maps")
        title = errors.isEmpty ? "Данные обновлены" : "Обновление завершено с замечаниями"
        detail = errors.isEmpty ? "Все доступные пакеты установлены" : "Существующие данные сохранены"
        isDownloading = false
        progress = 1
        presented = false
    }

    private func tick() {
        completed += 1
        progress = Double(completed) / Double(max(1, total))
    }
}

/// Lock protects the callback's state when the connectivity queue is different
/// from the main actor.
private final class NetworkGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    func set(_ next: Bool) { lock.lock(); value = next; lock.unlock() }
    func get() -> Bool? { lock.lock(); defer { lock.unlock() }; return value }
}

private struct StartupTip: Decodable {
    let category: String
    let text: String
    let source_url: String
}
private struct TipCollection: Decodable {
    let schema: String
    let tips: [StartupTip]
}

private enum StartupTips {
    static let items: [StartupTip] = {
        guard let url = Bundle.main.url(forResource: "StartupTips", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode(TipCollection.self, from: data),
              result.schema == "hunt-startup-tips-v1", !result.tips.isEmpty else {
            return [StartupTip(category: "Туризм", text: "Проверяйте погоду и сохраняйте маршрут перед выходом.", source_url: "https://www.nps.gov/articles/10essentials.htm")]
        }
        return result.tips
    }()
}

struct StartupSyncScreen: View {
    @ObservedObject var sync: StartupSync
    @ObservedObject var hosting: HostingOfflineDownloads
    @ObservedObject var protomaps: ProtomapsOfflineStore
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.025, green: 0.09, blue: 0.09), .black],
                           startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer(minLength: 32)
                Image(systemName: "map.fill")
                    .font(.system(size: 54, weight: .thin)).foregroundStyle(.mint)
                    .padding(30)
                    .background(.mint.opacity(0.09), in: Circle())
                VStack(spacing: 8) {
                    Text("QAZ TRAIL").font(.system(size: 31, weight: .bold, design: .rounded))
                    Text(sync.title).font(.headline).foregroundStyle(.white.opacity(0.85))
                    Text(sync.detail).font(.subheadline).foregroundStyle(.white.opacity(0.64))
                        .lineLimit(2).multilineTextAlignment(.center)
                }
                VStack(spacing: 12) {
                    ProgressView(value: sync.progress).tint(.mint)
                    HStack {
                        Text(sync.isDownloading ? "Синхронизация" : "Проверка обновлений")
                        Spacer()
                        Text("\(Int(sync.progress * 100))%")
                    }.font(.caption).foregroundStyle(.white.opacity(0.8))
                    if sync.total > 0 {
                        Text("Пакеты: \(sync.completed) / \(sync.total)")
                            .font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
                    if hosting.busy && hosting.progress > 0 && hosting.progress < 1 {
                        ProgressView(value: hosting.progress).tint(.cyan)
                            .accessibilityLabel("Прогресс текущего пакета")
                    }
                    if protomaps.busy && protomaps.progress > 0 && protomaps.progress < 1 {
                        ProgressView(value: protomaps.progress).tint(.cyan)
                    }
                }.padding(18).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                TimelineView(.periodic(from: .now, by: 8)) { timeline in
                    let index = Int(timeline.date.timeIntervalSince1970 / 8) % StartupTips.items.count
                    let item = StartupTips.items[index]
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Совет · \(item.category)", systemImage: "lightbulb")
                            .font(.caption.bold()).foregroundStyle(.mint)
                        Text(item.text).font(.body).fixedSize(horizontal: false, vertical: true)
                        Text("Советы по материалам NPS / Hunter-ed / Take Me Fishing")
                            .font(.caption2).foregroundStyle(.white.opacity(0.45))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                        .id(index).transition(.opacity)
                }
                Spacer()
                Button { sync.skip() } label: {
                    Text("Открыть приложение без ожидания")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .contentShape(Rectangle())
                        .foregroundStyle(HuntReference.green)
                        .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("startup_skip")
                .padding(.bottom, 16)
            }
            .padding(.horizontal, 24)
        }
        .preferredColorScheme(.dark)
    }
}