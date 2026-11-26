import SwiftUI
import MapKit
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
    @State private var measurementMode: MeasurementKind?
    @State private var measurementPoints: [GeoPoint] = []
    @State private var measurementMoveIndex: Int?
    @State private var profileTrack: Track?
    @State private var editingTrack: Track?
    @State private var measurementArchive = MeasurementArchive()
    @StateObject private var animals = WildlifeStore()
    @StateObject private var connectivity = WeatherConnectivity()
    @StateObject private var weather = WeatherService()
    @StateObject private var observations = ObservationStore()
    @StateObject private var weatherGrid = WeatherGridService()
    @State private var didPrefetchWeather = false
    @State private var didCleanExports = false

    @AppStorage("hunt.onlineBasemap") private var online = true
    @AppStorage("hunt.navigation.courseUp") private var courseUp = false
    @State private var showReturnPoints = false
    @State private var returnPointMessage = ""
    @State private var azimuthMode = false
    @AppStorage("hunt.map.style") private var mapStyle = MapBasemap.protomaps.rawValue
    private var hasMapTilerKey: Bool { MapTilerConfiguration.isConfigured }

    @State private var tab: Tab = .home
    @State private var dataSection: DataSection = .routes
    @State private var serviceSection: ServiceSection = .weather
    @State private var forecastPoint: GeoPoint?
    @State private var forecastTitle = "Текущая GPS-позиция"
    @State private var pickingForecastPoint = false
    @State private var pointDestination: ServiceSection = .weather
    @State private var weatherLayer: WeatherMapLayer = .none
    @State private var zone: GeoZone?
    @State private var highlightedGroundID: String?
    @State private var groundFitRequest = 0
    @State private var showLayers = false
    @State private var showSettings = false
    @State private var showWeather = false
    @State private var showWeatherLayers = false
    @State private var showAbout = false
    @State private var showOfflineManager = false
    @State private var showFieldMode = false
    @State private var showEmergency = false
    @State private var showLegalLibrary = false
    @State private var showDiagnostics = false
    @State private var showGBIF = false
    @State private var showSearch = false
    @State private var searchText = ""
    @State private var addressOrigin: AddressHit?
    @State private var addressDestination: AddressHit?
    @State private var plannedOrigin: GeoPoint?
    @State private var addressResults: [AddressHit] = []
    @State private var addressIndex = OfflineAddressIndex()
    @State private var importingAddressIndex = false
    @State private var addressIndexReady = false
    @State private var addressIndexStatus = ""
    @State private var addressRequest: UUID?
    @State private var addressLoading = false
    @State private var addressMessage = ""
    @AppStorage("hunt.address.history.v1") private var addressHistoryJSON = "[]"
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
    @State private var trackedRecordedGuidance = false
    @State private var returnStatus = ""
    @State private var returnArrived = false
    @State private var travelMode: OfflineRouteGraph.TravelMode = .foot
    @State private var valhallaManeuvers: [ValhallaManeuver] = []
    @State private var nextTurnText = ""
    @State private var nextTurnDistance = 0.0
    @AppStorage("hunt.navigation.voice") private var routeVoiceEnabled = true
    @State private var routeCumulative: [Double] = []
    @State private var routeRemainingMeters = 0.0
    @State private var routeDurationSeconds: Double?
    @State private var announcedManeuver = -1
    @State private var announcedStage = 0
    @State private var recordedAverageSpeed = 4.5
    @State private var routingError: String?
    @State private var importingRoutingNetwork = false
    @State private var legacyRouteTask: Task<Void, Never>?
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
    private enum DataSection: String, CaseIterable { case routes = "Маршруты", markers = "Метки", grounds = "Угодья" }
    private enum ServiceSection: String, CaseIterable { case weather = "Погода", astronomy = "Астрономия", wildlife = "Животные" }

    var body: some View { featurePresentation }

    private var immersiveNavigation: Bool { tab == .map && (routeGuidance || recordedRouteFollowing) }

    private var rootLayout: some View {
        ZStack {
            // Do not allocate the native map during cold launch.
            if tab == .map && !startupSync.presented { mapScreen }
            if tab != .map { themedScreen }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) { if !immersiveNavigation { navigation } }
        .accessibilityHidden(startupSync.presented || showFieldMode || showEmergency)
        .allowsHitTesting(!startupSync.presented && !showFieldMode && !showEmergency)
        .overlay {
            if startupSync.presented {
                StartupSyncScreen(sync: startupSync, hosting: hosting, protomaps: protomaps)
                    .transition(.opacity)
                    .accessibilityAddTraits(.isModal)
            }
        }
        .overlay {
            if !startupSync.presented && (showFieldMode || showEmergency) {
                fieldFeatureOverlay
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(HuntReference.background.ignoresSafeArea())
                    .zIndex(10)
            }
        }
        .background(HuntReference.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(HuntReference.green)
        .environment(\.locale, Locale(identifier: "ru_KZ"))
        .background(ShakeDetector().frame(width: 1, height: 1))
    }

    private var lifecycleLayout: some View {
        AnyView(rootLayout)
        .onReceive(NotificationCenter.default.publisher(for: .huntShake)) { _ in showDiagnostics = true }
        .onAppear {
            HuntPerformance.shared.start()
            model.setForegroundGPS(scenePhase == .active)
            startupSync.begin(hosting: hosting, tiles: maps, protomaps: protomaps,
                              model: model, valhalla: valhalla)
        }
        .task(id: startupSync.presented) {
            // Keep the startup contract: prefetch only after the launch gate releases.
            guard !startupSync.presented, !didPrefetchWeather else { return }
            HuntPerformance.shared.markReady()
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled, !startupSync.presented, !didPrefetchWeather else { return }
            didPrefetchWeather = true
            if weatherLayer == .none { weatherGrid.load(hourOffset: 0) }
            if !didCleanExports {
                didCleanExports = true
                let directory = FileManager.default.temporaryDirectory
                do { _ = try await HuntBackgroundWork.run { try TrackExportCleanup.removeExpired(in: directory) } }
                catch is CancellationError { }
                catch { AppDiagnosticLog.shared.recordError(subsystem: "Хранилище", operation: "Очистка старых GPX", error: error) }
            }
        }
        .onChange(of: tab) { _, value in
            if value == .services { refreshWeatherOnLaunch() }
            if value == .map { nativePacks.restore() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { HuntPerformance.shared.start() } else { HuntPerformance.shared.stop() }
            model.setForegroundGPS(phase == .active)
            if phase == .active && tab == .services { refreshWeatherOnLaunch() }
        }
        .onChange(of: connectivity.connected) { _, connected in
            if connected && tab == .services { refreshWeatherOnLaunch() }
        }
        .onChange(of: weatherLayer) { _, value in
            if value != .none { weatherGrid.load(hourOffset: weatherGrid.chosenOffset) }
        }
        .onDisappear { playbackTask?.cancel(); legacyRouteTask?.cancel() }
        .onChange(of: online) { _, enabled in if enabled { offlineRoads.clear() } }
    }

    private var guidanceLayout: some View {
        AnyView(lifecycleLayout)
        .onChange(of: model.coordinate) { _, newPoint in
            if tab == .services, forecastPoint == nil, let point = newPoint {
                weather.updateIfNeeded(latitude: point.latitude, longitude: point.longitude)
            }
            if newPoint != nil, navigationKind == "Ожидание GPS", let destination = routeDestination {
                planRoute(to: destination, title: routeTitle, markerID: navigationTargetID)
            }
            if let position = newPoint, routeGuidance, let destination = routeDestination {
                if !navigationPath.isEmpty, routeRemainingMeters <= 50,
                   (model.accuracy ?? 100) <= 50,
                   GeoMath.meters(position, destination) <= max(20, model.accuracy ?? 20) {
                    navigationKind = "Вы достигли точки назначения"
                    routeGuidance = false
                    model.stopRecordedRouteGuidance()
                    model.speakRouteInstruction("Вы прибыли.")
                    return
                }
                refreshNextTurn(at: position)
                if navigationPath.count >= 2, Date().timeIntervalSince(rerouteTime) > 45 {
                    let distance = navigationPath.map { GeoMath.meters(position, $0) }.min() ?? 0
                    if distance > 150 {
                        rerouteTime = Date()
                        planRoute(to: destination, title: routeTitle, markerID: navigationTargetID)
                    }
                }
            }
        }
        .onReceive(model.$recordedGuidanceResult) { result in
            guard let result, recordedRouteFollowing, trackedRecordedGuidance else { return }
            recordedRouteRemaining = result.remaining
            recordedRouteDeviation = result.deviation ?? 0
            returnStatus = result.status.rawValue
            if result.arrived {
                returnArrived = true
                recordedRouteFollowing = false
                navigationKind = "Конечная точка достигнута"
            }
        }
    }

        private var importLayout: some View {
        AnyView(guidanceLayout)
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

    private var mapPresentation: some View {
        AnyView(importLayout)
        .sheet(isPresented: $showLayers) { layerSheet.huntModal() }
        .sheet(isPresented: $showReturnPoints) { returnPointsSheet.huntModal() }
        .sheet(isPresented: $showSearch) { mapSearchSheet.huntModal() }
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
                .huntModal()
                .presentationDetents([.large])
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

    private var editingPresentation: some View {
        AnyView(mapPresentation)
        .sheet(item: $creatingMapMarker) { marker in
            MarkerEditor(marker: marker, isNew: true,
                         onSave: { changed in
                             model.insertMarker(changed)
                             showMarkersOnMap = true
                         },
                         onDelete: { _ in }).huntModal()
        }
        .sheet(item: $editingMarker) { marker in
            MarkerEditor(marker: marker,
                         onSave: { model.saveMarker($0) },
                         onDelete: { model.deleteMarker(id: $0) }).huntModal()
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

    private var servicePresentation: some View {
        AnyView(editingPresentation)
        .sheet(isPresented: $showWeather) {
            WeatherPanel(service: weather, coordinate: forecastPoint ?? model.coordinate, online: connectivity.connected)
                .huntModal()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showWeatherLayers) {
            WeatherMapSheet(service: weatherGrid, layer: $weatherLayer,
                            coordinate: model.coordinate, online: online,
                            onShowKazakhstan: { tab = .map; overviewCommand += 1 })
                .huntModal()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $zone) { ground in
            GroundDetailsSheet(zone: ground, model: model, onMap: { showGround($0) }, onRoute: { routeGround($0) }).huntModal()
        }
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
                            valhallaStatus: valhalla.status).huntModal()
        }
    }

    private var featurePresentation: some View {
        AnyView(servicePresentation)
        .sheet(isPresented: $showSettings) {
            HuntSettingsScreen(model: model, observations: observations,
                online: $online, grounds: $showGrounds, markers: $showMarkersOnMap,
                gps: $showGPSOnMap, track: $showTrackOnMap,
                onStorage: { showSettings = false; showOfflineManager = true },
                onDiagnostics: { showSettings = false; showDiagnostics = true })
                .huntModal()
        }
        .sheet(item: $editingTrack) { track in
            TrackEditScreen(model: model, source: track).huntModal()
        }
        .sheet(item: $profileTrack) { track in
            TrackProfileScreen(track: track, onMap: { point in
                profileTrack = nil
                showRecordedTrack(track, direction: .forward, follow: false)
                mapFocus = point
                centerRequest += 1
            }).huntModal()
        }
        .onChange(of: showOfflineManager) { _, shown in if shown { HuntPerformance.shared.markOfflineOpening() } }
        .sheet(isPresented: $showOfflineManager) {
            OfflineManagerScreen(hosting: hosting, tiles: maps, protomaps: protomaps, valhalla: valhalla,
                startupBusy: startupSync.presented || startupSync.isDownloading, onCancelStartup: { startupSync.skip() })
                .huntModal()
        }
        .sheet(isPresented: $showAbout) { AboutHuntView().huntModal() }
        .sheet(isPresented: $showLegalLibrary) { LegalLibraryView().huntModal() }
    }

    @ViewBuilder
    private var fieldFeatureOverlay: some View {
        if showEmergency {
            EmergencyScreen(model: model, onClose: { showEmergency = false })
        } else if showFieldMode {
            FieldModeScreen(model: model, onReturn: { track in
                showFieldMode = false
                beginFieldReturn(track)
            }, onClose: { showFieldMode = false })
        }
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
            .padding(.bottom, 18)
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
        .background(HuntReference.background.ignoresSafeArea(edges: .bottom))
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
                    Text("QAZ TRAIL").font(.system(size: 19, weight: .bold))
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
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 12) {
                Button { dataSection = .grounds; tab = .data } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "map.fill").font(.title2.bold())
                            .foregroundStyle(HuntReference.green)
                            .frame(width: 48, height: 48)
                            .background(HuntReference.green.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Охотугодья").font(.headline.bold()).foregroundStyle(.white)
                            Text("\(model.zones.count) территорий · каталог офлайн")
                                .font(.caption).foregroundStyle(HuntReference.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(HuntReference.green)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityIdentifier("grounds_home")
                Text(model.groundMonitorStatus).font(.caption).foregroundStyle(HuntReference.muted)
                HStack(spacing: 8) {
                    HuntAction(title: "Каталог", symbol: "list.bullet", primary: true) { dataSection = .grounds; tab = .data }
                    HuntAction(title: "Карта", symbol: "map") { showGrounds = true; tab = .map }
                }
            }.huntSurface()
            VStack(alignment: .leading, spacing: 12) {
                Button { showFieldMode = true } label: {
                    HuntRow(title: "Полевой режим", subtitle: model.recording ? "Запись маршрута активна" : "Компас · GPS · Маршрут", symbol: "location.north.circle")
                }.buttonStyle(.plain).contentShape(Rectangle()).accessibilityIdentifier("field_mode_home")
                HuntAction(title: "Экстренная помощь", symbol: "cross.case") { showEmergency = true }
                    .accessibilityIdentifier("sos_home")
            }
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
                ReferenceActionCard(title: "Карта", subtitle: "Открыть карту", symbol: "map") { tab = .map }
                ReferenceActionCard(title: "Офлайн-карты", subtitle: "Пакеты и загрузки", symbol: "checkmark.icloud") { showOfflineManager = true }
                ReferenceActionCard(title: "Мои маршруты", subtitle: "Треки и GPX", symbol: "mappin.and.ellipse") { dataSection = .routes; tab = .data }
                ReferenceActionCard(title: "Метки", subtitle: "Сохранённые точки", symbol: "mappin.circle") { dataSection = .markers; tab = .data }
                ReferenceActionCard(title: "Погода", subtitle: "Прогноз и карта", symbol: "cloud.sun") { serviceSection = .weather; tab = .services }
                ReferenceActionCard(title: "Животные", subtitle: "Справочник", symbol: "pawprint") { serviceSection = .wildlife; tab = .services }
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
                           groundRevision: model.groundGeometryRevision,
                           position: (showGPSOnMap || model.recording || routeGuidance || recordedRouteFollowing) ? model.coordinate : nil,
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
                           online: online, selectedZone: $zone,
                           weatherGrid: tab == .map && weatherLayer != .none ? weatherGrid.grid : nil,
                           weatherLayer: tab == .map ? weatherLayer : .none,
                           followsGPS: (model.recording && !model.paused) || routeGuidance || recordedRouteFollowing,
                           followPosition: model.fieldFixTime.map { Date().timeIntervalSince($0) < 30 && Date().timeIntervalSince($0) >= -5 } == true ? model.coordinate : nil,
                           followFixTime: model.fieldFixTime,
                           courseUp: courseUp,
                           gpsCourse: (model.fieldSpeed ?? 0) >= 3.6 ? model.fieldCourse : nil,
                           centerRequest: centerRequest,
                           zoomCommand: zoomCommand,
                           overviewCommand: overviewCommand,
                           focusCoordinate: mapFocus,
                           highlightedGroundID: highlightedGroundID,
                           groundFitRequest: groundFitRequest,
                           measurementPoints: measurementMode == nil ? [] : measurementPoints,
                           measurementClosed: measurementMode == .area,
                           measurementActive: measurementMode != nil,
                           onMapTap: { point in
                               guard !immersiveNavigation else { return }
                               if pickingForecastPoint {
                                   selectForecastPoint(point, title: "Точка на карте", destination: pointDestination)
                                   return
                               }
                               if measurementMode != nil {
                                   if let index = measurementMoveIndex, measurementPoints.indices.contains(index) {
                                       measurementPoints[index] = point
                                       measurementMoveIndex = nil
                                   } else if measurementPoints.count < 500 {
                                       measurementPoints.append(point)
                                   }
                                   return
                               }
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
                                   if showGrounds, let ground = pendingMapZone {
                                       highlightedGroundID = ground.id
                                       zone = ground
                                   } else {
                                       highlightedGroundID = nil
                                       showMapPointActions = true
                                   }
                               }
                           },
                           onMarkerTap: { id in
                               guard !immersiveNavigation else { return }
                               if movingMarkerID == nil {
                                   selectedMapMarker = MapMarkerSelection(id: id)
                               }
                           },
                           onViewportChanged: { bounds in
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

            if immersiveNavigation {
                immersiveGuidanceOverlay
            } else {
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Button { showSearch = true } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "magnifyingglass")
                            Text("Поиск адресов, мест и точек")
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
                    VStack(spacing: 7) {
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
                        circleMapButton(courseUp ? "location.north.line.fill" : "location.north", label: courseUp ? "По курсу" : "Север сверху") {
                            courseUp.toggle()
                        }
                        circleMapButton("mappin.and.ellipse", label: "Автомобиль и лагерь") { showReturnPoints = true }
                        circleMapButton("plus", label: "Приблизить") { zoomCommand += 1 }
                        circleMapButton("minus", label: "Отдалить") { zoomCommand -= 1 }
                    }
                }
                .padding(.top, 10)
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
                if pickingForecastPoint {
                    HStack {
                        Text("Выберите точку на карте").font(.caption.bold())
                        Spacer()
                        Button("Отмена") { pickingForecastPoint = false; tab = .services }
                    }.huntSurface().padding(.horizontal, 12)
                }
                if let kind = measurementMode {
                    MeasurementPanel(kind: kind, points: $measurementPoints, moveIndex: $measurementMoveIndex,
                        archive: measurementArchive, boundaryDistance: measurementBoundaryDistance,
                        onClose: { measurementMode = nil; measurementMoveIndex = nil })
                        .padding(.horizontal, 12).padding(.bottom, 8)
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
                if measurementMode == nil, routeDestination == nil, recordedRoute == nil, showGrounds, let ground = model.zones.first(where: { $0.id == highlightedGroundID }) {
                    selectedGroundBanner(ground)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
                if measurementMode == nil, routeDestination == nil, recordedRoute == nil, weatherLayer != .none {
                    Button { showWeatherLayers = true } label: {
                        Label("\(weatherLayer.rawValue) · \(weatherGrid.forecastLabel)", systemImage: "cloud.fill")
                            .font(.caption.bold())
                            .foregroundStyle(HuntReference.green)
                            .padding(10)
                            .background(HuntReference.card.opacity(0.94), in: Capsule())
                    }
                    .padding(.bottom, 8)
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
                    Menu {
                        ForEach(MeasurementKind.allCases, id: \.self) { kind in
                            Button(kind.rawValue) {
                                measurementPoints = []
                                measurementMoveIndex = nil
                                movingMarkerID = nil
                                measurementMode = kind
                            }
                        }
                    } label: {
                        Label("Измерить", systemImage: "ruler").font(.caption.bold())
                            .foregroundStyle(HuntReference.green)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 12))
                    }.accessibilityIdentifier("map_measure")
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
                .padding(.bottom, 12)
            }
            }
        }
    }

    private var immersiveGuidanceOverlay: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: recordedRouteFollowing ? "figure.walk.motion" : "location.north.line.fill")
                    .font(.title2).foregroundStyle(HuntReference.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text(recordedRouteFollowing ? "По записанному треку" : (nextTurnText.isEmpty ? "Следуйте маршруту" : nextTurnText))
                        .font(.headline).lineLimit(2)
                    if !recordedRouteFollowing && !valhallaManeuvers.isEmpty && !nextTurnText.isEmpty {
                        Text(String(format: "Манёвр через %.0f м", nextTurnDistance)).font(.caption.monospacedDigit())
                    }
                }
                Spacer(minLength: 0)
                Button {
                    routeVoiceEnabled.toggle()
                    if !routeVoiceEnabled { model.silenceRouteVoice() }
                    else if !recordedRouteFollowing { model.speakRouteInstruction(nextTurnText.isEmpty ? "Голосовые подсказки включены" : nextTurnText) }
                } label: {
                    Image(systemName: routeVoiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.title3).padding(8)
                }.accessibilityLabel(routeVoiceEnabled ? "Выключить голос" : "Включить голос")
            }.padding(12).background(HuntReference.card.opacity(0.97), in: RoundedRectangle(cornerRadius: 14))
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    circleMapButton("location.fill", label: "Моё местоположение") { mapFocus = nil; model.requestGPS(); centerRequest += 1 }
                    circleMapButton(courseUp ? "location.north.line.fill" : "location.north", label: "Ориентация карты") { courseUp.toggle() }
                    circleMapButton("plus", label: "Приблизить") { zoomCommand += 1 }
                    circleMapButton("minus", label: "Отдалить") { zoomCommand -= 1 }
                }
            }
            Spacer(minLength: 0)
            TimelineView(.periodic(from: .now, by: 1)) { clock in
                let fresh = model.fieldFixTime.map { clock.date.timeIntervalSince($0) >= -5 && clock.date.timeIntervalSince($0) < 30 } ?? false
                VStack(alignment: .leading, spacing: 6) {
                    if !fresh { Text("Ожидание свежей GPS-позиции").foregroundStyle(.orange).font(.caption.bold()) }
                    if recordedRouteFollowing {
                        Text(returnStatus).font(.caption.bold()).foregroundStyle(.orange)
                        Text(String(format: "По треку: %.2f км", recordedRouteRemaining / 1000)).font(.headline.monospacedDigit())
                    } else { Text(routeTitle).font(.headline).lineLimit(1) }
                    routeETA(at: clock.date)
                    HStack {
                        if fresh, let speed = model.fieldSpeed, speed.isFinite, speed >= 0 {
                            Text(String(format: "%.0f км/ч", speed)).font(.caption.monospacedDigit())
                        }
                        Spacer()
                        if model.recording {
                            Button { model.togglePause() } label: { Label(model.paused ? "Продолжить" : "Пауза", systemImage: model.paused ? "play.fill" : "record.circle.fill") }.font(.caption.bold())
                        }
                        Button("Завершить") {
                            if recordedRouteFollowing { stopRecordedTrack() } else { stopNavigation() }
                        }.buttonStyle(.bordered).accessibilityIdentifier(recordedRouteFollowing ? "recorded_track_stop" : "route_stop_guidance")
                    }
                }.padding(12).background(HuntReference.card.opacity(0.97), in: RoundedRectangle(cornerRadius: 14))
            }
        }.foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 8)
        .accessibilityIdentifier("immersive_guidance")
    }

    private var measurementBoundaryDistance: Double? {
        guard let point = measurementPoints.last ?? model.coordinate,
              let ground = model.zones.first(where: { $0.id == highlightedGroundID }) else { return nil }
        return ground.distanceToBoundaryMeters(point)
    }

    // MARK: - In-app offline guidance / routing
    private var routingNetworkURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("routing/network.geojson")
    }

    private func startNavigation(to id: UUID) {
        guard let marker = model.markers.first(where: { $0.id == id }) else { return }
        if routeGuidance { model.stopRecordedRouteGuidance() }
        routeGuidance = false
        planRoute(to: marker.coordinate, title: marker.title, markerID: id)
    }
    private func planRoute(to destination: GeoPoint, title: String, markerID: UUID? = nil, origin: GeoPoint? = nil) {
        plannedOrigin = origin
        azimuthMode = false
        legacyRouteTask?.cancel()
        routeRequestID = nil
        if recordedRoute != nil { stopRecordedTrack() }
        if !routeGuidance { navigationPath = [] }
        routeDestination = destination
        routeTitle = title
        navigationTargetID = markerID
        routeCumulative = []
        routeRemainingMeters = 0
        routeDurationSeconds = nil
        announcedManeuver = -1
        announcedStage = 0
        valhallaManeuvers = []
        nextTurnText = ""
        tab = .map
        guard let current = origin ?? model.coordinate else {
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
                    prepareRouteEstimate(path: result.path, duration: result.durationSeconds)
                    refreshNextTurn(at: plannedOrigin ?? model.coordinate ?? current)
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
        navigationKind = "Локальный граф · расчёт…"
        let requestID = routeRequestID
        let localURL = routingNetworkURL
        legacyRouteTask?.cancel()
        legacyRouteTask = Task {
            do {
                let graph: OfflineRouteGraph
                do {
                    graph = try await hosting.graph(start: current, destination: destination, mode: mode)
                } catch {
                    try Task.checkCancellation()
                    guard FileManager.default.fileExists(atPath: localURL.path) else {
                        throw error
                    }
                    graph = try await HuntBackgroundWork.run {
                        try OfflineRouteGraph(geoJSON: Data(contentsOf: localURL), mode: mode)
                    }
                }
                let route = try await HuntBackgroundWork.run { try graph.path(from: current, to: destination) }
                guard !Task.isCancelled, routeRequestID == requestID, routeDestination == destination else { return }
                guard route.count >= 2 else { throw OfflineRouteGraph.RouteError.disconnected }
                routeGraphCount = graph.count
                navigationPath = route
                prepareRouteEstimate(path: route, duration: nil)
                refreshNextTurn(at: plannedOrigin ?? model.coordinate ?? current)
                navigationKind = mode == .foot ? "Локальный граф · пешком" : "Локальный граф · автомобиль"
                routingError = nil
            } catch {
                guard !Task.isCancelled, routeRequestID == requestID, routeDestination == destination else { return }
                navigationPath = []
                navigationKind = "Маршрут недоступен"
                AppDiagnosticLog.shared.recordError(subsystem: "Навигация",
                    operation: "Резервный локальный граф", error: error,
                    usedCache: !hosting.installedRoutes.isEmpty)
                routingError = (valhallaError.map { "Valhalla: \($0). " } ?? "") + error.localizedDescription
            }
        }
    }

    private func prepareRouteEstimate(path: [GeoPoint], duration: Double?) {
        var cumulative = [0.0]
        for (a, b) in zip(path, path.dropFirst()) {
            cumulative.append(cumulative.last! + GeoMath.meters(a, b))
        }
        routeCumulative = cumulative
        routeRemainingMeters = cumulative.last ?? 0
        routeDurationSeconds = duration
    }

    private var remainingTravelSeconds: Double? {
        if recordedRouteFollowing {
            return recordedRouteRemaining / max(1, recordedAverageSpeed) * 3.6
        }
        guard let total = routeCumulative.last, total > 0 else { return nil }
        if let duration = routeDurationSeconds {
            return duration * min(1, max(0, routeRemainingMeters / total))
        }
        return routeRemainingMeters / (travelMode == .foot ? 4.5 : 40) * 3.6
    }

    private func travelTimeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 31_536_000 else { return "—" }
        let minutes = Int(ceil(seconds / 60))
        return minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) мин" : "\(minutes) мин"
    }

    private func routeETA(at date: Date) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(remainingTravelSeconds.map { travelTimeText($0) } ?? "—")
                    .font(.title2.bold()).monospacedDigit()
                Text("Осталось").font(.caption2)
            }
            Spacer(minLength: 4)
            VStack(alignment: .center, spacing: 2) {
                Text(String(format: "%.1f км", (recordedRouteFollowing ? recordedRouteRemaining : routeRemainingMeters) / 1000))
                    .font(.headline.monospacedDigit())
                Text("По маршруту").font(.caption2)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                if let seconds = remainingTravelSeconds {
                    Text(date.addingTimeInterval(seconds), format: .dateTime.hour().minute())
                        .font(.headline.monospacedDigit())
                } else { Text("—").font(.headline) }
                Text("Прибытие ≈").font(.caption2)
            }
        }.accessibilityIdentifier("route_eta")
    }

    private func refreshNextTurn(at location: GeoPoint) {
        guard navigationPath.count >= 2, routeCumulative.count == navigationPath.count,
              let total = routeCumulative.last else { return }
        let longitudeScale = cos(location.latitude * .pi / 180)
        var best = Double.infinity
        var progress = 0.0
        for index in 1..<navigationPath.count {
            let a = navigationPath[index - 1], b = navigationPath[index]
            let x = (a.longitude - location.longitude) * longitudeScale
            let y = a.latitude - location.latitude
            let dx = (b.longitude - a.longitude) * longitudeScale
            let dy = b.latitude - a.latitude
            let denominator = dx * dx + dy * dy
            let fraction = denominator > 0 ? min(1, max(0, -(x * dx + y * dy) / denominator)) : 0
            let distance = pow(x + fraction * dx, 2) + pow(y + fraction * dy, 2)
            if distance < best {
                best = distance
                progress = routeCumulative[index - 1] + fraction * (routeCumulative[index] - routeCumulative[index - 1])
            }
        }
        routeRemainingMeters = max(0, total - progress)
        let valid = valhallaManeuvers.filter { routeCumulative.indices.contains($0.beginIndex) }
        guard let upcoming = valid.first(where: { routeCumulative[$0.beginIndex] >= progress - 5 && $0.beginIndex > 0 }) ?? valid.last else {
            nextTurnText = "Следуйте по линии маршрута"
            nextTurnDistance = 0
            return
        }
        nextTurnText = upcoming.instruction
        nextTurnDistance = max(0, routeCumulative[upcoming.beginIndex] - progress)
        guard routeGuidance, routeVoiceEnabled else { return }
        if announcedManeuver != upcoming.beginIndex {
            announcedManeuver = upcoming.beginIndex
            announcedStage = 0
        }
        let near = travelMode == .car ? 50.0 : 20.0
        let far = travelMode == .car ? 300.0 : 100.0
        let stage = nextTurnDistance <= near ? 2 : (nextTurnDistance <= far ? 1 : 0)
        guard stage > announcedStage else { return }
        announcedStage = stage
        if upcoming.isDestination {
            if stage == 1 { model.speakRouteInstruction("Вы приближаетесь к точке назначения") }
            return
        }
        let meters = max(10, Int((nextTurnDistance / 10).rounded()) * 10)
        let prefix = stage == 2 ? "" : "Через \(meters) метров, "
        let command = stage == 2 ? upcoming.instruction : upcoming.instruction.prefix(1).lowercased() + upcoming.instruction.dropFirst()
        model.speakRouteInstruction(prefix + command)
    }

    private func stopNavigation() {
        plannedOrigin = nil
        azimuthMode = false
        legacyRouteTask?.cancel()
        valhallaManeuvers = []
        nextTurnText = ""
        routeCumulative = []
        routeDurationSeconds = nil
        routeRemainingMeters = 0
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

    private func beginFieldReturn(_ track: Track) {
        guard !track.hasDiscontinuity, TrackReturnTracker(points: Array(track.fixes.map(\.point).reversed())) != nil else {
            routingError = "Маршрут содержит разрывы или недостаточно валидных точек"
            return
        }
        showRecordedTrack(track, direction: .backward, follow: true)
        if trackedRecordedGuidance { navigationKind = "Возвращение по записанному треку" }
    }

    private func showRecordedTrack(_ track: Track, direction: RecordedRouteDirection, follow: Bool) {
        guard let route = RecordedTrackFollow(track: track, direction: direction) else {
            routingError = "В записи меньше двух GPS-точек. Маршрут нельзя воспроизвести."
            return
        }
        if follow && (track.hasDiscontinuity || TrackReturnTracker(points: route.points) == nil) {
            routingError = "Маршрут с разрывами или недостаточной длиной нельзя использовать для ведения"
            return
        }
        playbackTask?.cancel()
        recordedRoutePlay = false
        model.stopRecordedRouteGuidance()
        routeRequestID = nil
        navigationTargetID = nil
        routeDestination = nil
        routeGuidance = false
        trackedRecordedGuidance = false
        returnStatus = ""
        returnArrived = false
        selectedRecordedTrackID = track.id
        recordedRoute = route
        recordedRoutePreviewIndex = 0
        recordedRouteProgress = 0
        recordedRouteRemaining = route.remainingFrom[0]
        let recordedSpeed = track.durationSeconds > 0 ? recordedRouteRemaining / track.durationSeconds * 3.6 : 4.5
        recordedAverageSpeed = recordedSpeed.isFinite && recordedSpeed >= 1 ? recordedSpeed : 4.5
        recordedRouteDeviation = 0
        recordedRouteFollowing = follow
        navigationPath = route.points
        navigationKind = follow ? "Повторное прохождение · \(direction.rawValue)" : "Просмотр записи · \(direction.rawValue)"
        tab = .map
        mapFocus = route.points[0]
        centerRequest += 1
        if follow {
            trackedRecordedGuidance = model.beginRecordedGuidance(points: route.points)
            recordedRouteFollowing = trackedRecordedGuidance
            returnStatus = "Ожидание свежей GPS-позиции"
        }
    }

    private func stopRecordedTrack() {
        trackedRecordedGuidance = false
        returnStatus = ""
        returnArrived = false
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
                if returnArrived {
                    Text("Возвращение завершено. Запись маршрута можно завершить отдельно.")
                        .font(.caption).foregroundStyle(HuntReference.green)
                } else if trackedRecordedGuidance && recordedRouteFollowing {
                    TimelineView(.periodic(from: .now, by: 1)) { clock in
                        let stale = model.fieldFixTime.map { clock.date.timeIntervalSince($0) >= 30 } ?? true
                        VStack(alignment: .leading, spacing: 6) {
                            Text(stale ? "GPS устарел — движение не подтверждено" : returnStatus)
                                .font(.caption.bold()).foregroundStyle(.orange)
                            Text(String(format: "Осталось по треку: %.2f км", recordedRouteRemaining / 1000))
                                .font(.caption.monospacedDigit())
                            Text("Следуйте записанному пути. Не пересекайте препятствия по прямой.")
                                .font(.caption).foregroundStyle(HuntReference.muted)
                            HuntAction(title: "Остановить возвращение", symbol: "stop.fill") { stopRecordedTrack() }
                        }
                    }
                } else if recordedRouteFollowing {
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
                            guard let track = ([model.currentTrack].compactMap { $0 } + model.tracks).first(where: { $0.id == route.trackID }),
                                  !track.hasDiscontinuity else {
                                routingError = "Маршрут содержит разрывы или недоступен"
                                return
                            }
                            trackedRecordedGuidance = model.beginRecordedGuidance(points: route.points)
                            recordedRouteFollowing = trackedRecordedGuidance
                            recordedRouteProgress = 0
                            returnArrived = false
                            returnStatus = "Ожидание свежей GPS-позиции"
                            if !trackedRecordedGuidance { routingError = "Недостаточная длина маршрута"; return }
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

    private var returnPointsSheet: some View {
        NavigationStack {
            List {
                Section("Сохранить текущую GPS-позицию") {
                    ForEach(["Автомобиль", "Лагерь"], id: \.self) { kind in
                        Button("Сохранить: " + kind) {
                            guard let point = model.coordinate, let time = model.fieldFixTime,
                                  Date().timeIntervalSince(time) >= -5, Date().timeIntervalSince(time) < 30,
                                  let accuracy = model.accuracy, accuracy >= 0, accuracy <= 30 else {
                                returnPointMessage = "Нужна свежая GPS-позиция с точностью до 30 м."
                                model.requestGPS()
                                return
                            }
                            model.addMarker(at: point, kind: kind)
                            returnPointMessage = "Точка добавлена в список меток."
                        }
                    }
                    if !returnPointMessage.isEmpty { Text(returnPointMessage).font(.caption) }
                }
                Section("Возвращение к сохранённой точке") {
                    ForEach(model.markers.filter { $0.kind == "Автомобиль" || $0.kind == "Лагерь" }) { marker in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(marker.title).font(.headline)
                            Button("По дорогам") {
                                showReturnPoints = false
                                planRoute(to: marker.coordinate, title: marker.title, markerID: marker.id)
                            }
                            Button("По азимуту") {
                                showReturnPoints = false
                                beginAzimuth(to: marker.coordinate, title: marker.title, markerID: marker.id)
                            }
                        }
                    }
                }
                Text("Азимут показывает направление по прямой, а не безопасный проходимый маршрут. Учитывайте препятствия и границы.").font(.caption)
            }
            .navigationTitle("Точки возвращения")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { showReturnPoints = false } } }
        }
    }

    private func beginAzimuth(to destination: GeoPoint, title: String, markerID: UUID?) {
        stopNavigation()
        if recordedRoute != nil { stopRecordedTrack() }
        azimuthMode = true
        routeDestination = destination
        routeTitle = title
        navigationTargetID = markerID
        navigationKind = "Азимут · направление по прямой"
        navigationPath = []
        tab = .map
        model.requestGPS()
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
                if azimuthMode {
                    Text("АЗИМУТ · НЕ ДОРОЖНЫЙ МАРШРУТ").font(.caption.bold()).foregroundStyle(.orange)
                    if let current = model.coordinate, let time = model.fieldFixTime,
                       Date().timeIntervalSince(time) >= -5, Date().timeIntervalSince(time) < 30,
                       let accuracy = model.accuracy, accuracy >= 0, accuracy <= 50 {
                        let distance = GeoMath.meters(current, destination)
                        Text(String(format: "%.0f м · %d° от севера", distance, bearing(to: destination, from: current)))
                            .font(.title2.monospacedDigit().bold())
                        if distance <= 15 && accuracy <= 10 {
                            Text("Вы рядом с сохранённой точкой").font(.caption)
                        }
                    } else { Text("Ожидание точной GPS-позиции").font(.caption) }
                    Text("Не пересекайте препятствия по прямой.").font(.caption)
                    Button("Завершить") { stopNavigation() }.buttonStyle(.bordered)
                } else {
                HStack(spacing: 9) {
                    Button {
                        travelMode = .car
                        if routeGuidance { model.stopRecordedRouteGuidance() }
                        routeGuidance = false
                        planRoute(to: destination, title: routeTitle, markerID: navigationTargetID, origin: plannedOrigin)
                    } label: {
                        Label("Авто", systemImage: "car.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(travelMode == .car ? HuntReference.green.opacity(0.3) : Color.white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 11))
                    }.accessibilityIdentifier("route_drive")
                    Button {
                        travelMode = .foot
                        if routeGuidance { model.stopRecordedRouteGuidance() }
                        routeGuidance = false
                        planRoute(to: destination, title: routeTitle, markerID: navigationTargetID, origin: plannedOrigin)
                    } label: {
                        Label("Пешком", systemImage: "figure.walk")
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(travelMode == .foot ? HuntReference.green.opacity(0.3) : Color.white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 11))
                    }.accessibilityIdentifier("route_walk")
                }.buttonStyle(.plain).font(.caption.bold())
                Text(navigationKind).font(.caption)
                    .foregroundStyle(navigationPath.isEmpty ? Color.orange : Color.gray)
                if let current = plannedOrigin ?? model.coordinate {
                    let distance = GeoMath.meters(current, destination)
                    Text(String(format: "По прямой: %.0f м · Азимут %d°",
                                distance, bearing(to: destination, from: current)))
                        .font(.caption.monospacedDigit())
                }
                if !routeCumulative.isEmpty { routeETA(at: Date()) }
                if routeGuidance {
                    Label("Ведение включено", systemImage: "location.north.line.fill")
                        .font(.caption.bold()).foregroundStyle(HuntReference.green)
                    if !nextTurnText.isEmpty {
                        Text(nextTurnText).font(.subheadline.bold())
                        if !valhallaManeuvers.isEmpty {
                            Text(String(format: "Следующий манёвр через %.0f м", nextTurnDistance))
                                .font(.caption.monospacedDigit())
                        }
                    }
                    Button("Завершить") { stopNavigation() }.buttonStyle(.bordered)
                } else {
                    if plannedOrigin != nil {
                        Text("Предварительный маршрут между адресами. Для ведения пересчитайте от GPS.").font(.caption)
                    }
                    Button {
                        if plannedOrigin != nil {
                            planRoute(to: destination, title: routeTitle, markerID: navigationTargetID)
                            return
                        }
                        routeGuidance = true
                        rerouteTime = Date()
                        model.startRecordedRouteGuidance()
                        if let position = model.coordinate { refreshNextTurn(at: position) }
                        if announcedStage == 0 {
                            model.speakRouteInstruction(valhallaManeuvers.first?.instruction ?? "Следуйте по линии маршрута.")
                        }
                    } label: {
                        Label(plannedOrigin == nil ? "В путь" : "Маршрут от GPS", systemImage: "location.north.line.fill")
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
                Button("Показать азимут вместо маршрута") {
                    beginAzimuth(to: destination, title: routeTitle, markerID: navigationTargetID)
                }.font(.caption)
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

    private struct AddressHit: Codable, Identifiable {
        let title: String
        let address: String
        let latitude: Double
        let longitude: Double
        var house: String? = nil
        var id: String { "\(latitude),\(longitude),\(title)" }
        var point: GeoPoint { GeoPoint(latitude, longitude) }
    }

    private var addressHistory: [AddressHit] {
        (try? JSONDecoder().decode([AddressHit].self, from: Data(addressHistoryJSON.utf8))) ?? []
    }

    // Preserve fractional numbers and suffixes, including Cyrillic/Latin equivalents.
    private func normalizedHouse(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "а", with: "a")
            .replacingOccurrences(of: "б", with: "b")
            .replacingOccurrences(of: "в", with: "v")
            .replacingOccurrences(of: "с", with: "c")
            .replacingOccurrences(of: " ", with: "")
    }

    private func houseNumber(_ query: String) -> String? {
        let pattern = #"(?<![\p{L}\d])\d+[\p{L}]?(?:\s*[/\-]\s*\d+[\p{L}]?)?(?![\p{L}\d])"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: query, range: NSRange(query.startIndex..., in: query)).last,
              let range = Range(match.range, in: query) else { return nil }
        return normalizedHouse(String(query[range]))
    }

    private func addressWords(_ value: String) -> [String] {
        value.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "." })
            .map(String.init).filter { !["ул", "улица", "пр", "проспект", "д", "дом", "г", "город"].contains($0) }
    }

    private var cachedAddressMatches: [AddressHit] {
        let number = houseNumber(searchText)
        let words = addressWords(searchText).filter { !$0.contains(where: \.isNumber) }
        return Array(addressHistory.filter { hit in
            let text = hit.title + " " + hit.address
            guard words.allSatisfy({ text.localizedCaseInsensitiveContains($0) }) else { return false }
            guard let number else { return true }
            // Old cached records lack structured house numbers; do not treat them as exact.
            return hit.house == number
        }.prefix(20))
    }

    private func rememberAddresses(_ hits: [AddressHit]) {
        var seen = Set<String>()
        let unique = Array((hits + addressHistory).filter { seen.insert($0.id).inserted }.prefix(100))
        if let data = try? JSONEncoder().encode(unique),
           let json = String(data: data, encoding: .utf8) { addressHistoryJSON = json }
    }

    @MainActor
    private func findAddresses(_ query: String, requestID: UUID) async {
        addressLoading = true
        addressResults = []
        addressMessage = ""
        defer { if addressRequest == requestID { addressLoading = false } }
        let number = houseNumber(query)
        let local: [OfflineAddressIndex.Hit]
        do {
            local = try await addressIndex.search(words: addressWords(query).filter { !$0.contains(where: \.isNumber) }, house: number)
        } catch {
            local = []
            addressIndexStatus = error.localizedDescription
        }
        guard !Task.isCancelled, addressRequest == requestID else { return }
        let offlineHits = local.map { AddressHit(title: $0.title, address: $0.address, latitude: $0.latitude, longitude: $0.longitude, house: $0.house) }
        addressResults = offlineHits
        if !offlineHits.isEmpty || !connectivity.connected {
            if offlineHits.isEmpty { addressMessage = "В локальной базе адрес не найден." }
            return
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query + ", Казахстан"
        request.resultTypes = number == nil ? [.address, .pointOfInterest] : [.address]
        request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 48, longitude: 67),
                                            span: MKCoordinateSpan(latitudeDelta: 16, longitudeDelta: 44))
        let search = MKLocalSearch(request: request)
        var hits: [AddressHit] = []
        do {
            let response = try await withTaskCancellationHandler(operation: {
                try await search.start()
            }, onCancel: { search.cancel() })
            guard !Task.isCancelled, addressRequest == requestID else { return }
            hits = response.mapItems.compactMap { item in
                let p = item.placemark
                guard p.isoCountryCode == "KZ", CLLocationCoordinate2DIsValid(p.coordinate) else { return nil }
                let house = p.subThoroughfare.map(normalizedHouse)
                if let number, house != number { return nil }
                let address = p.title ?? item.name ?? query
                return AddressHit(title: item.name ?? address, address: address,
                                  latitude: p.coordinate.latitude, longitude: p.coordinate.longitude, house: house)
            }
        } catch {
            guard !Task.isCancelled, addressRequest == requestID else { return }
        }
        guard !Task.isCancelled, addressRequest == requestID else { return }
        var seen = Set<String>()
        addressResults = hits.filter { seen.insert($0.id).inserted }
        rememberAddresses(addressResults)
        if addressResults.isEmpty {
            addressMessage = number == nil ? "Адрес не найден. Уточните город и улицу." : "Точный номер дома не найден. Укажите город и улицу. Соседние дома не подставляются."
        }
    }

    private func addressRow(_ hit: AddressHit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HuntRow(title: hit.title, subtitle: hit.address, symbol: "mappin.and.ellipse")
            HStack {
                Button("На карте") {
                    rememberAddresses([hit])
                    showSearch = false
                    tab = .map
                    mapFocus = hit.point
                    centerRequest += 1
                }
                Spacer()
                Button("Отсюда") {
                    rememberAddresses([hit])
                    addressOrigin = hit
                    searchText = ""
                }.buttonStyle(.bordered)
                Button("Сюда") {
                    rememberAddresses([hit])
                    addressDestination = hit
                }.buttonStyle(.borderedProminent)
            }.padding(.horizontal, 8)
        }
    }

    private var addressRoutePlanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Маршрут А → Б").font(.headline)
            HStack {
                Label(addressOrigin?.address ?? "Моя GPS-позиция", systemImage: "a.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                if addressOrigin != nil {
                    Button("GPS") { addressOrigin = nil }.buttonStyle(.bordered)
                }
            }
            HStack {
                Label(addressDestination?.address ?? "Выберите адрес назначения", systemImage: "b.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    let old = addressOrigin
                    addressOrigin = addressDestination
                    addressDestination = old
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .disabled(addressOrigin == nil || addressDestination == nil)
            }
            Picker("Способ передвижения", selection: $travelMode) {
                Text("Пешком").tag(OfflineRouteGraph.TravelMode.foot)
                Text("Авто").tag(OfflineRouteGraph.TravelMode.car)
            }.pickerStyle(.segmented)
            Button {
                guard let destination = addressDestination else { return }
                if routeGuidance { model.stopRecordedRouteGuidance() }
                routeGuidance = false
                showSearch = false
                if let origin = addressOrigin {
                    mapFocus = origin.point
                    centerRequest += 1
                }
                planRoute(to: destination.point, title: destination.address, origin: addressOrigin?.point)
            } label: {
                Label("Построить маршрут", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent)
            .disabled(addressDestination == nil || addressOrigin?.id == addressDestination?.id)
            Text("Найдите адрес и нажмите «Отсюда» или «Сюда».")
                .font(.caption).foregroundStyle(HuntReference.muted)
        }.padding(12).background(HuntReference.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private var addressIndexControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(addressIndexReady ? "Офлайн-адреса установлены" : "Офлайн-адреса не загружены", systemImage: addressIndexReady ? "checkmark.circle" : "arrow.down.circle")
                .font(.caption)
            Button("Импорт базы адресов SQLite") { importingAddressIndex = true }
                .font(.caption).buttonStyle(.bordered)
            if !addressIndexStatus.isEmpty { Text(addressIndexStatus).font(.caption) }
            Text("Данные адресов: © OpenStreetMap contributors, ODbL").font(.caption2)
        }
    }

    private var mapSearchSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    addressRoutePlanner
                    addressIndexControls
                    HuntSearchField(text: $searchText, placeholder: "Город, улица, дом, место")
                    Button { addressRequest = UUID() } label: {
                        Label("Найти адрес", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent)
                    .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 || (!connectivity.connected && !addressIndexReady) || addressLoading)
                    if !connectivity.connected {
                        Text(addressIndexReady ? "Офлайн-поиск по загруженной базе адресов." : "Загрузите базу для поиска новых адресов без интернета.")
                            .font(.caption).foregroundStyle(HuntReference.muted)
                    }
                    if addressLoading { ProgressView("Поиск адресов…") }
                    if !addressMessage.isEmpty {
                        Text(addressMessage).font(.caption).foregroundStyle(HuntReference.muted)
                    }
                    if !addressResults.isEmpty {
                        Text("Адреса и места · \(addressResults.count)").font(.subheadline.bold())
                        ForEach(addressResults) { hit in addressRow(hit) }
                    }
                    let cached = cachedAddressMatches.filter { hit in !addressResults.contains(where: { $0.id == hit.id }) }
                    if !cached.isEmpty {
                        Text("Сохранённые адреса · \(cached.count)").font(.subheadline.bold())
                        ForEach(cached) { hit in addressRow(hit) }
                    }
                    let grounds = model.zones.filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
                    let marks = model.markers.filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) }
                    Text("Охотугодья · \(grounds.count)").font(.subheadline.bold()).foregroundStyle(HuntReference.muted)
                    ForEach(grounds) { ground in
                        Button { showSearch = false; showGround(ground) } label: {
                            HuntRow(title: ground.name, subtitle: ground.groundRegion, symbol: "map")
                        }.buttonStyle(.plain)
                    }
                    Text("Метки · \(marks.count)").font(.subheadline.bold()).foregroundStyle(HuntReference.muted)
                    ForEach(marks) { marker in
                        Button {
                            showSearch = false; tab = .map; mapFocus = marker.coordinate; centerRequest += 1
                        } label: {
                            HuntRow(title: marker.title, subtitle: String(format: "%.4f, %.4f", marker.coordinate.latitude, marker.coordinate.longitude), symbol: "mappin.circle")
                        }.buttonStyle(.plain)
                    }
                    if grounds.isEmpty && marks.isEmpty && cached.isEmpty && addressResults.isEmpty && !addressLoading {
                        ReferenceEmptyCard(title: "Ничего не найдено", detail: "Измените поисковый запрос", symbol: "magnifyingglass")
                    }
                }.padding(16)
            }
            .background(HuntReference.background)
            .task { addressIndexReady = await addressIndex.isInstalled() }
            .task(id: addressRequest) {
                if let id = addressRequest {
                    await findAddresses(searchText.trimmingCharacters(in: .whitespacesAndNewlines), requestID: id)
                }
            }
            .fileImporter(isPresented: $importingAddressIndex, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task {
                        addressIndexStatus = "Установка базы…"
                        do {
                            try await addressIndex.install(url)
                            addressIndexReady = true
                            addressIndexStatus = "Адресная база установлена"
                        } catch { addressIndexStatus = error.localizedDescription }
                    }
                case .failure(let error): addressIndexStatus = error.localizedDescription
                }
            }
            .onChange(of: searchText) { _, _ in
                addressRequest = nil
                addressLoading = false
                addressResults = []
                addressMessage = ""
            }
            .onDisappear {
                addressRequest = nil
                addressLoading = false
            }
            .navigationTitle("Поиск на карте")
            .navigationBarTitleDisplayMode(.inline)
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
                set: { if $0 {
                            if weatherLayer == .none { weatherLayer = .wind }
                            showLayers = false
                            showWeatherLayers = true
                        }
                       else { weatherLayer = .none } })
    }

    // MARK: - Screens 5 & 6: Data / routes / markers
    private var dataScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ReferenceChip(title: "Маршруты", selected: dataSection == .routes) { dataSection = .routes }
                ReferenceChip(title: "Метки", selected: dataSection == .markers) { dataSection = .markers }
                ReferenceChip(title: "Угодья", selected: dataSection == .grounds) { dataSection = .grounds }
            }
            switch dataSection {
            case .routes: routesContent
            case .markers: markersContent
            case .grounds: groundsContent
            }
        }
    }

    private var groundsContent: some View {
        GroundsCatalogView(model: model, onDetails: { zone = $0 }, onMap: { showGround($0) }, onRoute: { routeGround($0) }, onOpenMap: { showGrounds = true; tab = .map })
    }

    private func selectedGroundBanner(_ ground: GeoZone) -> some View {
        HStack(spacing: 10) {
            Button { zone = ground } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ground.name).font(.headline).foregroundStyle(.white)
                    Text(ground.groundAreaLabel).font(.caption).foregroundStyle(HuntReference.green)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            Button { routeGround(ground) } label: { Image(systemName: "location.fill").frame(width: 44, height: 44) }
                .foregroundStyle(HuntReference.green).accessibilityLabel("Маршрут до угодья")
            Button { highlightedGroundID = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                .foregroundStyle(.white).accessibilityLabel("Снять выделение")
        }
        .padding(12)
        .background(HuntReference.card.opacity(0.97), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(HuntReference.green, lineWidth: 1.5))
    }

    private func showGround(_ ground: GeoZone) {
        guard let point = ground.groundCenter else { return }
        zone = nil
        showGrounds = true
        highlightedGroundID = ground.id
        mapFocus = point
        groundFitRequest += 1
        tab = .map
    }

    private func routeGround(_ ground: GeoZone) {
        guard let point = ground.groundDestination else { return }
        zone = nil
        showGrounds = true
        highlightedGroundID = ground.id
        planRoute(to: point, title: ground.name)
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
                        Text(model.recoveredSession ? "Восстановлен · на паузе" : model.paused ? "На паузе" : "Идёт запись").font(.caption).foregroundStyle(HuntReference.muted)
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
                Button("Редактировать копию", systemImage: "scissors") { editingTrack = track }.disabled(track.fixes.count < 2)
                Button("Профиль высот", systemImage: "chart.xyaxis.line") { profileTrack = track }
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
                }.disabled(track.hasDiscontinuity)
                Button("Пройти от конца", systemImage: "figure.walk.motion") {
                    showRecordedTrack(track, direction: .backward, follow: true)
                }.disabled(track.hasDiscontinuity)
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
                ReferenceChip(title: "Астрономия", selected: serviceSection == .astronomy) { serviceSection = .astronomy }.accessibilityIdentifier("service_astronomy")
                ReferenceChip(title: "Животные", selected: serviceSection == .wildlife) { serviceSection = .wildlife }.accessibilityIdentifier("service_wildlife")
            }
            switch serviceSection {
            case .weather: weatherContent
            case .astronomy: astronomyContent
            case .wildlife: wildlifeContent
            }
        }
    }

    private var weatherContent: some View {
        VStack(spacing: 12) {
            forecastLocationControls
            AnimatedWeatherDashboard(service: weather, coordinate: forecastPoint ?? model.coordinate,
                onMap: { layer in weatherLayer = layer; openWeatherMap() },
                onDetails: { showWeather = true }, locationTitle: forecastTitle)
        }
    }
    private var astronomyContent: some View {
        VStack(spacing: 12) {
            forecastLocationControls
            AstronomyScreen(point: forecastPoint ?? model.coordinate)
        }
    }
    private var forecastLocationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(forecastTitle).font(.subheadline.bold())
            HStack {
                HuntAction(title: "GPS", symbol: "location.fill") {
                    forecastPoint = nil
                    forecastTitle = "Текущая GPS-позиция"
                    if serviceSection == .weather, let point = model.coordinate {
                        weather.updateIfNeeded(latitude: point.latitude, longitude: point.longitude, force: true)
                    }
                }
                HuntAction(title: "На карте", symbol: "map") {
                    pointDestination = serviceSection
                    pickingForecastPoint = true
                    measurementMode = nil
                    movingMarkerID = nil
                    tab = .map
                }
                Menu {
                    ForEach(model.zones) { ground in
                        Button(ground.name) {
                            if let point = ground.groundCenter {
                                selectForecastPoint(point, title: ground.name, destination: serviceSection)
                            }
                        }
                    }
                } label: {
                    Label("Угодье", systemImage: "map.fill").font(.caption.bold()).foregroundStyle(HuntReference.green).frame(minHeight: 44)
                }
            }
        }.huntSurface()
    }
    private func selectForecastPoint(_ point: GeoPoint, title: String, destination: ServiceSection) {
        forecastPoint = point
        forecastTitle = title
        pickingForecastPoint = false
        serviceSection = destination
        tab = .services
        if destination == .weather {
            weather.updateIfNeeded(latitude: point.latitude, longitude: point.longitude, force: true)
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
        guard let latitude = forecastPoint?.latitude ?? model.coordinate?.latitude ?? weather.forecast?.latitude,
              let longitude = forecastPoint?.longitude ?? model.coordinate?.longitude ?? weather.forecast?.longitude else { return }
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
                ForEach(["По угодьям", "Справочник", "Дневник"], id: \.self) { name in
                    ReferenceChip(title: name, selected: selectedWildlifeMode == name) {
                        selectedWildlifeMode = name
                    }.accessibilityIdentifier("wildlife_" + name)
                }
            }
            if selectedWildlifeMode == "По угодьям" {
                let knownGrounds = model.zones.filter { $0.groundAnimals != "Нет данных о животных" }
                if animals.packs.isEmpty && knownGrounds.isEmpty {
                    ReferenceEmptyCard(title: "Каталоги животных не загружены",
                                       detail: "Импортируй подтверждённые сведения об угодье",
                                       symbol: "pawprint")
                }
                if !knownGrounds.isEmpty {
                    Text("Виды, упомянутые в источниках. Не подтверждение разрешения на охоту.").font(.caption).foregroundStyle(HuntReference.muted)
                    ForEach(knownGrounds) { ground in
                        Button { zone = ground } label: { HuntRow(title: ground.name, subtitle: ground.groundAnimals, symbol: "pawprint") }.buttonStyle(.plain)
                    }
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
            } else if selectedWildlifeMode == "Дневник" {
                ObservationJournal(store: observations, model: model, wildlife: animals, weather: weather.forecast,
                    onMap: { point in mapFocus = point; centerRequest += 1; tab = .map })
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
                OfflineWildlifeCatalog(store: animals)
                ForEach(taxa.isEmpty ? GBIFDiscovery.cached() : taxa) { animal in
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
                ReferenceMenuRow(symbol: "leaf.fill", title: "Охотугодья") { dataSection = .grounds; tab = .data }
                Divider().overlay(HuntReference.separator)
                ReferenceMenuRow(symbol: "books.vertical", title: "Библиотека охотника") { showLegalLibrary = true }
                Divider().overlay(HuntReference.separator)
                ReferenceMenuRow(symbol: "waveform.path.ecg", title: "Диагностика") { showDiagnostics = true }
                Divider().overlay(HuntReference.separator)
                ReferenceMenuRow(symbol: "location.north.circle", title: "Полевой режим") { showFieldMode = true }
                ReferenceMenuRow(symbol: "cross.case", title: "Экстренная помощь") { showEmergency = true }
                ReferenceMenuRow(symbol: "externaldrive", title: "Офлайн-карты") { showOfflineManager = true }.accessibilityIdentifier("offline_manager_open")
                ReferenceMenuRow(symbol: "gearshape", title: "Настройки") { showSettings = true }.accessibilityIdentifier("settings_open")
                Divider().overlay(HuntReference.separator)
                ReferenceMenuRow(symbol: "info.circle", title: "О приложении") { showAbout = true }
            }
            .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 20))
            VStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 50, weight: .bold))
                    .foregroundStyle(HuntReference.green)
                Text("QAZ TRAIL").font(.headline.bold())
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