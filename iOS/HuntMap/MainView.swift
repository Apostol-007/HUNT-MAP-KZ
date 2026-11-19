import SwiftUI
import HuntCore
import UniformTypeIdentifiers

private func paceText(_ secondsPerKm: Double) -> String {
    guard secondsPerKm.isFinite, secondsPerKm >= 0 else { return "—" }
    let total = Int(min(secondsPerKm.rounded(), 359999))
    return String(format: "%d:%02d мин/км", total / 60, total % 60)
}

struct MainView: View {
    @EnvironmentObject var model:FieldModel
    @StateObject private var tileStore = OfflineTileStore()
    @StateObject private var nativeOSM = NativeOfflineOSM()
    @AppStorage("hunt.showDownloadGrid") private var showDownloadGrid = true
    @State private var osmRegionName = ""
    @State private var osmRadius = 1500
    @StateObject private var wildlifeStore = WildlifeStore()
    @StateObject private var wildlifeUpdater = WildlifeUpdater()
    @StateObject private var boundaryDownloader = BoundaryDownloader()
    @State private var boundaryGroundID = ""
    @State private var directGeoJSONURL = ""
    @State private var wildlifeServer = "https://example.org"
    @State private var wildlifeGround = ""
    @State private var wildlifeImportShown = false
    @State private var wildlifeSearch = ""
    // Independent HTTPS catalogs operated by the user or a licensed map provider.
    // No public OSM/Google/Yandex tile endpoint is used as a bulk downloader.
    @AppStorage("hunt.catalog.primary") private var primaryCatalog = ""
    @AppStorage("hunt.catalog.secondary") private var secondaryCatalog = ""
    @AppStorage("hunt.catalog.tertiary") private var tertiaryCatalog = ""
    @AppStorage("hunt.catalog.selected") private var selectedCatalog = 0
    @State private var catalogError: String?
    @State private var showAdvancedDownloads = false
    @State private var selectedScope = "ground"
    @State private var scopeID = ""
    @State private var directMBTilesURL = ""
    @State private var tileImportShown=false
    @State private var importShown=false
    @State private var importError:String?
    @State private var showDiagnostics = false
    @State private var showAbout = false
    @State private var editingMarker: Marker?
    @State private var selectedZone: GeoZone?
    @State private var tappedMapPoint: GeoPoint?
    @State private var showMapDownload = false
    @State private var publicTaxa: [GBIFTaxon] = []
    @State private var gbifStatus = "Не загружено"
    @State private var loadingGBIF = false
    @AppStorage("hunt.onlineBasemap") private var onlineBasemap = true
    @AppStorage("hunt.mapStyle") private var mapStyle = "liberty"
    @State private var showMapSources = false
    @State private var showLayers = false
    @State private var showGrounds = true
    @State private var showMarkers = true
    @State private var showTrack = true
    @State private var showGPS = true
    @State private var selectedRoute: Track?
    @State private var centerRequest = 0
    @State private var selectedTab: HuntTab = .map
    // The map is the background of the entire window, NOT a child of TabView.
    // TabView's safe-area and intrinsic sizing previously letterboxed the map.
    private enum HuntTab: String, CaseIterable {
        case map = "Карта", tracks = "Маршруты", markers = "Маркеры"
        case wildlife = "Животные", downloads = "Загрузки"

        var symbol: String {
            switch self {
            case .map: "map.fill"
            case .tracks: "figure.hiking"
            case .markers: "mappin.and.ellipse"
            case .wildlife: "pawprint.fill"
            case .downloads: "arrow.down.circle.fill"
            }
        }
    }

    var body: some View {
        ZStack {
            Group {
                switch selectedTab {
                case .map: mapTab
                case .tracks: tracksTab
                case .markers: markersTab
                case .wildlife: wildlifeTab
                case .downloads: downloadsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Overlay: does not alter the map's available height.
        .overlay(alignment: .bottom) { floatingNavigation }
        .background(Color.black.ignoresSafeArea())
        .background(ShakeDetector().frame(width: 1, height: 1))
        .onReceive(NotificationCenter.default.publisher(for: .huntShake)) { _ in showDiagnostics = true }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView(model: model, mapCount: tileStore.installed.count, wildlifeCount: wildlifeStore.packs.count, onlineMap: onlineBasemap) }
        .sheet(isPresented: $showAbout) { AboutHuntView() }
    }

    private var floatingNavigation: some View {
        HStack(spacing: 0) {
            ForEach(HuntTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol).font(.system(size: 19, weight: .semibold))
                        Text(tab.rawValue).font(.system(size: 9, weight: .medium))
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(selectedTab == tab ? .orange : .white)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue)
            }
        }
        .padding(.horizontal, 5)
        .background(.black.opacity(0.70), in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 10)
        .padding(.bottom, 0)
    }

