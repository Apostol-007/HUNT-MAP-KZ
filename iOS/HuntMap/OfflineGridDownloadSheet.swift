import SwiftUI

/// Selection summary for the MapLibre grid. Downloads only published files with known bounds.
struct OfflineGridDownloadSheet: View {
    @ObservedObject var hosting: HostingOfflineDownloads
    @ObservedObject var tiles: OfflineTileStore
    @Binding var selected: Set<String>
    let step: Double
    @Environment(\.dismiss) private var dismiss
    @State private var task: Task<Void, Never>?

    private var cells: [OfflineGridCell] {
        selected.sorted().compactMap { OfflineGridCell(id: $0, step: step) }
    }
    private var routePacks: [HostingRoutingPack] { hosting.routePacks(in: cells) }
    private var mapPacks: [HostingMapPack] { hosting.mapPacks(in: cells) }
    private var pendingRoutes: [HostingRoutingPack] {
        routePacks.filter { !hosting.installedRoutes.contains($0.id) }
    }
    private var pendingMaps: [HostingMapPack] {
        mapPacks.filter { pack in
            !tiles.installed.contains(where: { $0.sha256.lowercased() == pack.sha256.lowercased() })
        }
    }
    private var bytes: Int64 {
        pendingMaps.reduce(Int64(0)) { $0 + $1.bytes } +
        pendingRoutes.reduce(Int64(0)) { $0 + $1.bytes }
    }
    private var count: Int { pendingRoutes.count + pendingMaps.count }
    private var unknownBounds: Int { hosting.maps.filter { $0.bounds == nil }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    Text("Выбрано ячеек: \(cells.count)")
                        .font(.title3.bold())
                    Text("Размер сетки: \(String(format: "%.2f°", step)). Пакеты подбираются по пересечению координатных границ.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Label("MBTiles: \(mapPacks.count)", systemImage: "map.fill")
                        Spacer()
                        Label("Дороги: \(routePacks.count)", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    }
                    .font(.subheadline)
                    Text("Для скачивания: \(count) пакетов · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                        .font(.headline)
                    if unknownBounds > 0 {
                        Text("\(unknownBounds) растровых пакетов не содержат bounds в каталоге и не могут быть отобраны по сетке. Их можно установить из общего менеджера офлайн-карт.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if !pendingRoutes.isEmpty {
                        Text("Дорожные сети").font(.headline)
                        ForEach(pendingRoutes.prefix(30)) { pack in
                            HStack {
                                Text(pack.name).lineLimit(1)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: pack.bytes, countStyle: .file))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                        if pendingRoutes.count > 30 {
                            Text("И ещё \(pendingRoutes.count - 30) пакетов").font(.caption)
                        }
                    }
                    if hosting.busy || task != nil {
                        ProgressView(value: hosting.progress)
                        Text("\(hosting.completedPacks) / \(hosting.plannedPacks) · \(hosting.activePack)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(hosting.status).font(.caption).foregroundStyle(.secondary)
                    Button("Обновить каталоги") { Task { await hosting.refresh() } }
                        .disabled(hosting.busy || task != nil)
                    if task == nil {
                        Button("Скачать выбранные пакеты") {
                            let snapshot = cells
                            task = Task {
                                await hosting.downloadGrid(cells: snapshot, tiles: tiles)
                                task = nil
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(count == 0 || hosting.busy)
                    } else {
                        Button("Остановить после текущего файла", role: .destructive) { task?.cancel() }
                    }
                    Text("Сетка выбирает готовые пакеты с сервера. Она не создаёт новые MBTiles из онлайн-карт и не скачивает массово публичные тайлы.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Офлайн по сетке")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .task { if hosting.routes.isEmpty && hosting.maps.isEmpty { await hosting.refresh() } }
        }
    }
}
