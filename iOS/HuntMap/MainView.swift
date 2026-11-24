import SwiftUI
import UIKit
import HuntCore
import UniformTypeIdentifiers

/// Rebuilt UI: MapLibre remains the root full-screen view. No native TabView,
/// no fixed-height map, no nested NavigationStack around the map.
struct MainView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var model: FieldModel
    @StateObject private var maps = OfflineTileStore()
    @StateObject private var hosting = HostingOfflineDownloads()
    @StateObject private var startupSync = StartupSync()
    @StateObject private var offlineRoads = OfflineRoadOverlayStore()
    @StateObject private var nativePacks = NativeOfflinePackStore()
    @StateObject private var protomaps = ProtomapsOfflineStore()
    @StateObject private var valhalla = ValhallaRoutingStore()
    @State private var importingValhallaTiles = false
    @State private var routeRequestID: UUID?
    @State private var gridMode = false
    @State private var gridStep = 0.1
    @State private var selectedGridCells: Set<String> = []
    @StateObject private var animals = WildlifeStore()
    @StateObject private var connectivity = WeatherConnectivity()
    @StateObject private var weather = WeatherService()
    @StateObject private var weatherGrid = WeatherGridService()

    @AppStorage("hunt.onlineBasemap") private var online = true
    @AppStorage("hunt.map.style") private var mapStyle = MapBasemap.protomaps.rawValue
    private var hasMapTilerKey: Bool { MapTilerConfiguration.isConfigured }

    @State private var tab: Tab = .home
    @State private var mapOpened = false
    @State private var dataSection: DataSection = .routes
    @State private var serviceSection: ServiceSection = .weather
    @State private var weatherLayer: WeatherMapLayer = .none
    @State private var zone: GeoZone?
    @State private var showLayers = false
    @State private var showWeather = false
    @State private var showWeatherLayers = false
    @State private var showAbout = false
    @State private var showLegalLibrary = false
    @State private var showDiagnostics = false
    @State private var backupFile: URL?
    @State private var showGBIF = false
    @State private var showSearch = false
    @State private var searchText = ""
    @State private var selectedRouteFilter = "Все"
    @State private var selectedMarkerFilter = "Все"
    @State private var selectedWildlifeMode = "По угодьям"
    @State private var centerRequest = 0
    @State private var zoomCommand = 0
    @State private var overviewCommand = 0
    @AppStorage("hunt.showGrounds") private var showGrounds = true
    @AppStorage("hunt.showMarkers") private var showMarkersOnMap = true
    @AppStorage("hunt.showGPS") private var showGPSOnMap = true
    @AppStorage("hunt.showTrack") private var showTrackOnMap = true
    @State private var showAnimalsLayer = false
    @State private var editingMarker: Marker?
    @State private var selectedMapMarker: MapMarkerSelection?
    @State private var creatingMapMarker: Marker?
    @State private var pendingMapPoint: GeoPoint?
    @State private var pendingMapZone: GeoZone?
    @State private var movingMarkerID: UUID?
    @State private var showMapPointActions = false
    @State private var markerToDelete: Marker?
    @State private var trackToDelete: Track?
    @State private var mapFocus: GeoPoint?
    @State private var navigationTargetID: UUID?
    @State private var routeDestination: GeoPoint?
    @State private var routeTitle = "Выбранная точка"
    @State private var routeGuidance = false
    @State private var rerouteTime = Date.distantPast
    @State private var offRouteFixes = 0
    @State private var navigationPath: [GeoPoint] = []
    @State private var navigationKind = ""
    @State private var recordedRoute: RecordedTrackFollow?
    @State private var selectedRecordedTrackID: UUID?
    @State private var recordedRoutePreviewIndex = 0
    @State private var recordedRouteFollowing = false
    @State private var recordedRoutePlay = false
    @State private var playbackTask: Task<Void, Never>?
    @State private var recordedRouteProgress = 0
    @State private var recordedRouteRemaining = 0.0
    @State private var recordedRouteDeviation = 0.0
    @State private var travelMode: OfflineRouteGraph.TravelMode = .foot
    @State private var valhallaManeuvers: [ValhallaManeuver] = []
    @State private var nextTurnText = ""
    @State private var nextTurnDistance = 0.0
    @AppStorage("hunt.voiceGuidance") private var voiceGuidance = false
    @StateObject private var voice = RouteVoice()
    @State private var nextTurnTask: Task<Void, Never>?
    @State private var nextTurnWorker: Task<(Int, Double), Never>?
    @State private var routingError: String?
    @State private var importingRoutingNetwork = false
    @State private var routeGraph: OfflineRouteGraph?
    @State private var routeGraphCount = 0
    @State private var taxa: [GBIFTaxon] = []
    @State private var wildlifeError: String?

    private enum Tab: String, CaseIterable {
        case home = "Главная", map = "Карта", data = "Данные", services = "Сервисы", more = "Ещё"
        var icon: String {
            switch self {
            case .home: "house.fill"
            case .map: "map.fill"
            case .data: "square.grid.2x2.fill"
            case .services: "square.stack.3d.up.fill"
            case .more: "ellipsis"
            }
        }
    }
    private enum DataSection: String, CaseIterable { case routes = "Маршруты", markers = "Метки" }
    private enum ServiceSection: String, CaseIterable { case weather = "Погода", wildlife = "Животные" }

    var body: some View { serviceSheetsView }

    private var rootLayout: some View {
        ZStack {
            // MapLibre, PMTiles and style parsing can consume substantial memory.
            // Never construct the native map behind the Home screen on cold launch.
            // Instantiate only when the map tab is actually selected.
            if mapOpened || tab == .map {
                mapScreen
                    .opacity(tab == .map ? 1 : 0)
                    .allowsHitTesting(tab == .map)
                    .accessibilityHidden(tab != .map)
            }
            if tab != .map {
                themedScreen
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { navigation }
        .overlay(alignment: .top) {
            if startupSync.active {
                StartupSyncBanner(sync: startupSync)
                    .padding(.top, 105)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .background(HuntReference.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .background(ShakeDetector().frame(width: 1, height: 1))
    }

    private var lifecycleView: some View {
        rootLayout
        .onReceive(NotificationCenter.default.publisher(for: .huntShake)) { _ in showDiagnostics = true }
        .onAppear {
            LaunchHealth.started()
            // Do not parse the potentially huge routing/network.geojson on the
            // main thread at launch. Offline routing loads it on first request.
            startupSync.begin(hosting: hosting, tiles: maps, protomaps: protomaps,
                              model: model, valhalla: valhalla)
            // Weather is not critical to app launch: defer it until after the
            // first screen is usable and an actual map view has a viewport.
            Task {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                LaunchHealth.firstScreenReady()
                refreshWeatherOnLaunch()
                if weatherLayer != .none { weatherGrid.load(hourOffset: 0) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshWeatherOnLaunch() }
        }
        .onChange(of: connectivity.connected) { _, connected in
            if connected { refreshWeatherOnLaunch() }
        }
        .onChange(of: weatherLayer) { _, value in
            if value != .none { weatherGrid.load(hourOffset: weatherGrid.chosenOffset) }
        }
        .onDisappear { playbackTask?.cancel() }
        .onChange(of: tab) { _, value in
            if value == .map { mapOpened = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            if tab != .map { mapOpened = false }
        }
        .onChange(of: online) { _, enabled in if enabled { offlineRoads.clear() } }
    }

    private var gpsView: some View {
        lifecycleView
        .onChange(of: model.coordinate) { _, newPoint in
            if let point = newPoint {
                weather.updateIfNeeded(latitude: point.latitude, longitude: point.longitude)
            }
            if newPoint != nil, navigationKind == "Ожидание GPS", let destination = routeDestination {
                planRoute(to: destination, title: routeTitle, markerID: navigationTargetID)
            }
            if let position = newPoint, routeGuidance, let destination = routeDestination {
                if GeoMath.meters(position, destination) <= max(20, model.accuracy ?? 20) {
                    navigationKind = "Вы достигли точки назначения"
                    routeGuidance = false
                    model.stopRecordedRouteGuidance()
                    return
                }
                refreshNextTurn(at: position)
                if navigationPath.count >= 2 {
                    // Stay on long road segments: distance to vertices alone can
                    // incorrectly trigger rerouting between sparse map nodes.
                    let deviation = GeoMath.distanceToPolyline(position, navigationPath)
                    let threshold = max(150.0, (model.accuracy ?? 20) * 3)
                    offRouteFixes = deviation > threshold ? min(offRouteFixes + 1, 3) : 0
                    if offRouteFixes >= 3 && Date().timeIntervalSince(rerouteTime) > 45 {
                        rerouteTime = Date()
                        offRouteFixes = 0
                        planRoute(to: destination, title: routeTitle, markerID: navigationTargetID)
                    }
                }
            }
            if let position = newPoint, let route = recordedRoute, recordedRouteFollowing {
                let p = route.progress(from: position, after: recordedRouteProgress)
                recordedRouteProgress = max(recordedRouteProgress, p.index)
                recordedRouteRemaining = p.remaining
                recordedRouteDeviation = p.deviation
                if recordedRouteProgress >= route.points.count - 1 &&
                   p.deviation < max(25, model.accuracy ?? 25) {
                    recordedRouteFollowing = false
                    model.stopRecordedRouteGuidance()
                    navigationKind = "Маршрут завершён"
                }
            }
        }
    }

    private var importView: some View {
        gpsView
        .fileImporter(isPresented: $importingValhallaTiles,
                      allowedContentTypes: [UTType(filenameExtension: "tar") ?? .data],
                      allowsMultipleSelection: false) { result in
            do {
                guard let file = try result.get().first else { return }
                Task { await valhalla.install(file) }
            } catch { routingError = error.localizedDescription }
        }
        .fileImporter(isPresented: $importingRoutingNetwork, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            do {
                guard let file = try result.get().first else { return }
                let secured = file.startAccessingSecurityScopedResource()
                defer { if secured { file.stopAccessingSecurityScopedResource() } }
                let bytes = try Data(contentsOf: file)
                let graph = try OfflineRouteGraph(geoJSON: bytes, mode: travelMode)
                let location = routingNetworkURL
                try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: location, options: .atomic)
                routeGraph = graph
                routeGraphCount = graph.count
                if let id = navigationTargetID { startNavigation(to: id) }
            } catch { routingError = error.localizedDescription }
        }
        .alert("Маршрутизация", isPresented: Binding(get: { routingError != nil }, set: { if !$0 { routingError = nil } })) {
            Button("Понятно") { routingError = nil }
        } message: { Text(routingError ?? "") }
    }

    private var mapDialogsView: some View {
        importView
        .sheet(isPresented: $showLayers) { layerSheet }
        .sheet(isPresented: $showSearch) { mapSearchSheet }
        .sheet(item: $selectedMapMarker) { selection in
            MapMarkerDetails(markerID: selection.id, model: model,
                onShowOnMap: { point in
                    mapFocus = point
                    centerRequest += 1
                    tab = .map
                    selectedMapMarker = nil
                },
                onMove: {
                    movingMarkerID = selection.id
                    selectedMapMarker = nil
                },
                onNavigate: { id in
                    selectedMapMarker = nil
                    startNavigation(to: id)
                })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("Точка на карте", isPresented: $showMapPointActions, titleVisibility: .visible) {
            Button("Построить маршрут") {
                if routeGuidance { model.stopRecordedRouteGuidance() }
                routeGuidance = false
                if let point = pendingMapPoint { planRoute(to: point, title: "Точка на карте") }
                pendingMapPoint = nil
                pendingMapZone = nil
            }
            Button("Поставить метку") {
                if let point = pendingMapPoint {
                    creatingMapMarker = Marker(title: "Моя метка", kind: "Точка", coordinate: point)
                }
                pendingMapPoint = nil
                pendingMapZone = nil
            }
            if pendingMapZone != nil {
                Button("Информация об угодье") {
                    zone = pendingMapZone
                    pendingMapPoint = nil
                    pendingMapZone = nil
                }
            }
            Button("Отмена", role: .cancel) { pendingMapPoint = nil; pendingMapZone = nil }
        } message: {
            if let point = pendingMapPoint {
                Text(String(format: "Широта %.6f, долгота %.6f", point.latitude, point.longitude))
            }
        }
    }

    private var markerDialogsView: some View {
        mapDialogsView
        .sheet(item: $creatingMapMarker) { marker in
            MarkerEditor(marker: marker, isNew: true,
                         onSave: { changed in
                             model.insertMarker(changed)
                             showMarkersOnMap = true
                         },
                         onDelete: { _ in })
        }
        .sheet(item: $editingMarker) { marker in
            MarkerEditor(marker: marker,
                         onSave: { model.saveMarker($0) },
                         onDelete: { model.deleteMarker(id: $0) })
        }
        .confirmationDialog("Удалить метку?", isPresented: Binding(
            get: { markerToDelete != nil },
            set: { if !$0 { markerToDelete = nil } })) {
            Button("Удалить", role: .destructive) {
                if let markerToDelete { model.deleteMarker(id: markerToDelete.id) }
                markerToDelete = nil
            }
            Button("Отмена", role: .cancel) { markerToDelete = nil }
        }
        .confirmationDialog("Удалить маршрут?", isPresented: Binding(
            get: { trackToDelete != nil },
            set: { if !$0 { trackToDelete = nil } })) {
            Button("Удалить", role: .destructive) {
                if let trackToDelete { model.deleteTrack(id: trackToDelete.id) }
                trackToDelete = nil
            }
            Button("Отмена", role: .cancel) { trackToDelete = nil }
        }
    }

    private var serviceSheetsView: some View {
        markerDialogsView
        .sheet(isPresented: $showWeather) {
            WeatherPanel(service: weather, coordinate: model.coordinate, online: online)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showWeatherLayers) {
            WeatherMapSheet(service: weatherGrid, layer: $weatherLayer,
                            coordinate: model.coordinate, online: online,
                            onShowKazakhstan: { tab = .map; overviewCommand += 1 })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $zone) { GroundDetailsSheet(zone: $0) }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView(model: model, mapCount: maps.installed.count,
                            wildlifeCount: animals.packs.count, onlineMap: online,
                            weatherGridStatus: weatherGrid.status, weatherPointStatus: weather.message,
                            startupStatus: startupSync.title + " · " + startupSync.detail,
                            startupErrors: startupSync.errors,
                            internetConnected: connectivity.connected,
                            weatherLayer: weatherLayer.rawValue,
                            navigationStatus: navigationKind,
                            protomapsStatus: protomaps.status,
                            valhallaStatus: valhalla.status)
        }
        .sheet(isPresented: $showAbout) { AboutHuntView() }
        .sheet(isPresented: $showLegalLibrary) { LegalLibraryView() }
    }

    // MARK: - Root layout
    private var themedScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch tab {
                case .home: homeScreen
                case .data: dataScreen
                case .services: serviceScreen
                case .more: moreScreen
                case .map: EmptyView()
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 112)
        }
        .scrollIndicators(.hidden)
        .background(HuntReference.background.ignoresSafeArea())
    }

    private var navigation: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button { withAnimation(.easeOut(duration: 0.16)) { tab = item } } label: {
                    FBTabButton(title: item.rawValue, systemImage: item.icon, active: tab == item)
                        .frame(height: 57)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab_\(item.rawValue)")
            }
        }
        .padding(.horizontal, 7)
        .padding(.top, 8)
        .padding(.bottom, 5)
        .background(HuntReference.background.opacity(0.98))
        .overlay(alignment: .top) { Rectangle().fill(HuntReference.separator).frame(height: 1) }
        .padding(.bottom, 0)
    }

    // MARK: - Screen 1: Home, screenshot hierarchy
    private var homeScreen: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 31, weight: .bold))
                    .foregroundStyle(HuntReference.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("HUNT MAP KZ").font(.system(size: 19, weight: .bold))
                    Text("Охота · Карты · Навигация")
                        .font(.system(size: 11))
                        .foregroundStyle(HuntReference.muted)
                }
                Spacer()
                Button { showDiagnostics = true } label: {
                    Image(systemName: "bell.badge")
                        .foregroundStyle(HuntReference.green)
                        .frame(width: 42, height: 42)
                        .background(HuntReference.card, in: Circle())
                }
                .accessibilityLabel("Диагностика и события")
            }
            Button { tab = .map } label: {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [Color(red: 0.08, green: 0.32, blue: 0.25),
                                            HuntReference.card, Color(red: 0.04, green: 0.09, blue: 0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "mountain.2.fill")
                        .font(.system(size: 150, weight: .ultraLight))
                        .foregroundStyle(HuntReference.mint.opacity(0.28))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .offset(x: 15, y: 12)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Карты\nохотугодий\nКазахстана")
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                        Text("Офлайн · GPS · Границы")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.82))
                    }
                    .padding(20)
                }
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)

            Button { showLegalLibrary = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(HuntReference.green)
                        .frame(width: 54, height: 54)
                        .background(HuntReference.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Библиотека охотника").font(.headline.bold()).foregroundStyle(.white)
                        Text("Законы РК · Правила охоты · Путёвки · Оружие")
                            .font(.caption).foregroundStyle(HuntReference.muted)
                        Text("4 документа · 237 страниц · поиск · офлайн")
                            .font(.caption2.bold()).foregroundStyle(HuntReference.green)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").foregroundStyle(HuntReference.green)
                }
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("legal_library_home")
            Text("Быстрые действия").font(.headline.bold())
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
                ReferenceActionCard(title: "Карта и угодья", subtitle: "Открыть карту", symbol: "map") { tab = .map }
                ReferenceActionCard(title: "Офлайн-карты", subtitle: "Обновляются автоматически", symbol: "checkmark.icloud") { tab = .map }
                ReferenceActionCard(title: "Мои маршруты", subtitle: "Треки и GPX", symbol: "mappin.and.ellipse") { dataSection = .routes; tab = .data }
                ReferenceActionCard(title: "Слои и погода", subtitle: "Прогноз и карта", symbol: "square.3.layers.3d") { tab = .map; showLayers = true }
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("Мои данные").font(.headline.bold())
                HStack {
                    stat("Маршруты", model.tracks.count)
                    Spacer()
                    stat("Метки", model.markers.count)
                    Spacer()
                    stat("Угодья", model.zones.count)
                }
            }
            .padding(17)
            .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(HuntReference.muted)
            Text(String(value)).font(.system(size: 23, weight: .bold)).foregroundStyle(.white)
        }
    }

    // MARK: - Screen 2: Map. Map canvas itself must fill UIWindow bounds.
    private var mapScreen: some View {
        ZStack {
            OfflineMapView(zones: showGrounds ? model.zones : [],
                           position: showGPSOnMap ? model.coordinate : nil,
                           markers: showMarkersOnMap ? model.markers : [],
                           track: showTrackOnMap ? (model.tracks.first(where: { $0.id == selectedRecordedTrackID }) ?? model.currentTrack) : nil,
                           navigationPath: navigationPath,
                           replayPosition: replayMapPosition,
                           tileFiles: maps.paths, tileRevision: maps.revision,
                           offlineRoadLines: online ? [] : offlineRoads.lines,
                           offlineRoadRevision: offlineRoads.revision,
                           routingGeneration: hosting.installedRoutes.hashValue,
                           nativeOfflineStyleURL: nativePacks.styleURL,
                           protomapsOnlineStyleURL: protomaps.onlineStyleURL,
                           protomapsOfflineStyleURL: protomaps.offlineStyleURL,
                           protomapsHybridStyleURL: protomaps.hybridOfflineStyleURL,
                           online: online, active: tab == .map, zonesRevision: model.zoneRevision, selectedZone: $zone,
                           weatherGrid: tab == .map && weatherLayer != .none ? weatherGrid.grid : nil,
                           weatherLayer: tab == .map ? weatherLayer : .none,
                           centerRequest: centerRequest,
                           zoomCommand: zoomCommand,
                           overviewCommand: overviewCommand,
                           focusCoordinate: mapFocus,
                           onMapTap: { point in
                               if let id = movingMarkerID {
                                   if var marker = model.markers.first(where: { $0.id == id }) {
                                       marker.coordinate = point
                                       model.saveMarker(marker)
                                       selectedMapMarker = MapMarkerSelection(id: id)
                                   }
                                   movingMarkerID = nil
                               } else {
                                   pendingMapPoint = point
                                   pendingMapZone = model.zones.first(where: { $0.contains(point) })
                                   showMapPointActions = true
                               }
                           },
                           onMarkerTap: { id in
                               if movingMarkerID == nil {
                                   selectedMapMarker = MapMarkerSelection(id: id)
                               }
                           },
                           gridEnabled: gridMode,
                           gridStep: gridStep,
                           selectedGridCells: selectedGridCells,
                           onGridTap: { id in
                               if selectedGridCells.contains(id) { selectedGridCells.remove(id) }
                               else if selectedGridCells.count < 100 { selectedGridCells.insert(id) }
                           },
                           onViewportChanged: { bounds in
                               guard tab == .map else { return }
                               weatherGrid.updateViewport(bounds, active: weatherLayer != .none)
                               if !online {
                                   offlineRoads.load(bounds: bounds, files: hosting.installedRoadFiles(in: bounds))
                               }
                           })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .all)
            LinearGradient(colors: [.black.opacity(0.48), .clear, .black.opacity(0.28)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Button { showSearch = true } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "magnifyingglass")
                            Text("Поиск мест, охотугодий, точек")
                                .lineLimit(1).minimumScaleFactor(0.72)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 13)
                        .frame(height: 43)
                        .background(HuntReference.card.opacity(0.97), in: Capsule())
                    }
                    Button { showLayers = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(HuntReference.green)
                            .frame(width: 43, height: 43)
                            .background(HuntReference.card.opacity(0.97), in: Circle())
                    }
                    .accessibilityLabel("Слои")
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                HStack {
                    Spacer()
                    VStack(spacing: 9) {
                        circleMapButton("square.3.layers.3d", label: "Слои") { showLayers = true }
                        circleMapButton(gridMode ? "square.grid.3x3.fill" : "square.grid.3x3", label: "Выбор сетки") {
                            gridMode.toggle()
                        }
                        circleMapButton("cloud.sun.fill", label: "Погода") {
                                    if weatherLayer == .none { weatherLayer = .wind }
                                    showWeatherLayers = true
                                }
                        circleMapButton("location.fill", label: "Моё местоположение") {
                            mapFocus = nil
                            model.requestGPS()
                            centerRequest += 1
                        }
                        Spacer().frame(height: 8)
                        circleMapButton("plus", label: "Приблизить") { zoomCommand += 1 }
                        circleMapButton("minus", label: "Отдалить") { zoomCommand -= 1 }
                    }
                }
                .padding(.top, 16)
                .padding(.horizontal, 13)
                Spacer(minLength: 0)
                if !online {
                    HStack(spacing: 7) {
                        Image(systemName: maps.installed.isEmpty ? "point.topleft.down.curvedto.point.bottomright.up" : "checkmark.circle.fill")
                        Text(maps.installed.isEmpty
                            ? "MBTiles нет · дорожных пакетов: \(hosting.installedRoutes.count)"
                            : "MBTiles: \(maps.installed.count) · дороги: \(hosting.installedRoutes.count)")
                        Spacer()
                    }
                    Text(offlineRoads.status)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                    .font(.caption2.bold())
                    .foregroundStyle(maps.installed.isEmpty ? Color.orange : HuntReference.green)
                    .padding(9)
                    .background(HuntReference.card.opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                }
                if gridMode {
                    gridSelectionBar
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
                if let movingMarkerID {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.point.up.left.fill")
                        Text("Нажмите на новое место метки")
                        Spacer()
                        Button("Отмена") { self.movingMarkerID = nil }
                    }
                    .font(.caption.bold())
                    .padding(12)
                    .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("marker_move_mode")
                }
                if weatherLayer != .none {
                    Button { showWeatherLayers = true } label: {
                        Label("\(weatherLayer.rawValue) · \(weatherGrid.forecastLabel)", systemImage: "cloud.fill")
                            .font(.caption.bold())
                            .foregroundStyle(HuntReference.green)
                            .padding(10)
                            .background(HuntReference.card.opacity(0.94), in: Capsule())
                    }
                    .padding(.bottom, 4)
                    if weatherGrid.grid == nil {
                        HStack(spacing: 7) {
                            if weatherGrid.loading { ProgressView().tint(.white) }
                            Image(systemName: "cloud.slash").foregroundStyle(.orange)
                            Text(weatherGrid.status)
                                .lineLimit(2).font(.caption2)
                        }
                        .foregroundStyle(.white)
                        .padding(9)
                        .background(HuntReference.card.opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 12)
                    } else {
                        if weatherLayer == .precipitation, let active = weatherGrid.grid {
                            let knownRainfall = active.points.compactMap(\.precipitation)
                            if knownRainfall.isEmpty {
                                Label("Нет данных об осадках для выбранной области",
                                      systemImage: "cloud.slash")
                                    .font(.caption2).foregroundStyle(.orange)
                            } else if knownRainfall.allSatisfy({ $0 < 0.1 }) {
                                Label("Осадков не ожидается · 0 мм/ч",
                                      systemImage: "sun.max")
                                    .font(.caption2).foregroundStyle(.white)
                            }
                        }
                        Text("Прогноз загружен · \(weatherLayer.rawValue)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(7)
                            .background(HuntReference.card.opacity(0.86), in: Capsule())
                            .padding(.horizontal, 12)
                    }
                    Spacer().frame(height: 3)
                }
                if recordedRoute != nil {
                    recordedTrackPanel
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
                if routeDestination != nil {
                    navigationPanel
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
                if model.recording {
                    HStack(spacing: 8) {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                        Text(model.paused ? "Маршрут на паузе" : "Идёт запись маршрута")
                        Spacer()
                        Button(model.paused ? "Продолжить" : "Пауза") { model.togglePause() }
                    }
                    .font(.caption.bold())
                    .padding(12)
                    .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 13)
                    .padding(.bottom, 8)
                }
                HStack(spacing: 10) {
                    miniMapAction("location.north.fill", title: "GPS") { mapFocus = nil; model.requestGPS(); centerRequest += 1 }
                    miniMapAction("mappin.circle.fill", title: "Метка") {
                        if let point = mapFocus ?? model.coordinate {
                            creatingMapMarker = Marker(title: "Моя метка", kind: "Точка", coordinate: point)
                        } else {
                            model.status = "Нажмите на карту, чтобы выбрать место метки"
                        }
                    }
                    miniMapAction(model.recording ? "stop.fill" : "record.circle.fill",
                                  title: model.recording ? "Стоп" : "Запись") {
                        if model.recording { model.stopTrack() } else { model.startTrack() }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 84)
            }
        }
    }

    private var gridSelectionBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: "square.grid.3x3.fill").foregroundStyle(HuntReference.green)
                Text("Сетка · \(selectedGridCells.count) ячеек").font(.caption.bold())
                Spacer()
                Button("Закрыть") { gridMode = false }.font(.caption)
            }
            HStack(spacing: 8) {
                ForEach([0.05, 0.1, 0.25, 0.5], id: \.self) { step in
                    Button(String(format: "%.2f°", step)) {
                        gridStep = step
                        selectedGridCells.removeAll()
                    }
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(gridStep == step ? HuntReference.green.opacity(0.22) : Color.white.opacity(0.08),
                                in: Capsule())
                }
            }
            Text("Коснитесь ячеек на карте. Выделено до 100 участков.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("Очистить") { selectedGridCells.removeAll() }
                    .disabled(selectedGridCells.isEmpty)
                Spacer()
                Text("Карты обновляются при запуске").fontWeight(.semibold)
            }
            .font(.caption)
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(HuntReference.card.opacity(0.97), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - In-app offline guidance / routing
    private var routingNetworkURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("routing/network.geojson")
    }

    private func loadRoutingNetwork() {
        guard let bytes = try? Data(contentsOf: routingNetworkURL),
              let graph = try? OfflineRouteGraph(geoJSON: bytes, mode: travelMode) else { return }
        routeGraph = graph
        routeGraphCount = graph.count
    }

    private func startNavigation(to id: UUID) {
        guard let marker = model.markers.first(where: { $0.id == id }) else { return }
        if routeGuidance { model.stopRecordedRouteGuidance() }
        routeGuidance = false
        planRoute(to: marker.coordinate, title: marker.title, markerID: id)
    }
    private func planRoute(to destination: GeoPoint, title: String, markerID: UUID? = nil) {
        nextTurnTask?.cancel()
        nextTurnWorker?.cancel()
        voice.stop()
        if recordedRoute != nil { stopRecordedTrack() }
        if !routeGuidance { navigationPath = [] }
        routeDestination = destination
        routeTitle = title
        navigationTargetID = markerID
        valhallaManeuvers = []
        nextTurnText = ""
        tab = .map
        guard let current = model.coordinate else {
            navigationPath = []
            navigationKind = "Ожидание GPS"
            model.requestGPS()
            return
        }
        let requestID = UUID()
        routeRequestID = requestID
        let chosenMode = travelMode
        if valhalla.tilesInstalled {
            navigationPath = []
            navigationKind = "Valhalla · расчёт по локальным дорогам…"
            Task {
                do {
                    let result = try await valhalla.route(from: current, to: destination, mode: chosenMode)
                    guard routeRequestID == requestID, routeDestination == destination else { return }
                    navigationPath = result.path
                    valhallaManeuvers = result.maneuvers
                    refreshNextTurn(at: current)
                    navigationKind = chosenMode == .foot ? "Valhalla · пешком" : "Valhalla · автомобиль"
                    routingError = nil
                } catch {
                    guard routeRequestID == requestID, routeDestination == destination else { return }
                    AppDiagnosticLog.shared.recordError(subsystem: "Навигация",
                        operation: "Valhalla, \(chosenMode == .foot ? "пешком" : "авто")",
                        error: error, usedCache: valhalla.tilesInstalled)
                    calculateLegacyRoute(from: current, to: destination, mode: chosenMode,
                                         valhallaError: error.localizedDescription)
                }
            }
        } else {
            calculateLegacyRoute(from: current, to: destination, mode: chosenMode)
        }
    }

    private func calculateLegacyRoute(from current: GeoPoint, to destination: GeoPoint,
                                      mode: OfflineRouteGraph.TravelMode, valhallaError: String? = nil) {
        valhallaManeuvers = []
        nextTurnText = ""
        let requestID = routeRequestID ?? UUID()
        routeRequestID = requestID
        navigationKind = "Подготовка локальной дорожной сети…"
        let fallbackFile = routingNetworkURL
        Task {
            do {
                let graph: OfflineRouteGraph
                if let downloaded = try? await hosting.graphAsync(start: current, destination: destination, mode: mode) {
                    graph = downloaded
                } else {
                    graph = try await Task.detached(priority: .userInitiated) {
                        let bytes = try Data(contentsOf: fallbackFile, options: .mappedIfSafe)
                        return try OfflineRouteGraph(geoJSON: bytes, mode: mode)
                    }.value
                }
                let route = try await Task.detached(priority: .userInitiated) {
                    try graph.path(from: current, to: destination)
                }.value
                guard routeRequestID == requestID, routeDestination == destination else { return }
                guard route.count >= 2 else { throw OfflineRouteGraph.RouteError.disconnected }
                navigationPath = route
                navigationKind = mode == .foot ? "Локальный граф · пешком" : "Локальный граф · автомобиль"
                routingError = nil
            } catch {
                guard routeRequestID == requestID, routeDestination == destination else { return }
                navigationPath = []
                navigationKind = "Маршрут недоступен"
                AppDiagnosticLog.shared.recordError(subsystem: "Навигация",
                    operation: "Резервный локальный граф, \(mode == .foot ? "пешком" : "авто")",
                    error: error, usedCache: routeGraph != nil || !hosting.installedRoutes.isEmpty)
                routingError = (valhallaError.map { "Valhalla: \($0). " } ?? "") + error.localizedDescription
            }
        }
    }

    private func refreshNextTurn(at location: GeoPoint) {
        let path = navigationPath
        let maneuvers = valhallaManeuvers
        guard path.count >= 2, !maneuvers.isEmpty else { return }
        nextTurnTask?.cancel()
        nextTurnWorker?.cancel()
        let previous = nextTurnWorker
        let indices = maneuvers.map(\.beginIndex)
        let worker = Task.detached(priority: .userInitiated) {
            _ = await previous?.value
            var closestIndex = 0
            var closestMeters = Double.infinity
            for (index, point) in path.enumerated() {
                if Task.isCancelled { return (-1, 0.0) }
                let distance = GeoMath.meters(location, point)
                if distance < closestMeters { closestMeters = distance; closestIndex = index }
            }
            let maneuverIndex = indices.firstIndex(where: { $0 > closestIndex }) ?? indices.count - 1
            let end = min(path.count - 1, max(0, indices[maneuverIndex]))
            var distance = 0.0
            if closestIndex < end {
                for index in (closestIndex + 1)...end {
                    distance += GeoMath.meters(path[index - 1], path[index])
                }
            }
            return (maneuverIndex, distance)
        }
        nextTurnWorker = worker
        let request = routeRequestID
        nextTurnTask = Task { @MainActor in
            let (index, distance) = await worker.value
            guard !Task.isCancelled, request == routeRequestID, maneuvers.indices.contains(index) else { return }
            nextTurnText = maneuvers[index].instruction
            nextTurnDistance = distance
            if routeGuidance && voiceGuidance {
                voice.announce(instruction: nextTurnText, distance: distance, maneuver: index)
            }
        }
    }

    private func stopNavigation() {
        nextTurnTask?.cancel()
        nextTurnWorker?.cancel()
        voice.stop()
        valhallaManeuvers = []
        nextTurnText = ""
        routeRequestID = nil
        navigationTargetID = nil
        routeDestination = nil
        if routeGuidance { model.stopRecordedRouteGuidance() }
        routeGuidance = false
        if recordedRoute == nil { navigationPath = [] }
        navigationKind = ""
    }

    private var replayMapPosition: GeoPoint? {
        guard let route = recordedRoute, !recordedRouteFollowing,
              !route.points.isEmpty else { return nil }
        return route.points[max(0, min(recordedRoutePreviewIndex, route.points.count - 1))]
    }

    private func showRecordedTrack(_ track: Track, direction: RecordedRouteDirection, follow: Bool) {
        guard let route = RecordedTrackFollow(track: track, direction: direction) else {
            routingError = "В записи меньше двух GPS-точек. Маршрут нельзя воспроизвести."
            return
        }
        playbackTask?.cancel()
        recordedRoutePlay = false
        model.stopRecordedRouteGuidance()
        routeRequestID = nil
        navigationTargetID = nil
        routeDestination = nil
        routeGuidance = false
        selectedRecordedTrackID = track.id
        recordedRoute = route
        recordedRoutePreviewIndex = 0
        recordedRouteProgress = 0
        recordedRouteRemaining = route.remainingFrom[0]
        recordedRouteDeviation = 0
        recordedRouteFollowing = follow
        navigationPath = route.points
        navigationKind = follow ? "Повторное прохождение · \(direction.rawValue)" : "Просмотр записи · \(direction.rawValue)"
        tab = .map
        mapFocus = route.points[0]
        centerRequest += 1
        if follow { model.startRecordedRouteGuidance() }
    }

    private func stopRecordedTrack() {
        model.stopRecordedRouteGuidance()
        playbackTask?.cancel()
        playbackTask = nil
        recordedRoutePlay = false
        recordedRouteFollowing = false
        recordedRoute = nil
        selectedRecordedTrackID = nil
        recordedRoutePreviewIndex = 0
        recordedRouteProgress = 0
        if navigationTargetID == nil { navigationPath = []; navigationKind = "" }
    }

    private func playRecordedTrack() {
        guard let route = recordedRoute, !recordedRouteFollowing else { return }
        playbackTask?.cancel()
        if recordedRoutePreviewIndex >= route.points.count - 1 {
            recordedRoutePreviewIndex = 0
        }
        recordedRoutePlay = true
        playbackTask = Task { @MainActor in
            while !Task.isCancelled && recordedRoutePlay,
                  let current = recordedRoute, recordedRoutePreviewIndex < current.points.count - 1 {
                try? await Task.sleep(nanoseconds: 230_000_000)
                if Task.isCancelled || !recordedRoutePlay { break }
                recordedRoutePreviewIndex += 1
                if recordedRoutePreviewIndex % 8 == 0 || recordedRoutePreviewIndex == current.points.count - 1 {
                    mapFocus = current.points[recordedRoutePreviewIndex]
                    centerRequest += 1
                }
            }
            recordedRoutePlay = false
        }
    }

    private var recordedTrackPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let route = recordedRoute {
                HStack {
                    Image(systemName: recordedRouteFollowing ? "figure.walk.motion" : "play.rectangle.fill")
                        .foregroundStyle(HuntReference.green)
                    Text(navigationKind).font(.caption.bold()).lineLimit(2)
                    Spacer()
                    Button { stopRecordedTrack() } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityIdentifier("recorded_track_stop")
                }
                if recordedRouteFollowing {
                    Text(String(format: "Осталось по записи: %.2f км · отклонение от ближайшей точки: %.0f м",
                                recordedRouteRemaining / 1000, recordedRouteDeviation))
                        .font(.caption.monospacedDigit())
                    if recordedRouteDeviation > 60 {
                        Text("Вы отклонились от записанного пути. Проверьте местность.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button("Остановить прохождение") { stopRecordedTrack() }
                        .buttonStyle(.bordered)
                } else {
                    Slider(value: Binding(get: { Double(recordedRoutePreviewIndex) },
                                          set: { recordedRoutePreviewIndex = Int($0); recordedRoutePlay = false;
                                                 playbackTask?.cancel() }),
                           in: 0...Double(route.points.count - 1), step: 1)
                        .accessibilityIdentifier("recorded_track_timeline")
                    HStack {
                        Text("\(recordedRoutePreviewIndex + 1) / \(route.points.count)")
                            .font(.caption.monospacedDigit())
                        Spacer()
                        Button(recordedRoutePlay ? "Пауза" : "Воспроизвести") {
                            if recordedRoutePlay { recordedRoutePlay = false; playbackTask?.cancel() }
                            else { playRecordedTrack() }
                        }
                        .accessibilityIdentifier("recorded_track_play")
                        Button("Пройти") {
                            recordedRoutePlay = false
                            playbackTask?.cancel()
                            recordedRouteFollowing = true
                            recordedRouteProgress = 0
                            model.startRecordedRouteGuidance()
                            navigationKind = "Повторное прохождение · \(route.direction.rawValue)"
                        }.accessibilityIdentifier("recorded_track_follow")
                    }
                    .font(.caption.bold())
                }
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(HuntReference.card.opacity(0.97), in: RoundedRectangle(cornerRadius: 14))
    }

    private func bearing(to destination: GeoPoint, from origin: GeoPoint) -> Int {
        let lat1 = origin.latitude * .pi / 180, lat2 = destination.latitude * .pi / 180
        let dl = (destination.longitude - origin.longitude) * .pi / 180
        let y = sin(dl) * cos(lat2)
        let x = cos(lat1)*sin(lat2) - sin(lat1)*cos(lat2)*cos(dl)
        return Int((atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360).rounded()) % 360
    }

    private var navigationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let destination = routeDestination {
                HStack(spacing: 8) {
                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                        .foregroundStyle(HuntReference.green)
                    Text(routeTitle).font(.subheadline.bold()).lineLimit(1)
                    Spacer()
                    Button { stopNavigation() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3)
                    }
                }
                HStack(spacing: 9) {
                    Button {
                        travelMode = .car
                        routeGuidance = false
                        planRoute(to: destination, title: routeTitle, markerID: navigationTargetID)
                    } label: {
                        Label("Авто", systemImage: "car.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(travelMode == .car ? HuntReference.green.opacity(0.3) : Color.white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 11))
                    }.accessibilityIdentifier("route_drive")
                    Button {
                        travelMode = .foot
                        routeGuidance = false
                        planRoute(to: destination, title: routeTitle, markerID: navigationTargetID)
                    } label: {
                        Label("Пешком", systemImage: "figure.walk")
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(travelMode == .foot ? HuntReference.green.opacity(0.3) : Color.white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 11))
                    }.accessibilityIdentifier("route_walk")
                }.buttonStyle(.plain).font(.caption.bold())
                Text(navigationKind).font(.caption)
                    .foregroundStyle(navigationPath.isEmpty ? Color.orange : Color.gray)
                if let current = model.coordinate {
                    let distance = GeoMath.meters(current, destination)
                    Text(String(format: "По прямой: %.0f м · Азимут %d°",
                                distance, bearing(to: destination, from: current)))
                        .font(.caption.monospacedDigit())
                }
                if routeGuidance {
                    Toggle("Голосовые подсказки", isOn: $voiceGuidance).font(.caption)
                        .onChange(of: voiceGuidance) { _, enabled in if !enabled { voice.stop() } }
                    Label("Ведение включено", systemImage: "location.north.line.fill")
                        .font(.caption.bold()).foregroundStyle(HuntReference.green)
                    if !nextTurnText.isEmpty {
                        Text(nextTurnText).font(.subheadline.bold())
                        Text(String(format: "Следующий манёвр через %.0f м", nextTurnDistance))
                            .font(.caption.monospacedDigit())
                    }
                    Button("Завершить") { stopNavigation() }.buttonStyle(.bordered)
                } else {
                    Button {
                        routeGuidance = true
                        rerouteTime = Date()
                        model.startRecordedRouteGuidance()
                        if let position = model.coordinate { refreshNextTurn(at: position) }
                    } label: {
                        Label("В путь", systemImage: "location.north.line.fill")
                            .font(.headline.bold()).frame(maxWidth: .infinity).frame(minHeight: 46)
                    }
                    .buttonStyle(.borderedProminent).tint(HuntReference.green)
                    .disabled(navigationPath.count < 2)
                    .accessibilityIdentifier("route_start_guidance")
                }
                if navigationPath.count < 2 {
                    Text("Для навигации необходима загруженная дорожная сеть.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(.white).padding(12)
        .background(HuntReference.card.opacity(0.97), in: RoundedRectangle(cornerRadius: 16))
    }

    private func circleMapButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(HuntReference.green)
                .frame(width: 47, height: 47)
                .background(HuntReference.card.opacity(0.95), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
    private func miniMapAction(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 47)
                .background(HuntReference.card.opacity(0.95), in: RoundedRectangle(cornerRadius: 17))
        }
        .buttonStyle(.plain)
    }

    private var mapSearchSheet: some View {
        NavigationStack {
            List {
                Section("Охотугодья · локальный каталог") {
                    ForEach(model.zones.filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }) { ground in
                        Button {
                            showSearch = false
                            tab = .map
                            zone = ground
                        } label: {
                            Label(ground.name, systemImage: "map")
                        }
                    }
                }
                Section("Метки · сохранённые") {
                    ForEach(model.markers.filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) }) { marker in
                        Button {
                            showSearch = false
                            tab = .map
                            mapFocus = marker.coordinate
                            centerRequest += 1
                        } label: {
                            HStack {
                                Label(marker.title, systemImage: "mappin.circle")
                                Spacer()
                                Text(String(format: "%.4f, %.4f", marker.coordinate.latitude, marker.coordinate.longitude))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Название охотугодья или метки")
            .navigationTitle("Поиск на карте")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { showSearch = false } } }
        }
    }

    // MARK: - Screen 3: Layers
    private var layerSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ReferencePageHeader(title: "Слои карты")
                    Text("Картографический движок: MapLibre Native")
                        .font(.caption).foregroundStyle(HuntReference.muted)

                    Text("Базовая карта").font(.headline).foregroundStyle(.white)
                    Button {
                        online = false
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "iphone.gen3").frame(width: 25)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Офлайн · мои карты").font(.subheadline.bold())
                                Text(maps.installed.isEmpty
                                     ? "MBTiles не установлены. Дорог: \(hosting.installedRoutes.count)"
                                     : "Установлено пакетов: \(maps.installed.count)")
                                    .font(.caption2).foregroundStyle(HuntReference.muted)
                            }
                            Spacer()
                            if !online { Image(systemName: "checkmark.circle.fill").foregroundStyle(HuntReference.green) }
                        }
                        .padding(12)
                        .background(HuntReference.green.opacity(!online ? 0.15 : 0.05), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)

                    Button {
                        mapStyle = MapBasemap.hybrid.rawValue
                        online = false
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "square.3.layers.3d").frame(width: 25)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Гибрид · полностью офлайн").font(.subheadline.bold())
                                Text("Спутниковые MBTiles + дороги/тропы Protomaps")
                                    .font(.caption2).foregroundStyle(HuntReference.muted)
                            }
                            Spacer()
                            if !online && mapStyle == MapBasemap.hybrid.rawValue {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(HuntReference.green)
                            }
                        }
                        .padding(12)
                        .background(HuntReference.green.opacity(!online && mapStyle == MapBasemap.hybrid.rawValue ? 0.15 : 0.05),
                                    in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .disabled(protomaps.installed.isEmpty || maps.installed.isEmpty)

                    ForEach(MapBasemap.allCases) { basemap in
                        let available = basemap.isAvailable(apiKey: MapTilerConfiguration.apiKey)
                        Button {
                            guard available else { return }
                            mapStyle = basemap.rawValue
                            online = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: basemap.symbol).frame(width: 25)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(basemap.name).font(.subheadline.bold())
                                    Text(available ? basemap.detail : "Требуется ключ MapTiler")
                                        .font(.caption2).foregroundStyle(HuntReference.muted)
                                }
                                Spacer()
                                if online && mapStyle == basemap.rawValue {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(HuntReference.green)
                                }
                            }
                            .padding(12)
                            .background(HuntReference.green.opacity(online && mapStyle == basemap.rawValue ? 0.15 : 0.05),
                                        in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .disabled(!available)
                        .opacity(available ? 1 : 0.55)
                    }

                    Text("MBTiles отображаются как подложка, а сохранённые дорожные GeoJSON как линии поверх неё. Без MBTiles офлайн-дороги видны на тёмном фоне, но изображения местности нет.")
                        .font(.caption2).foregroundStyle(HuntReference.muted)

                    if !online && mapStyle == MapBasemap.hybrid.rawValue {
                        Text(maps.installed.isEmpty
                             ? "Гибрид без интернета требует предварительно скачанных спутниковых MBTiles."
                             : "Гибрид офлайн: только локальные MBTiles и Protomaps; проверьте, что MBTiles — спутниковые снимки.")
                            .font(.caption)
                            .foregroundStyle(maps.installed.isEmpty ? Color.orange : HuntReference.muted)
                    }
                    Text("Дополнительные слои").font(.headline).foregroundStyle(.white)
                    ReferenceLayerRow(symbol: "map", title: "Охотугодья",
                                      detail: "Проверенные и импортированные границы", enabled: $showGrounds)
                    ReferenceLayerRow(symbol: "cloud.sun", title: "Погода",
                                      detail: "Ветер, давление, осадки", enabled: weatherEnabledBinding)
                    ReferenceLayerRow(symbol: "pawprint.fill", title: "Животные",
                                      detail: "Нужны проверенные геоданные", enabled: $showAnimalsLayer,
                                      available: false)
                    ReferencePrimaryButton(title: "Закрыть", symbol: "checkmark") { showLayers = false }
                }
                .padding(17)
            }
            .background(HuntReference.background.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { showLayers = false } } }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var weatherEnabledBinding: Binding<Bool> {
        Binding(get: { weatherLayer != .none },
                set: { if $0 { showLayers = false; showWeatherLayers = true }
                       else { weatherLayer = .none } })
    }

    // MARK: - Screens 5 & 6: Data / routes / markers
    private var dataScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ReferenceChip(title: "Маршруты", selected: dataSection == .routes) { dataSection = .routes }
                ReferenceChip(title: "Метки", selected: dataSection == .markers) { dataSection = .markers }
            }
            if dataSection == .routes { routesContent } else { markersContent }
        }
    }

    private var routesContent: some View {
        VStack(alignment: .leading, spacing: 15) {
            ReferencePageHeader(title: "Маршруты")
            HStack {
                Label("Valhalla", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                Spacer()
                Text("Обновляется автоматически")
            }
            .font(.caption.bold())
            .foregroundStyle(HuntReference.green)
            Text(valhalla.status).font(.caption2).foregroundStyle(HuntReference.muted)
            ReferencePrimaryButton(title: model.recording ? "Завершить маршрут" : "Новый маршрут",
                                   symbol: model.recording ? "stop.fill" : "plus") {
                if model.recording { model.stopTrack() } else { model.startTrack() }
            }
            HStack(spacing: 8) {
                ForEach(["Все", "Активные", "Архив"], id: \.self) { filter in
                    ReferenceChip(title: filter, selected: selectedRouteFilter == filter) {
                        selectedRouteFilter = filter
                    }
                }
            }
            if model.recording && selectedRouteFilter != "Архив" {
                HStack(spacing: 11) {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.currentTrack?.name ?? "Активная запись").font(.subheadline.bold())
                        Text(model.paused ? "На паузе" : "Идёт запись").font(.caption).foregroundStyle(HuntReference.muted)
                    }
                    Spacer()
                    Button(model.paused ? "Продолжить" : "Пауза") { model.togglePause() }
                        .font(.caption.bold()).foregroundStyle(HuntReference.green)
                }
                .fbCard()
            }
            if selectedRouteFilter != "Активные" {
                ForEach(model.tracks) { track in
                    routeRow(track)
                }
            }
            if (selectedRouteFilter == "Активные" && !model.recording) ||
               (selectedRouteFilter != "Активные" && model.tracks.isEmpty && !model.recording) {
                ReferenceEmptyCard(title: "Маршрутов пока нет",
                                   detail: "Начни запись GPS на карте", symbol: "figure.hiking")
            }
        }
    }

    private func routeDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours) ч \(minutes) мин" : "\(minutes) мин"
    }

    private func routeRow(_ track: Track) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .foregroundStyle(HuntReference.green)
                .font(.title2)
                .frame(width: 43, height: 43)
                .background(HuntReference.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(track.name).font(.subheadline.bold())
                Text(String(format: "%.2f км · %d точек · %@", track.distanceMeters / 1000,
                            track.fixes.count, routeDuration(track.durationSeconds)))
                    .font(.caption).foregroundStyle(HuntReference.muted)
                Text(track.createdAt.formatted(date: .numeric, time: .omitted))
                    .font(.caption2).foregroundStyle(HuntReference.muted)
            }
            Spacer(minLength: 2)
            Menu {
                Button("Показать на карте", systemImage: "map") {
                    showRecordedTrack(track, direction: .forward, follow: false)
                }
                Button("Воспроизвести: от начала", systemImage: "play.fill") {
                    showRecordedTrack(track, direction: .forward, follow: false)
                    playRecordedTrack()
                }
                Button("Воспроизвести: от конца", systemImage: "backward.fill") {
                    showRecordedTrack(track, direction: .backward, follow: false)
                    playRecordedTrack()
                }
                Button("Пройти от начала", systemImage: "figure.walk") {
                    showRecordedTrack(track, direction: .forward, follow: true)
                }
                Button("Пройти от конца", systemImage: "figure.walk.motion") {
                    showRecordedTrack(track, direction: .backward, follow: true)
                }
                if let file = model.exportGPX(track) {
                    ShareLink(item: file) { Label("Поделиться GPX", systemImage: "square.and.arrow.up") }
                }
                Button("Удалить маршрут", systemImage: "trash", role: .destructive) {
                    trackToDelete = track
                }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(.white)
                    .frame(width: 36, height: 36)
            }
        }
        .fbCard()
    }

    private var markersContent: some View {
        VStack(alignment: .leading, spacing: 15) {
            ReferencePageHeader(title: "Метки")
            ReferencePrimaryButton(title: "Добавить метку", symbol: "plus") {
                model.addMarker(kind: selectedMarkerFilter == "Все" ? "Точка" : selectedMarkerFilter)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["Все", "База", "Зверь", "Кормушка", "Другое"], id: \.self) { category in
                        ReferenceChip(title: category, selected: selectedMarkerFilter == category) {
                            selectedMarkerFilter = category
                        }
                    }
                }
            }
            ForEach(filteredMarkers) { marker in
                markerRow(marker)
            }
            if filteredMarkers.isEmpty {
                ReferenceEmptyCard(title: "Нет меток в этой категории",
                                   detail: "Добавь точку через GPS или выбери другую категорию",
                                   symbol: "mappin.slash")
            }
        }
    }

    private var filteredMarkers: [Marker] {
        model.markers.filter { selectedMarkerFilter == "Все" || markerCategory($0) == selectedMarkerFilter }
    }
    private func markerCategory(_ marker: Marker) -> String {
        let description = (marker.kind + " " + (marker.symbol ?? "")).lowercased()
        if description.contains("база") || description.contains("лагерь") || description.contains("дом") { return "База" }
        if description.contains("звер") || description.contains("живот") || description.contains("paw") || description.contains("лось") { return "Зверь" }
        if description.contains("корм") { return "Кормушка" }
        return "Другое"
    }
    private func markerRow(_ marker: Marker) -> some View {
        HStack(spacing: 12) {
            Image(systemName: marker.symbol ?? "mappin.circle.fill")
                .font(.title2)
                .foregroundStyle(HuntReference.green)
                .frame(width: 43, height: 43)
                .background(HuntReference.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 5) {
                Text(marker.title).font(.subheadline.bold())
                Text(String(format: "%.5f, %.5f", marker.coordinate.latitude, marker.coordinate.longitude))
                    .font(.caption).foregroundStyle(HuntReference.muted)
            }
            Spacer()
            Menu {
                Button("Показать на карте", systemImage: "map") {
                    tab = .map
                    mapFocus = marker.coordinate
                    centerRequest += 1
                }
                Button("Редактировать", systemImage: "pencil") { editingMarker = marker }
                ShareLink(item: "geo:\(marker.coordinate.latitude),\(marker.coordinate.longitude)") {
                    Label("Поделиться точкой", systemImage: "square.and.arrow.up")
                }
                Button("Удалить", systemImage: "trash", role: .destructive) { markerToDelete = marker }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(.white)
                    .frame(width: 35, height: 35)
            }
        }
        .fbCard()
    }

    // MARK: - Screen 4: Weather, Screen 7: Animals, Screen 8: More
    private var serviceScreen: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 8) {
                ReferenceChip(title: "Погода", selected: serviceSection == .weather) { serviceSection = .weather }
                ReferenceChip(title: "Животные", selected: serviceSection == .wildlife) { serviceSection = .wildlife }
            }
            if serviceSection == .weather { weatherContent } else { wildlifeContent }
        }
    }

    private var weatherContent: some View {
        VStack(alignment: .leading, spacing: 13) {
            ReferencePageHeader(title: "Погода")
            Label("По текущей GPS-позиции", systemImage: "mappin.circle.fill")
                .font(.caption)
                .foregroundStyle(HuntReference.muted)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "cloud.sun.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(HuntReference.mint)
                    Text(weather.forecast?.temperatureC.map { "\(Int($0.rounded()))°" } ?? "—°")
                        .font(.system(size: 46, weight: .light, design: .rounded))
                    Text(weather.forecast == nil ? "Нет прогноза" : "Прогноз Open-Meteo")
                        .font(.caption)
                        .foregroundStyle(HuntReference.muted)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 13) {
                    weatherMetric("Ветер", value: weather.forecast?.current.windSpeedKmh.map { String(format: "%.1f км/ч", $0) } ?? "—", icon: "wind")
                    weatherMetric("Давление", value: weather.forecast?.current.pressureMSLHpa.map { String(format: "%.0f гПа", $0) } ?? "—", icon: "barometer")
                    weatherMetric("Осадки", value: weather.forecast?.current.precipitationMm.map { String(format: "%.1f мм", $0) } ?? "—", icon: "cloud.rain")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 22))

            if let forecast = weather.forecast, !forecast.hourly.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        ForEach(Array(forecast.hourly.prefix(8).enumerated()), id: \.offset) { _, item in
                            VStack(spacing: 8) {
                                Text(item.timestamp.formatted(date: .omitted, time: .shortened))
                                    .font(.caption2).foregroundStyle(HuntReference.muted)
                                Image(systemName: "clock")
                                    .foregroundStyle(HuntReference.green)
                                Text(item.precipitationProbabilityPercent.map { "\(Int($0))%" } ?? "—")
                                    .font(.caption.bold())
                            }
                        }
                    }
                    .padding(14)
                }
                .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 19))
            } else {
                Text("Почасовой прогноз появится после загрузки данных")
                    .font(.caption).foregroundStyle(HuntReference.muted)
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 19))
            }
            VStack(spacing: 0) {
                serviceAction("Прогноз по часам", icon: "calendar") { showWeather = true }
                Divider().overlay(HuntReference.separator)
                serviceAction("Карта ветра", icon: "wind") { weatherLayer = .wind; openWeatherMap() }
                Divider().overlay(HuntReference.separator)
                serviceAction("Карта осадков", icon: "drop") { weatherLayer = .precipitation; openWeatherMap() }
                Divider().overlay(HuntReference.separator)
                serviceAction("Карта давления", icon: "barometer") { weatherLayer = .pressure; openWeatherMap() }
            }
            .padding(.horizontal, 13)
            .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 21))
            if let point = model.coordinate {
                Button(weather.busy ? "Обновляется…" : "Обновить прогноз") {
                    weather.refresh(latitude: point.latitude, longitude: point.longitude, strictOffline: false)
                }
                .font(.footnote.bold())
                .foregroundStyle(HuntReference.green)
                .disabled(weather.busy)
            } else {
                Text("Включи GPS, чтобы получить прогноз для своего местоположения")
                    .font(.caption).foregroundStyle(HuntReference.muted)
            }
            Text(weather.message).font(.caption2).foregroundStyle(HuntReference.muted)
        }
        .onAppear {
            if let point = model.coordinate {
                weather.refresh(latitude: point.latitude, longitude: point.longitude, strictOffline: false)
            }
        }
    }
    private func weatherMetric(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(HuntReference.green).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(HuntReference.muted)
                Text(value).font(.caption.bold())
            }
        }
    }
    private func serviceAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon).foregroundStyle(HuntReference.green).frame(width: 27)
                Text(title).font(.subheadline.bold()).foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(HuntReference.muted)
            }
            .frame(height: 54)
        }
        .buttonStyle(.plain)
    }
    private func refreshWeatherOnLaunch() {
        // GPS may not yet have a fix on launch. In that case refresh for the last
        // known weather location; the first new GPS fix will correct it if needed.
        guard let latitude = model.coordinate?.latitude ?? weather.forecast?.latitude,
              let longitude = model.coordinate?.longitude ?? weather.forecast?.longitude else { return }
        // A network request is attempted even if the map itself uses offline PMTiles.
        weather.updateIfNeeded(latitude: latitude, longitude: longitude, force: true)
        if weatherLayer != .none {
            weatherGrid.load(latitude: latitude, longitude: longitude,
                             hourOffset: weatherGrid.chosenOffset)
        }
    }
    private func openWeatherMap() {
        tab = .map
        showWeatherLayers = true
    }

    private var wildlifeContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            ReferencePageHeader(title: "Животные")
            HStack(spacing: 8) {
                ForEach(["По угодьям", "Справочник"], id: \.self) { name in
                    ReferenceChip(title: name, selected: selectedWildlifeMode == name) {
                        selectedWildlifeMode = name
                    }
                }
            }
            if selectedWildlifeMode == "По угодьям" {
                if animals.packs.isEmpty {
                    ReferenceEmptyCard(title: "Каталоги животных не загружены",
                                       detail: "Импортируй подтверждённые сведения об угодье",
                                       symbol: "pawprint")
                }
                ForEach(Array(animals.packs.enumerated()), id: \.offset) { _, pack in
                    VStack(alignment: .leading, spacing: 11) {
                        Text("Угодье: \(pack.ground_id)").font(.headline)
                        Text("Источник: \(pack.source)").font(.caption).foregroundStyle(HuntReference.muted)
                        ForEach(pack.taxa) { taxon in
                            HStack {
                                Image(systemName: "pawprint.fill").foregroundStyle(HuntReference.green)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(taxon.name_ru ?? taxon.name_kk ?? taxon.scientific_name).font(.subheadline.bold())
                                    Text("Статус: \(taxon.category) · записей: \(taxon.evidence_count)")
                                        .font(.caption2).foregroundStyle(HuntReference.muted)
                                }
                                Spacer()
                            }
                        }
                    }.fbCard()
                }
            } else {
                ReferenceEmptyCard(title: "Справочник наблюдений GBIF",
                                   detail: "Публичные наблюдения не подтверждают право на охоту",
                                   symbol: "book.closed")
                ReferencePrimaryButton(title: showGBIF ? "Загрузка…" : "Обновить справочник", symbol: "arrow.clockwise") {
                    Task {
                        showGBIF = true
                        do { taxa = try await GBIFDiscovery.fetchKazakhstan(); wildlifeError = nil }
                        catch { wildlifeError = error.localizedDescription }
                        showGBIF = false
                    }
                }
                .disabled(showGBIF)
                if let wildlifeError { Text(wildlifeError).foregroundStyle(.red).font(.caption) }
                ForEach(taxa) { animal in
                    HStack {
                        Image(systemName: "pawprint.fill").foregroundStyle(HuntReference.green)
                        Text(animal.name).font(.subheadline)
                        Spacer()
                    }.fbCard()
                }
            }
            Text("Карты и каталоги синхронизируются автоматически")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var moreScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            ReferencePageHeader(title: "Ещё")
            VStack(spacing: 0) {
                ReferenceMenuRow(symbol: "books.vertical", title: "Библиотека охотника") { showLegalLibrary = true }
                Divider().overlay(HuntReference.separator)
                ReferenceMenuRow(symbol: "waveform.path.ecg", title: "Диагностика") { showDiagnostics = true }
                Divider().overlay(HuntReference.separator)
                ReferenceMenuRow(symbol: "externaldrive", title: "Создать резервную копию") {
                    backupFile = model.exportBackup()
                }
                if let backupFile {
                    ShareLink(item: backupFile) {
                        Label("Сохранить копию маршрутов, меток и границ",
                              systemImage: "square.and.arrow.up")
                            .font(.subheadline.bold())
                            .foregroundStyle(HuntReference.green)
                            .padding(14)
                    }
                    .accessibilityIdentifier("export_complete_backup")
                }
                Divider().overlay(HuntReference.separator)
                ReferenceMenuRow(symbol: "gearshape", title: "Настройки") { showLayers = true }
                Divider().overlay(HuntReference.separator)
                ReferenceMenuRow(symbol: "info.circle", title: "О приложении") { showAbout = true }
            }
            .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 20))
            VStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 50, weight: .bold))
                    .foregroundStyle(HuntReference.green)
                Text("HUNT MAP KZ").font(.headline.bold())
                Text("Версия \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "неизвестна")")
                    .font(.caption).foregroundStyle(HuntReference.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 42)
        }
    }

    private func moreButton(_ title: String, hint: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.title3).foregroundStyle(FBTheme.green)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.bold()).foregroundStyle(.white)
                    Text(hint).font(.caption2).foregroundStyle(FBTheme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(FBTheme.textSecondary)
            }.fbCard()
        }.buttonStyle(.plain)
    }
    private func emptyCard(_ title: String, hint: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 38)).foregroundStyle(FBTheme.green)
            Text(title).font(.headline)
            Text(hint).font(.footnote).foregroundStyle(FBTheme.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28).fbCard()
    }
    private func pageTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 30, weight: .bold, design: .rounded))
            Text(subtitle).font(.subheadline).foregroundStyle(FBTheme.textSecondary)
        }
    }
}