    // All controls are laid out in the SAFE AREA. Only the underlying MapLibre
    // canvas extends under the status bar and home indicator.
    private var mapTab: some View {
        GeometryReader { geometry in
            ZStack {
                mapCanvas
                    .ignoresSafeArea(.container, edges: .all)

                mapControls
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .sheet(isPresented: $showLayers) {
            MapLayersSheet(
                mapStyle: $mapStyle, online: $onlineBasemap,
                grounds: $showGrounds, markers: $showMarkers,
                track: $showTrack, gps: $showGPS, grid: $showDownloadGrid,
                onDownload: { showMapDownload = true },
                onLibrary: { selectedTab = .downloads }
            )
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showMapSources) {
            MapLayersSheet(
                mapStyle: $mapStyle, online: $onlineBasemap,
                grounds: $showGrounds, markers: $showMarkers,
                track: $showTrack, gps: $showGPS, grid: $showDownloadGrid,
                onDownload: { showMapDownload = true },
                onLibrary: { selectedTab = .downloads }
            )
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showMapDownload) {
            QuickMapDownloadSheet(
                point: tappedMapPoint ?? model.coordinate,
                osm: nativeOSM, tiles: tileStore,
                onOpenLibrary: { selectedTab = .downloads }
            )
            .presentationDetents([.large])
        }
        .sheet(item: $editingMarker) { marker in
            MarkerEditor(marker: marker, onSave: { model.saveMarker($0) }, onDelete: { model.deleteMarker(id: $0) })
        }
        .sheet(item: $selectedZone) { zone in
            GroundDetailsSheet(zone: zone)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }


    // Break up the large SwiftUI result-builder expression. Xcode 16.4
    // otherwise times out type-checking mapTab (GitHub Actions log, line 126).
    private var mapDownloadSheet: some View {
            NavigationStack {
                Form {
                    Section("Выбранная точка") {
                        if let point = tappedMapPoint {
                            Text(String(format: "%.5f, %.5f", point.latitude, point.longitude))
                        } else { Text("Текущая область карты") }
                    }
                    Section("Метка без GPS") {
                        if let point = tappedMapPoint {
                            Button("Сохранить здесь машину") {
                                model.addMarker(kind: "Машина", at: point)
                                showMapDownload = false
                            }
                            Button("Сохранить здесь метку") {
                                model.addMarker(kind: "Точка", at: point)
                                showMapDownload = false
                            }
                        }
                    }
                    offlineMapDownloadSection
                }
                .navigationTitle("Скачать карту")
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("Закрыть") { showMapDownload = false }
                }}
            }
    }

    // Isolated ViewBuilder: avoids an ambiguous nested Section expression in Xcode 16.4.
    private var offlineMapDownloadSection: some View {
        Section(header: Text("Офлайн-карта")) {
            Text("Для загрузки нужен опубликованный MBTiles-пакет. Выберите пакет в разделе загрузок или импортируйте MBTiles с устройства.")
            if let point = tappedMapPoint {
                let hasCoverage = !tileStore.covering(latitude: point.latitude, longitude: point.longitude).isEmpty
                Text(tileStore.coveringDescription(latitude: point.latitude, longitude: point.longitude))
                    .foregroundStyle(hasCoverage ? Color.green : Color.orange)
            }
            Text(tileStore.installed.isEmpty ? "На устройстве нет офлайн-карт" : "Установлено пакетов: \(tileStore.installed.count)")
            if tileStore.serviceURL.isEmpty {
                Text("Активный сервер не выбран. Поиск по точке проверит все настроенные каталоги.")
                    .foregroundStyle(Color.orange)
            }
            if let point = tappedMapPoint {
                Button("Найти офлайн-карты для этой точки") {
                    Task {
                        await tileStore.fetchAtPointFromCatalogs(latitude: point.latitude, longitude: point.longitude, catalogs: [primaryCatalog, secondaryCatalog, tertiaryCatalog])
                    }
                }
                .disabled(tileStore.busy || [primaryCatalog, secondaryCatalog, tertiaryCatalog].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                ForEach(tileStore.available) { pack in
                    offlinePackRow(pack)
                }
                Text(tileStore.message).font(.caption).foregroundStyle(Color.secondary)
            }
            Button("Импортировать MBTiles для этого участка") {
                showMapDownload = false
                selectedTab = .downloads
                tileImportShown = true
            }
            Button("Открыть загрузки и импорт") {
                showMapDownload = false
                selectedTab = .downloads
            }
        }
    }

    private func offlinePackRow(_ pack: PublishedPack) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pack.pack_id).font(.headline)
            Text("\(ByteCountFormatter.string(fromByteCount: pack.size_bytes, countStyle: .file)) · \(pack.license)")
                .font(.caption).foregroundStyle(Color.secondary)
            if let source = pack.catalog_url {
                Text(source).font(.caption2).foregroundStyle(Color.secondary)
            }
            Button("Скачать / продолжить") {
                Task { await tileStore.install(pack) }
            }
            .disabled(tileStore.busy)
        }
    }

    private var mapCanvas: some View {
        OfflineMapView(
            zones: showGrounds ? model.zones : [], position: showGPS ? model.coordinate : nil,
            travelHeading: model.travelHeading,
            markers: showMarkers ? model.markers : [],
            track: showTrack ? (selectedRoute ?? model.currentTrack) : nil,
            centerRequest: centerRequest, mapStyle: mapStyle, tileFiles: tileStore.paths,
            tileRevision: tileStore.revision, offlineOSMLines: nativeOSM.lines,
            offlineOSMRevision: nativeOSM.revision, downloadGridVisible: showDownloadGrid,
            downloadedRegions: nativeOSM.regions, online: onlineBasemap,
            onMarkerSelect: { id in editingMarker = model.markers.first { $0.id == id } },
            onMarkerMove: { id, point in model.moveMarker(id: id, to: point) },
            selectedZone: $selectedZone, onMapTap: { point in
                tappedMapPoint = point
                showMapDownload = true
            }
        )
    }

    private var mapControls: some View {
        VStack(spacing: 0) {
            headerControls
            mapSideControls
            Spacer(minLength: 0)
            mapStatusFooter
        }
    }

    private var mapSideControls: some View {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 9) {
                    sideControl("magnifyingglass", "Поиск") { selectedTab = .downloads }
                    sideControl("figure.hiking", "Маршруты") { selectedTab = .tracks }
                    sideControl("square.3.layers.3d", "Слои") { showLayers = true }
                    sideControl(showDownloadGrid ? "square.grid.3x3.fill" : "square.grid.3x3", "Сетка") { showDownloadGrid.toggle() }
                    sideControl("pawprint.fill", "Животные") { selectedTab = .wildlife }
                    sideControl("arrow.down.circle.fill", "Скачать") { showMapDownload = true }
                }
                Spacer(minLength: 0)
                VStack(spacing: 9) {
                    sideControl("location.north.fill", "GPS") { model.requestGPS() }
                    sideControl("scope", "Центр") { centerRequest += 1 }
                    sideControl("car.fill", "Машина") { model.addMarker(kind: "Машина") }
                    sideControl(model.recording ? "stop.circle.fill" : "record.circle", model.recording ? "Стоп" : "Трек") {
                        if model.recording { model.stopTrack() } else { model.startTrack() }
                    }
                    sideControl("mappin.and.ellipse", "Метка") { model.addMarker() }
                    sideControl("square.dashed", "Границы") { selectedTab = .downloads }
                    sideControl("ladybug", "Диагн.") { showDiagnostics = true }
                }
            }
            .padding(.top, 12)
    }

    private var mapStatusFooter: some View {
        VStack(spacing: 0) {
            if model.recording, let active = model.currentTrack {
                HStack(spacing: 12) {
                    Image(systemName: model.paused ? "pause.circle.fill" : "record.circle.fill")
                        .foregroundStyle(model.paused ? .yellow : .red)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(active.name).font(.caption.bold()).lineLimit(1)
                        Text(String(format: "%.2f км · %d точек", active.distanceMeters / 1000, active.fixes.count))
                            .font(.caption2)
                        HStack(spacing: 8) {
                            Text("Скорость: " + (model.currentSpeedKmh.map { String(format: "%.1f км/ч", $0) } ?? "—"))
                            Text("Темп: " + (model.averagePaceSecondsPerKm.map { paceText($0) } ?? "—"))
                        }.font(.caption2)
                    }
                    Spacer(minLength: 0)
                    Button(model.paused ? "Продолжить" : "Пауза") { model.togglePause() }
                        .font(.caption.bold())
                    Button("Стоп") { model.stopTrack() }.font(.caption.bold())
                }
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 6)
            }
            if let route = selectedRoute {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Возврат: \(route.name)").font(.caption.bold())
                        Text(returnGuidance(for: route)).font(.caption2)
                    }
                    Spacer(minLength: 4)
                    Button("Завершить") { selectedRoute = nil }
                        .font(.caption.bold())
                }
                .foregroundStyle(.white).padding(10)
                .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 6)
            }
            if !model.lastWarning.isEmpty && model.lastWarning != "Границы не загружены" {
                Text(model.lastWarning).font(.caption.bold())
                    .foregroundStyle(.white).padding(8)
                    .background(.orange.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.bottom, 8)
            }
            if tileStore.installed.isEmpty {
                Button { showMapDownload = true } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "arrow.down.to.line.compact").font(.title3)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Карта не загружена").font(.system(size: 13, weight: .bold))
                            Text("Нажмите для загрузки офлайн-карты")
                                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.8))
                        }
                        Spacer(minLength: 3)
                        Text("Скачать").font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(.orange, in: RoundedRectangle(cornerRadius: 11))
                    }
                    .foregroundStyle(.white).padding(10)
                    .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                // Reserve the complete dock height; never draw behind navigation.
                .padding(.bottom, 69)
            } else {
                Color.clear.frame(height: 69)
            }
        }
    }

    private func openExternalMap(_ provider: String) {
        let latitude = tappedMapPoint?.latitude ?? model.coordinate?.latitude ?? 43.24
        let longitude = tappedMapPoint?.longitude ?? model.coordinate?.longitude ?? 76.91
        let urlString = provider == "google"
            ? "https://www.google.com/maps/search/?api=1&query=\(latitude),\(longitude)"
            : "https://yandex.kz/maps/?ll=\(longitude)%2C\(latitude)&z=13"
        if let url = URL(string: urlString) { UIApplication.shared.open(url) }
    }

    private var headerControls: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { showAbout = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "map.fill").foregroundStyle(.orange)
                    Text("HUNT MAP").foregroundStyle(.white)
                    Text("KZ").foregroundStyle(.orange)
                }
                .font(.system(size: 13, weight: .heavy))
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, 11).frame(height: 39)
                .background(.black.opacity(0.88), in: Capsule())
            }.buttonStyle(.plain)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Circle().fill(model.coordinate == nil ? .orange : .green).frame(width: 6, height: 6)
                Text("GPS")
            }
            .padding(.horizontal, 9).frame(height: 35)
            .background(.black.opacity(0.88), in: Capsule())
            HStack(spacing: 4) {
                Circle().fill(onlineBasemap ? .green : .orange).frame(width: 6, height: 6)
                Text(onlineBasemap ? "Online" : "Offline")
            }
            .padding(.horizontal, 9).frame(height: 35)
            .background(.black.opacity(0.88), in: Capsule())
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.white)
    }

    private func sideControl(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
                Text(title).font(.system(size: 9, weight: .medium)).lineLimit(1)
            }
            .frame(width: 59, height: 54)
            .foregroundStyle(.white)
            .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).accessibilityLabel(title)
    }

    private func fieldControl(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity).frame(minHeight: 44)
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .accessibilityLabel(title)
    }

    // Trackback projects the live position onto recorded SEGMENTS rather than
    // picking the nearest sampled fix (which can be hundreds of meters apart).
    // The projection is local/equirectangular; distances remain geodesic.
    private func returnGuidance(for route: Track) -> String {
        guard let current = model.coordinate else { return "Нет GPS: записанный маршрут доступен для просмотра" }
        let fixes = route.fixes
        guard let start = fixes.first?.point else { return "Маршрут не содержит точек" }
        if GeoMath.meters(current, start) <= 20 {
            return "Вы вернулись к началу маршрута (до 20 м)"
        }
        guard fixes.count >= 2 else { return "До начала: \(Int(GeoMath.meters(current, start))) м" }

        // Precompute recorded distance along the polyline.
        var cumulative = Array(repeating: 0.0, count: fixes.count)
        for i in 1..<fixes.count {
            cumulative[i] = cumulative[i - 1] + GeoMath.meters(fixes[i - 1].point, fixes[i].point)
        }
        var bestDistance = Double.infinity
        var bestIndex = 1
        var bestFraction = 0.0
        for i in 1..<fixes.count {
            let a = fixes[i - 1].point
            let b = fixes[i].point
            let latScale = 111_195.0
            let lonScale = latScale * cos(current.latitude * .pi / 180)
            let ax = (a.longitude - current.longitude) * lonScale
            let ay = (a.latitude - current.latitude) * latScale
            let bx = (b.longitude - current.longitude) * lonScale
            let by = (b.latitude - current.latitude) * latScale
            let dx = bx - ax, dy = by - ay
            let lengthSquared = dx * dx + dy * dy
            let fraction = lengthSquared > 0 ? max(0, min(1, -(ax * dx + ay * dy) / lengthSquared)) : 0
            let distance = hypot(ax + fraction * dx, ay + fraction * dy)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = i
                bestFraction = fraction
            }
        }
        let a = fixes[bestIndex - 1].point
        let b = fixes[bestIndex].point
        let segmentLength = GeoMath.meters(a, b)
        let remaining = cumulative[bestIndex - 1] + bestFraction * segmentLength
        if bestDistance > 100 {
            return "Вы вне трека на \(Int(bestDistance)) м · до старта по треку \(Int(remaining)) м"
        }
        // Follow the polyline BACKWARDS: from the projection to the previous fix.
        let waypoint = a
        let bearing = bearingDegrees(from: current, to: waypoint)
        let direction: String
        if let heading = model.travelHeading {
            let delta = (bearing - heading + 540).truncatingRemainder(dividingBy: 360) - 180
            if abs(delta) < 25 { direction = "Прямо" }
            else if abs(delta) > 155 { direction = "Развернитесь" }
            else { direction = delta > 0 ? "Правее" : "Левее" }
        } else {
            direction = "Азимут \(Int(bearing.rounded()))°"
        }
        return "\(direction) · до точки \(Int(GeoMath.meters(current, waypoint))) м · до старта \(Int(remaining)) м"
    }

    private func bearingDegrees(from a: GeoPoint, to b: GeoPoint) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let deltaLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private var tracksTab:some View {
        NavigationStack {
            List {
                if let current=model.currentTrack {Section("Активный маршрут") {trackRow(current);Button(model.paused ? "Продолжить":"Пауза") {model.togglePause()}}}
                Section("История · выбрать маршрут на карте") {
                    ForEach(model.tracks) { track in
                        VStack(alignment: .leading, spacing: 6) {
                            trackRow(track)
                            Button("Вернуться по маршруту") {
                                selectedRoute = track
                                centerRequest += 1
                                showTrack = true
                                selectedTab = .map
                            }
                            .font(.caption.bold())
                        }
                    }
                }
            }.overlay {if model.tracks.isEmpty && model.currentTrack == nil {ContentUnavailableView("Маршрутов пока нет",systemImage:"figure.hiking",description:Text("Начните запись на вкладке Карта"))}}.navigationTitle("Маршруты")
        }
    }
    private func trackRow(_ track:Track)->some View {
        HStack {VStack(alignment:.leading){Text(track.name);Text("\(track.fixes.count) точек · \(Int(track.distanceMeters)) м").font(.caption).foregroundStyle(.secondary)};Spacer();if let url=model.exportGPX(track) {ShareLink(item:url){Image(systemName:"square.and.arrow.up")}}}
    }
    private var markersTab: some View {
        NavigationStack {
            List {
                ForEach(model.markers) { marker in
                    Button { editingMarker = marker } label: {
                        HStack(spacing: 12) {
                            Image(systemName: marker.symbol ?? MarkerStyle.defaultSymbol(for: marker.kind))
                                .font(.title2).foregroundStyle(Color(hex: marker.colorHex ?? "#FF9F0A"))
                                .frame(width: 38)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(marker.title).foregroundStyle(.primary)
                                Text(String(format: "%.5f, %.5f", marker.coordinate.latitude, marker.coordinate.longitude))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "pencil.circle").foregroundStyle(.secondary)
                            ShareLink(item: "geo:\(marker.coordinate.latitude),\(marker.coordinate.longitude)") {
                                Image(systemName: "square.and.arrow.up")
                            }.buttonStyle(.borderless)
                        }
                    }
                }.onDelete(perform: model.removeMarkers)
            }
            .navigationTitle("Мои метки")
            .toolbar {
                Button("Добавить", systemImage: "plus") {
                    let point = tappedMapPoint ?? model.coordinate ?? GeoPoint(43.24, 76.91)
                    editingMarker = Marker(title: "Новая метка", kind: "Точка", coordinate: point)
                }
            }
            .overlay {
                if model.markers.isEmpty {
                    ContentUnavailableView("Нет меток", systemImage: "mappin", description: Text("Нажмите +, чтобы создать метку"))
                }
            }
        }
    }
    private var wildlifeTab:some View {
        NavigationStack {
            List {
                Section {
                    Text("Данные о животных не означают разрешение на охоту. Источники импортированных пакетов не проверяются приложением автоматически.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Получить виды из GBIF · Казахстан", systemImage: "globe.asia.australia") {
                        Task {
                            loadingGBIF = true
                            defer { loadingGBIF = false }
                            do {
                                publicTaxa = try await GBIFDiscovery.fetchKazakhstan()
                                gbifStatus = "Получено названий: \(publicTaxa.count). Это наблюдения, а не список видов угодья"
                            } catch { gbifStatus = "Ошибка GBIF: \(error.localizedDescription)" }
                        }
                    }.disabled(loadingGBIF)
                    Text(gbifStatus).font(.caption).foregroundStyle(.secondary)
                    ForEach(publicTaxa) { taxon in
                        Text(taxon.name).font(.subheadline)
                    }
                    Button("Импортировать каталог JSON", systemImage: "square.and.arrow.down") {
                        wildlifeImportShown = true
                    }
                    Text(wildlifeStore.message).font(.caption).foregroundStyle(.secondary)
                    TextField("HTTPS-адрес сервера", text: $wildlifeServer)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("ID угодья из проверенного источника", text: $wildlifeGround)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Проверить обновления", systemImage: "arrow.clockwise") {
                        Task { await wildlifeUpdater.check(server: wildlifeServer, groundID: wildlifeGround) }
                    }.disabled(wildlifeUpdater.busy)
                    Text(wildlifeUpdater.status).font(.caption).foregroundStyle(.secondary)
                    ForEach(wildlifeUpdater.candidates) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Версия: \(item.pack_id)").font(.subheadline)
                                Text("\(item.taxa_count) видов · \(item.generated_at)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Скачать") {
                                Task { await wildlifeUpdater.install(item, server: wildlifeServer, store: wildlifeStore) }
                            }.disabled(wildlifeUpdater.busy)
                        }
                    }
                }
                ForEach(Array(wildlifeStore.packs.enumerated()), id: \.offset) { index, pack in
                    Section {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Территория: \(pack.ground_id)").font(.headline)
                                Text("Источник: \(pack.source) · \(pack.license)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("Дата набора: \(pack.generated_at)").font(.caption2)
                            }
                            Spacer()
                            Button(role: .destructive) { wildlifeStore.remove(at: index) } label: {
                                Image(systemName: "trash")
                            }
                        }
                    } header: { Text("Каталог \(index + 1)") }
                    Section("Виды · \(pack.taxa.count)") {
                        ForEach(pack.taxa.filter { wildlifeSearch.isEmpty ||
                            $0.scientific_name.localizedCaseInsensitiveContains(wildlifeSearch) ||
                            ($0.name_ru?.localizedCaseInsensitiveContains(wildlifeSearch) ?? false) ||
                            ($0.name_kk?.localizedCaseInsensitiveContains(wildlifeSearch) ?? false)
                        }) { taxon in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(taxon.name_ru ?? taxon.name_kk ?? taxon.scientific_name).font(.headline)
                                Text(taxon.scientific_name).italic().font(.caption)
                                Text("Статус: \(wildlifeLabel(taxon.category)) · свидетельств: \(taxon.evidence_count)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let date = taxon.latest_evidence_at { Text("Последнее свидетельство: \(date)").font(.caption2) }
                                if let source = taxon.source_record_url, let url = URL(string: source) {
                                    Link("Исходная запись", destination: url).font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $wildlifeSearch, prompt: "Русское, казахское или научное название")
            .navigationTitle("Животные")
            .fileImporter(isPresented: $wildlifeImportShown, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url): wildlifeStore.importFile(url)
                case .failure(let error): wildlifeStore.message = error.localizedDescription
                }
            }
        }
    }
    private func wildlifeLabel(_ category: String) -> String {
        switch category {
        case "confirmed": "подтверждено источником"
        case "probable": "вероятно"
        case "historical": "историческое"
        default: "нет данных"
        }
    }
    // Isolate SwiftUI result-builder type checking.
    private var downloadsBlock1: some View {
                Section("Картографическая подложка") {
                    Button("Выбрать источник карты") { showMapSources = true }
                    Toggle("Онлайн-карта OpenFreeMap", isOn: $onlineBasemap)
                    Text("Онлайн-режим показывает дороги, тропы и объекты при наличии интернета. Отключите его для строгого офлайна. Онлайн-тайлы не скачиваются массово для офлайн-использования.")
                        .font(.caption).foregroundStyle(.secondary)
                }
    }

    // Isolate SwiftUI result-builder type checking.
    private var downloadsBlock2: some View {
                Section("Офлайн-районы OpenStreetMap") {
                    Button("Быстрая загрузка района на карте", systemImage: "arrow.down.circle.fill") {
                        showMapDownload = true
                    }
                    Text("Выберите точку на карте или используйте GPS. Скачанные дороги, тропы и водотоки остаются на iPhone без интернета.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Название района (необязательно)", text: $osmRegionName)
                    Picker("Радиус", selection: $osmRadius) {
                        Text("500 м").tag(500)
                        Text("1 км").tag(1000)
                        Text("1,5 км").tag(1500)
                        Text("2,5 км").tag(2500)
                    }
                    Button("Скачать выбранный район", systemImage: "arrow.down.circle") {
                        if let point = tappedMapPoint ?? model.coordinate {
                            let name = osmRegionName
                            let radius = osmRadius
                            Task { await nativeOSM.download(around: point, radiusMeters: radius, title: name) }
                        }
                    }
                    .disabled(nativeOSM.busy || (tappedMapPoint == nil && model.coordinate == nil))
                    if nativeOSM.busy { ProgressView("Получение объектов OSM…") }
                    Text(nativeOSM.status).font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Объектов на устройстве", value: String(nativeOSM.lines.count))
                    if !nativeOSM.regions.isEmpty {
                        ForEach(nativeOSM.regions) { region in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(region.title).font(.subheadline)
                                    Text("\(region.radiusMeters) м · \(region.featureCount) объектов · \(region.downloadedAt.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) { nativeOSM.remove(region) } label: {
                                    Image(systemName: "trash")
                                }.buttonStyle(.borderless).disabled(nativeOSM.busy)
                            }
                        }
                    }
                    if !nativeOSM.lines.isEmpty {
                        Button("Удалить все локальные дороги и тропы", role: .destructive) { nativeOSM.clear() }
                            .disabled(nativeOSM.busy)
                    }
                    Text("Источник: Overpass API / © OpenStreetMap contributors, ODbL. Это локальный слой объектов, не спутниковая или полноценная растровая карта. Для скачивания нужен интернет. Публичный API ограничивает объём запросов.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
    }

    // Isolate SwiftUI result-builder type checking.
    private var downloadsBlock3: some View {
        Section("Каталог поставщиков исходных данных") {
            Text("Выберите источник. Для небольших районов дороги и тропы скачиваются прямо в приложении кнопкой выше. Остальные сайты предоставляют исходные данные или файлы, которые могут потребовать обработки.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Geofabrik · Казахстан (OSM PBF)", destination: URL(string: "https://download.geofabrik.de/asia/kazakhstan.html")!)
            Link("BBBike · выбрать район (OSM / MBTiles)", destination: URL(string: "https://extract.bbbike.org/?lang=ru")!)
            Link("Protomaps · карты PMTiles", destination: URL(string: "https://protomaps.com/")!)
            Link("OpenMapTiles · векторные карты", destination: URL(string: "https://openmaptiles.org/")!)
            Link("OpenStreetMap · исходные данные", destination: URL(string: "https://www.openstreetmap.org/export")!)
            Link("OpenTopoMap · топографическая карта", destination: URL(string: "https://opentopomap.org/")!)
            Link("Copernicus · снимки Sentinel", destination: URL(string: "https://dataspace.copernicus.eu/")!)
            Link("USGS EarthExplorer · рельеф и снимки", destination: URL(string: "https://earthexplorer.usgs.gov/")!)
            Text("Важно: OpenTopoMap и публичные тайловые серверы OSM не предназначены для массового скачивания тайлов. PMTiles, PBF и векторные MBTiles пока не устанавливаются растровым загрузчиком.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // Isolate SwiftUI result-builder type checking.
    private var downloadsBlock4: some View {
                Section("Карты с вашего сервера") {
                    Text("Найдите готовые MBTiles по координатам на карте. Сервер автоматически отдаёт список, а приложение проверяет SHA-256 перед установкой.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Найти карты для выбранной точки", systemImage: "location.magnifyingglass") {
                        if let point = tappedMapPoint {
                            Task { await tileStore.fetchAtPointFromCatalogs(latitude: point.latitude, longitude: point.longitude, catalogs: [primaryCatalog, secondaryCatalog, tertiaryCatalog]) }
                        }
                    }
                    .disabled(tappedMapPoint == nil || tileStore.busy || [primaryCatalog, secondaryCatalog, tertiaryCatalog].allSatisfy { $0.isEmpty })
                    ForEach(tileStore.available) { pack in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pack.pack_id).font(.headline)
                            Text(ByteCountFormatter.string(fromByteCount: pack.size_bytes, countStyle: .file)).font(.caption)
                            Button("Установить карту") { Task { await tileStore.install(pack) } }.disabled(tileStore.busy)
                        }
                    }
                    Text("Нужен ваш HTTPS-сервер с опубликованными пакетами. Geofabrik и BBBike предоставляют исходные данные, а не этот API.")
                        .font(.caption).foregroundStyle(.secondary)
                }
    }

    // Isolate SwiftUI result-builder type checking.
    private var downloadsBlock5: some View {
                DisclosureGroup("Дополнительные настройки и источники", isExpanded: $showAdvancedDownloads) {
                Section("О приложении и диагностика") {
                    Button("О приложении") { showAbout = true }
                    Button("Диагностика / сохранить / отправить в ChatGPT") { showDiagnostics = true }
                    Button("Запросить фоновое разрешение GPS") { model.requestBackgroundGPS() }
                    Text("Также откройте диагностику, встряхнув iPhone.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Загрузка опубликованных границ") {
                    TextField("ID угодья из каталога вашего сервера", text: $boundaryGroundID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Загрузить GeoJSON с сервера") {
                        Task { await boundaryDownloader.fetch(server: tileStore.serviceURL, groundID: boundaryGroundID, model: model) }
                    }.disabled(boundaryDownloader.busy || boundaryGroundID.isEmpty)
                    Text(boundaryDownloader.message).font(.caption).foregroundStyle(.secondary)
                }
                Section("Загрузить GeoJSON напрямую") {
                    TextField("https://.../grounds.geojson", text: $directGeoJSONURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Загрузить границы из HTTPS GeoJSON", systemImage: "globe") {
                        Task { await boundaryDownloader.fetchGeoJSON(urlString: directGeoJSONURL, model: model) }
                    }.disabled(boundaryDownloader.busy || directGeoJSONURL.isEmpty)
                    Text("Источник должен разрешать загрузку и повторное использование. Поддерживаются FeatureCollection и Feature с Polygon/MultiPolygon. Сохраняются все простые поля properties.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Открытые источники границ") {
                    Link("Государственные геоданные Казахстана (проверяйте права)", destination: URL(string: "https://data.egov.kz/")!)
                    Link("Tabigat: исходные данные и карта", destination: URL(string: "https://tabigat.gov.kz/")!)
                    Text("Автоматическая загрузка официальных границ не включена: требуется подтверждённый машиночитаемый адрес и разрешение. GeoJSON импортируется отдельно.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Источники офлайн-карт") {
                    Picker("Активный каталог", selection: $selectedCatalog) {
                        Text("Источник 1").tag(0)
                        Text("Источник 2").tag(1)
                        Text("Источник 3").tag(2)
                    }.pickerStyle(.segmented)
                    switch selectedCatalog {
                    case 0:
                        TextField("https://ваш-сервер-1.kz", text: $primaryCatalog)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    case 1:
                        TextField("https://ваш-сервер-2.kz", text: $secondaryCatalog)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    default:
                        TextField("https://ваш-сервер-3.kz", text: $tertiaryCatalog)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Button("Использовать выбранный источник") {
                        let raw = [primaryCatalog, secondaryCatalog, tertiaryCatalog][selectedCatalog]
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let url = URL(string: raw), url.scheme == "https", url.host != nil,
                              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                            catalogError = "Укажите HTTPS-адрес без логина, пароля и параметров."
                            return
                        }
                        tileStore.serviceURL = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        catalogError = nil
                    }
                    if let catalogError { Text(catalogError).foregroundStyle(.red).font(.caption) }
                    Text("Поиск по точке опрашивает все три каталога. Скачивание выполняется именно с того источника, который опубликовал пакет. Каждый должен поддерживать API /v1/packs/manifest и /v1/packs/{pack_id}, HTTP Range и SHA-256. Адреса сохраняются на устройстве. Переключение источника не удаляет установленные карты.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Google и Яндекс не являются источниками офлайн-MBTiles без отдельного разрешения. Публичные тайловые серверы OSM нельзя использовать для массовой загрузки.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Режим загрузки") {
                    Picker("Масштаб пакета", selection: $selectedScope) {
                        Text("Область").tag("region")
                        Text("Охотугодье").tag("ground")
                        Text("Казахстан").tag("country")
                    }.pickerStyle(.segmented)
                    TextField(selectedScope == "country" ? "KZ" : "ID области / угодья", text: $scopeID)
                        .textInputAutocapitalization(.never)
                    Button("Найти пакеты") {
                        Task { await tileStore.fetch(scope: selectedScope, id: selectedScope == "country" ? "KZ" : scopeID) }
                    }.disabled(tileStore.busy || (selectedScope != "country" && scopeID.isEmpty))
                    ForEach(tileStore.available) { pack in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(pack.pack_id).font(.headline)
                            Text("\(ByteCountFormatter.string(fromByteCount: pack.size_bytes, countStyle: .file)) · \(pack.source_version) · \(pack.license)")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Скачать / продолжить (SHA-256)") { Task { await tileStore.install(pack) } }
                                .disabled(tileStore.busy)
                        }
                    }
                }
                }
    }

    // Direct download of licensed raster MBTiles; no external map-preparation computer required.
    private var directMapDownloadBlock: some View {
        Section("Дополнительно · загрузить свой MBTiles по ссылке") {
            TextField("Прямая HTTPS-ссылка на .mbtiles", text: $directMBTilesURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Скачать и установить карту", systemImage: "arrow.down.circle") {
                Task { await tileStore.importFromHTTPS(directMBTilesURL) }
            }
            .disabled(tileStore.busy || directMBTilesURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("Поддерживаются растровые MBTiles (PNG/JPEG/WebP). Векторные MBTiles и PMTiles не поддерживаются этим загрузчиком. Ссылка должна вести непосредственно на файл, не на страницу сайта.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Для загрузки без вставки ссылок используйте «Офлайн-районы OpenStreetMap» выше. Каталог бесплатных источников со всеми ссылками находится в этом же разделе.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // Isolate SwiftUI result-builder type checking.
    private var downloadsBlock6: some View {
                Section("Импорт без сервера") {
                    Button("Импортировать растровый MBTiles", systemImage: "square.and.arrow.down") { tileImportShown = true }
                    Text("Только ваши файлы, которые законно разрешено копировать. Лицензия и границы автоматически не подтверждаются.").font(.caption).foregroundStyle(.secondary)
                }
    }

    // Isolate SwiftUI result-builder type checking.
    private var downloadsBlock7: some View {
                Section("Установленные карты") {
                    if tileStore.installed.isEmpty { Text("Офлайн-карты пока отсутствуют") }
                    ForEach(tileStore.installed) { pack in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(pack.pack_id)
                                Text("\(pack.license) · \(pack.verified ? "источник проверен" : "источник не подтверждён")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { tileStore.remove(pack) } label: { Image(systemName: "trash") }
                        }
                    }
                }
    }

    // Isolate SwiftUI result-builder type checking.
    private var downloadsBlock8: some View {
                Section("Статус") {
                    if tileStore.busy { ProgressView(value: tileStore.progress) }
                    Text(tileStore.message)
                    LabeledContent("Картографических пакетов", value: String(tileStore.installed.count))
                    LabeledContent("Границ", value: String(model.zones.count))
                    LabeledContent("Каталогов животных", value: String(wildlifeStore.packs.count))
                }
    }

    // Isolate SwiftUI result-builder type checking.
    private var downloadsBlock9: some View {
                Section("Локальный GeoJSON") {Button("Импортировать границы GeoJSON",systemImage:"square.and.arrow.down") {importShown=true};if let importError {Text(importError).foregroundStyle(.red)}}
    }

    // Isolate SwiftUI result-builder type checking.
    private var downloadsBlock10: some View {
                Section("Тестирование") {Button("Показать демо-полигон") {model.loadDemoZones()};Text("Демонстрационный полигон создан искусственно. Он не является охотугодьем.").font(.caption).foregroundStyle(.secondary)}
    }

    // Isolate SwiftUI result-builder type checking.
    private var downloadsBlock11: some View {
                Section("Ограничения") {
                    Text("MapLibre использует локальный стиль без интернет-источников и файлы MBTiles. Отсутствие сетевых запросов необходимо подтвердить сетевым тестом на физическом iPhone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
    }

    private var downloadsTab:some View {
        NavigationStack {
            Form {
                downloadsBlock1
                downloadsBlock2
                downloadsBlock3
                downloadsBlock4
                downloadsBlock5
                directMapDownloadBlock
                downloadsBlock6
                downloadsBlock7
                downloadsBlock8
                downloadsBlock9
                downloadsBlock10
                downloadsBlock11
            }.navigationTitle("Загрузки").fileImporter(isPresented: $tileImportShown, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url): Task { await tileStore.importLocal(url) }
                case .failure(let error): importError = error.localizedDescription
                }
            }.fileImporter(isPresented:$importShown,allowedContentTypes:[.json]) { result in
                do {model.setImportedZones(try GeoJSONImport.load(result.get()));importError=nil} catch {importError=error.localizedDescription}
            }
        }
    }
}

struct OfflineCanvas:View {
    let zones:[GeoZone];let position:GeoPoint?;let markers:[Marker];let track:Track?
    @State private var scale=1.0
    @State private var offset:CGSize = .zero
    var body:some View {
        GeometryReader { geo in
            Canvas {context,size in
                let center=position ?? GeoPoint(43.26,76.90)
                let span=0.12/scale
                func screen(_ p:GeoPoint)->CGPoint {
                    CGPoint(x:size.width/2+(p.longitude-center.longitude)/span*size.width+offset.width,y:size.height/2-(p.latitude-center.latitude)/span*size.height+offset.height)
                }
                for zone in zones {
                    for poly in zone.polygons {
                        for ring in poly.rings {
                            guard let first=ring.first else {continue}
                            var path=Path();path.move(to:screen(first))
                            for p in ring.dropFirst() {path.addLine(to:screen(p))};path.closeSubpath()
                            context.stroke(path,with:.color(zone.verified ? .orange : .yellow),lineWidth:3)
                        }
                    }
                }
                if let track,let first=track.fixes.first {var path=Path();path.move(to:screen(first.point));for fix in track.fixes.dropFirst() {if fix.startsNewSegment == true {path.move(to:screen(fix.point))} else {path.addLine(to:screen(fix.point))}};context.stroke(path,with:.color(.green),lineWidth:3)}
                for m in markers {let p=screen(m.coordinate);context.fill(Path(ellipseIn:CGRect(x:p.x-5,y:p.y-5,width:10,height:10)),with:.color(.orange))}
                if let position {let p=screen(position);context.fill(Path(ellipseIn:CGRect(x:p.x-7,y:p.y-7,width:14,height:14)),with:.color(.blue));context.stroke(Path(ellipseIn:CGRect(x:p.x-8,y:p.y-8,width:16,height:16)),with:.color(.white),lineWidth:2)}
            }
            .overlay(alignment:.topLeading) {VStack(alignment:.leading){Text("СХЕМА · БЕЗ ПОДЛОЖКИ").font(.caption.bold());Text("Не навигационная топокарта").font(.caption2)}.foregroundStyle(.white).padding(10).background(.black.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius:8)).padding(10)}
            .overlay(alignment:.bottomTrailing) {VStack {Button {scale=min(20,scale*1.5)} label:{Image(systemName:"plus")};Button {scale=max(0.5,scale/1.5)} label:{Image(systemName:"minus")}}.buttonStyle(.borderedProminent).padding(12)}
            .gesture(DragGesture().onChanged {offset=$0.translation}.onEnded {_ in offset = .zero})
        }
    }
}


/// All original fields are presented, rather than a hardcoded mock of one hunting ground.
private struct GroundDetailsSheet: View {
    let zone: GeoZone
    @Environment(\.dismiss) private var dismiss
    private var fields: [(key: String, value: String)] {
        (zone.attributes ?? [:]).map { (key: $0.key, value: $0.value) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }
    var body: some View {
        NavigationStack {
            List {
                Section("Общая информация") {
                    LabeledContent("Название", value: zone.name)
                    LabeledContent("Тип", value: zone.kind == .protectedArea ? "Охраняемая территория" : "Охотничье хозяйство")
                    LabeledContent("Достоверность", value: zone.verified ? "Верифицировано" : "Не подтверждено")
                    LabeledContent("Источник", value: zone.source)
                }
                Section("Все атрибуты источника · \(fields.count)") {
                    if fields.isEmpty {
                        Text("В GeoJSON отсутствуют атрибуты хозяйства. Их нельзя восстановить по одной геометрии.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(fields.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(fields[index].key).font(.caption).foregroundStyle(.secondary)
                            Text(fields[index].value.isEmpty ? "Нет данных" : fields[index].value)
                                .font(.body).textSelection(.enabled)
                        }.padding(.vertical, 3)
                    }
                }
                Section {
                    Text("Данные информационные. Актуальность границ, договоров и разрешений необходимо проверить по первоисточнику.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(zone.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { dismiss() } } }
        }
    }
}
