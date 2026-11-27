import SwiftUI

struct OfflineManagerScreen: View {
    @ObservedObject var hosting: HostingOfflineDownloads
    @ObservedObject var tiles: OfflineTileStore
    @ObservedObject var protomaps: ProtomapsOfflineStore
    @ObservedObject var valhalla: ValhallaRoutingStore
    let startupBusy: Bool
    var onCancelStartup: () -> Void = {}
    var addressControls: AnyView? = nil
    var onAddressAppear: () async -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var catalogAddress = ""
    @State private var freeBytes: Int64?
    @State private var showPackages = false
    @State private var packageKind: PackageKind = .vector
    private enum PackageKind: String, CaseIterable { case vector = "PMTiles", raster = "MBTiles", roads = "Дороги", navigation = "Valhalla" }
    @State private var job: Task<Void, Never>?
    @State private var deletePack: ProtomapsPack?
    private enum Filter: String, CaseIterable { case all = "Все", installed = "Установлено", missing = "Доступно" }
    private var locked: Bool { startupBusy || job != nil || hosting.busy || protomaps.busy }
    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    private func matches(_ name: String, installed: Bool) -> Bool {
        (query.isEmpty || name.localizedCaseInsensitiveContains(query)) &&
        (filter == .all || (filter == .installed && installed) || (filter == .missing && !installed))
    }
    private func start(_ operation: @escaping @MainActor () async -> Void) {
        guard !locked else { return }
        job = Task { @MainActor in
            await operation()
            job = nil
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    summary
                    if let addressControls { addressControls.huntSurface() }
                    controls
                    if hosting.busy || protomaps.busy || job != nil { progress }
                    if showPackages {
                        Picker("Тип пакета", selection: $packageKind) {
                            ForEach(PackageKind.allCases, id: \.self) { kind in Text(kind.rawValue).tag(kind) }
                        }.pickerStyle(.segmented)
                        switch packageKind {
                        case .vector: vectorSection
                        case .raster: rasterSection
                        case .roads: roadsSection
                        case .navigation: navigationSection
                        }
                    } else {
                        ProgressView("Подготовка списка…").font(.caption)
                    }
                }.padding(.horizontal, 18).padding(.vertical, 14)
            }.background(HuntReference.background.ignoresSafeArea())
            .navigationTitle("Офлайн-карты")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("Готово") { dismiss() }.accessibilityIdentifier("offline_manager_close")
            } }
            .confirmationDialog("Удалить векторный пакет?", isPresented: Binding(
                get: { deletePack != nil }, set: { if !$0 { deletePack = nil } })) {
                Button("Удалить", role: .destructive) {
                    if let item = deletePack { protomaps.delete(item) }
                    deletePack = nil
                }.disabled(locked)
                Button("Отмена", role: .cancel) { deletePack = nil }
            } message: { Text("Удаляется только выбранный PMTiles. Маршруты и метки сохраняются.") }
        }
        .interactiveDismissDisabled(job != nil)
        .onAppear { catalogAddress = protomaps.catalogAddress; HuntPerformance.shared.markOfflineOpened() }
        .task {
            // Let the sheet present before constructing any catalogue rows.
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard !Task.isCancelled else { return }
            showPackages = true
            await onAddressAppear()
            let free = await Task.detached(priority: .utility) {
                let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                return try? folder?.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            }.value
            guard !Task.isCancelled else { return }
            freeBytes = free
        }
    }
    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Установленные данные").font(.headline).accessibilityIdentifier("offline_manager_ready")
            HStack {
                count("PMTiles", protomaps.installed.count)
                Spacer()
                count("MBTiles", tiles.installed.count)
                Spacer()
                count("Дороги", hosting.installedRoutes.count)
            }
            if let free = freeBytes {
                Text("Свободно для загрузок: " + size(free)).font(.caption).foregroundStyle(HuntReference.muted)
            }
            Text("Установленные пакеты доступны без сети. Наличие пакета не гарантирует покрытие всей территории.")
                .font(.caption).foregroundStyle(HuntReference.muted)
        }.huntSurface()
    }
    private func count(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(value)).font(.title2.bold()).foregroundStyle(HuntReference.green)
            Text(label).font(.caption).foregroundStyle(HuntReference.muted)
        }
    }
    private var controls: some View {
        VStack(spacing: 10) {
            TextField("HTTPS-адрес каталога", text: $catalogAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.URL).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("protomaps_catalog_address")
            HuntAction(title: "Проверить хостинг и каталог", symbol: "link") {
                protomaps.setCatalogAddress(catalogAddress)
                start { await protomaps.refresh() }
            }.disabled(locked || catalogAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text(protomaps.diagnostic).font(.caption).foregroundStyle(HuntReference.muted)
            HuntSearchField(text: $query, placeholder: "Поиск пакетов")
            HStack(spacing: 8) {
                ForEach(Filter.allCases, id: \.self) { item in
                    Button { filter = item } label: {
                        Text(item.rawValue).font(.caption.bold()).frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(filter == item ? Color.black : HuntReference.green)
                            .background(filter == item ? HuntReference.green : HuntReference.card, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                HuntAction(title: "Обновить каталог", symbol: "arrow.clockwise") {
                    start { await hosting.refresh(); if !Task.isCancelled { await protomaps.refresh() } }
                }.disabled(locked)
            }
            if startupBusy {
                Text("Синхронизация выполняется в фоне.").font(.caption).foregroundStyle(.orange)
                HuntAction(title: "Остановить синхронизацию", symbol: "stop.circle") { onCancelStartup() }
            }
        }
    }
    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hosting.busy {
                Text(hosting.activePack.isEmpty ? "Каталог карт" : hosting.activePack).font(.caption.bold())
                ProgressView(value: hosting.progress).tint(HuntReference.green)
                Text("Прогресс сборки проверенных частей пакета").font(.caption2)
            }
            if protomaps.busy {
                Text(protomaps.status).font(.caption)
                ProgressView(value: protomaps.progress).tint(HuntReference.green)
                Text("Прогресс проверки файла, не сетевой счётчик").font(.caption2)
            }
            if job != nil {
                HuntAction(title: "Прервать операцию", symbol: "stop.circle") { job?.cancel() }
            }
        }.huntSurface()
    }
    private var vectorSection: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            Text("Векторные карты · PMTiles").font(.headline)
            let availableIDs = Set(protomaps.available.map(\.id))
            let installedByID = Dictionary(protomaps.installed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let items = protomaps.available + protomaps.installed.filter { !availableIDs.contains($0.id) }
            ForEach(items.filter { matches($0.name, installed: installedByID[$0.id] != nil) }) { item in
                let existing = installedByID[item.id]
                let current = existing?.sha256.lowercased() == item.sha256.lowercased()
                if matches(item.name, installed: existing != nil) {
                    VStack(alignment: .leading, spacing: 8) {
                        packageTitle(item.name, detail: size(item.bytes) + " · zoom \(item.minzoom)–\(item.maxzoom)", state: current ? "Установлено" : existing == nil ? "Доступно" : "Есть обновление")
                        if !current && availableIDs.contains(item.id) {
                            HuntAction(title: existing == nil ? "Скачать" : "Обновить", symbol: "arrow.down.circle") {
                                start { await protomaps.downloadPack(id: item.id) }
                            }.disabled(locked)
                        }
                        if let existing {
                            Button("Удалить пакет", role: .destructive) { deletePack = existing }
                                .font(.caption).disabled(locked)
                        }
                    }.huntSurface()
                }
            }
            Text(protomaps.status).font(.caption).foregroundStyle(HuntReference.muted)
        }
    }
    private var rasterSection: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            Text("Растровые карты · MBTiles").font(.headline)
            let hashes = Set(tiles.installed.map { $0.sha256.lowercased() })
            ForEach(hosting.maps.filter { matches($0.name, installed: hashes.contains($0.sha256.lowercased())) }) { item in
                let installed = hashes.contains(item.sha256.lowercased())
                if matches(item.name, installed: installed) {
                    VStack(alignment: .leading, spacing: 8) {
                        packageTitle(item.name, detail: size(item.bytes), state: installed ? "Установлено" : "Доступно")
                        if !installed {
                            HuntAction(title: "Скачать", symbol: "arrow.down.circle") {
                                start { await hosting.installMap(item, tiles: tiles) }
                            }.disabled(locked)
                        }
                    }.huntSurface()
                }
            }
            Text(hosting.status).font(.caption).foregroundStyle(HuntReference.muted)
        }
    }
    private var roadsSection: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            Text("Дорожные сети").font(.headline)
            ForEach(hosting.routes.filter { matches($0.name, installed: hosting.installedRoutes.contains($0.id)) }) { item in
                let installed = hosting.installedRoutes.contains(item.id)
                if matches(item.name, installed: installed) {
                    VStack(alignment: .leading, spacing: 8) {
                        packageTitle(item.name, detail: size(item.bytes), state: installed ? "Установлено · по ID" : "Доступно")
                        HuntAction(title: installed ? "Проверить и обновить" : "Скачать", symbol: "arrow.down.circle") {
                            start { await hosting.installRoute(item) }
                        }.disabled(locked)
                    }.huntSurface()
                }
            }
        }
    }
    private var navigationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Valhalla").font(.headline)
            Text(valhalla.tilesInstalled ? "Пакет установлен" : "Пакет не установлен").font(.subheadline.bold())
            Text(valhalla.status).font(.caption).foregroundStyle(HuntReference.muted)
            HuntAction(title: "Проверить офлайн-навигацию", symbol: "arrow.clockwise") {
                start { await valhalla.downloadFromHosting() }
            }.disabled(locked)
            Text("Рельеф DEM: отдельный каталог пока не подключён.").font(.caption).foregroundStyle(HuntReference.muted)
        }.huntSurface()
    }
    private func packageTitle(_ name: String, detail: String, state: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.subheadline.bold()).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.caption).foregroundStyle(HuntReference.muted)
            Text(state).font(.caption.bold()).foregroundStyle(HuntReference.green)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
