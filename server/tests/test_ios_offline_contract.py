"""Source-level guardrails, not a replacement for an iOS network trace / Xcode build."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / 'iOS' / 'HuntMap'


def test_offline_maplibre_has_no_online_tile_fallback():
    map_view = (IOS / 'OfflineMapView.swift').read_text()
    assert 'import MapLibre' in map_view
    assert 'import MapKit' not in map_view
    assert '"sources":{}' in map_view
    assert 'LocalMBTilesServer.shared' in map_view
    assert 'tileURLTemplates' in map_view
    assert 'URL(string: "mbtiles://' not in map_view
    # Remote style is allowed only behind an explicit user-controlled online flag.
    assert 'protomapsOfflineStyleURL ?? OfflineMapStyle.url' in map_view
    assert 'nativeOfflineStyleURL ?? OfflineMapStyle.url' not in map_view
    assert 'protomapsOnlineStyleURL' in map_view
    assert 'MapBasemap.protomaps.rawValue' in map_view
    assert 'MLNTilePyramidOfflineRegion' in (IOS / 'NativeOfflinePackStore.swift').read_text()
    assert 'HuntOfflineStyleURL' in (IOS / 'NativeOfflinePackStore.swift').read_text()
    sources = (IOS / 'MapSources.swift').read_text()
    assert 'https://tiles.openfreemap.org/styles/' in sources
    assert 'api.maptiler.com/maps/' in sources
    assert 'OfflineMapStyle.url' in map_view
    assert 'didFinishLoading style' in map_view


def test_maplibre_package_declared_and_local_import_available():
    project = (ROOT / 'iOS' / 'project.yml').read_text()
    tiles = (IOS / 'OfflineTiles.swift').read_text()
    ui = (IOS / 'MainView.swift').read_text()
    assert 'maplibre-gl-native-distribution' in project
    assert '- package: MapLibre' in project
    assert 'func importLocal(' in tiles
    assert 'RasterMBTiles.isSupported(temp)' in tiles
    assert 'Self.sha256(file: temp)' in tiles
    # Legacy screens have been removed, not merely hidden.
    assert not (IOS / 'LegacyMainView.swift').exists()
    assert 'LegacyMainView' not in ui
    assert 'startupSync.begin(' in ui
    assert 'StartupSyncBanner(sync: startupSync)' in ui
    assert 'StartupSyncScreen(sync:' not in ui
    assert 'HostingOfflineSheet' not in ui  # manual download screen is intentionally unreachable
    assert 'MapKit' not in tiles


def test_downloaded_roads_are_visible_offline_and_local_tiles_allowed():
    source = (IOS / 'OfflineMapView.swift').read_text()
    main = (IOS / 'MainView.swift').read_text()
    road = (IOS / 'OfflineRoadOverlayStore.swift').read_text()
    hosting = (IOS / 'HostingOfflineDownloads.swift').read_text()
    project = (ROOT / 'iOS/project.yml').read_text()
    assert 'NSAllowsLocalNetworking: true' in project
    assert 'OFFLINE|ROAD' in source
    assert 'offlineRoadLines: online ? [] : offlineRoads.lines' in main
    assert 'installedRoadFiles(in bounds:' in hosting
    assert 'Data(contentsOf: file)' in road
    assert 'Task.detached(priority: .utility)' in road
    assert 'onViewportChanged:' in main


def test_protomaps_native_pmtiles_integration():
    code = (IOS / 'ProtomapsOfflineStore.swift').read_text()
    style = (IOS / 'ProtomapsVectorStyle.swift').read_text()
    view = (IOS / 'OfflineMapView.swift').read_text()
    ui = (IOS / 'MainView.swift').read_text()
    assert 'pmtiles://' in style and 'absoluteString' in style
    assert 'roads' in style and 'path' in style and 'water' in style
    assert 'PMTiles' in code and 'SHA256' in code
    assert 'protomapsOfflineStyleURL' in view
    assert 'ProtomapsOfflineStore()' in ui


def test_protomaps_local_glyphs_and_sprites_are_downloaded():
    source = (IOS / 'ProtomapsAssets.swift').read_text()
    style = (IOS / 'ProtomapsVectorStyle.swift').read_text()
    assert 'Noto Sans Regular' in source
    assert '1024-1279' in source and '1280-1535' in source
    assert 'sprites/v4' in source
    assert 'ProtomapsAssets.ready(in: folder)' in style
    assert 'place_names_' in style


def test_protomaps_catalog_is_editable_and_diagnosed():
    store = (IOS / "ProtomapsOfflineStore.swift").read_text()
    ui = (IOS / "OfflineGridDownloadSheet.swift").read_text()
    assert "catalogCandidates(" in store
    assert "setCatalogAddress(" in store
    assert "loadedCatalogURL" in store
    assert "rejectedPacks" in store
    assert "HTTP \\(statusCode)" in store
    assert "URL(string: raw, relativeTo: catalog)" in store
    assert "protomaps_catalog_address" in ui
    assert "Проверить хостинг и каталог" in ui


def test_offline_hybrid_is_file_backed():
    style = (IOS / "ProtomapsVectorStyle.swift").read_text()
    mapview = (IOS / "OfflineMapView.swift").read_text()
    store = (IOS / "ProtomapsOfflineStore.swift").read_text()
    assert "hybrid: Bool = false" in style
    assert "if !hybrid {" in style
    assert "protomaps-offline-hybrid.json" in style
    assert "hybridOfflineStyleURL" in store
    assert "protomapsHybridStyleURL" in mapview
    assert "style.insertLayer(raster, below: vector)" in mapview


def test_offline_style_cannot_fallback_to_remote_native_pack():
    mapview = (IOS / "OfflineMapView.swift").read_text()
    ui = (IOS / "MainView.swift").read_text()
    assert "nativeOfflineStyleURL ?? OfflineMapStyle.url" not in mapview
    assert "Гибрид · полностью офлайн" in ui
    assert ".disabled(protomaps.installed.isEmpty || maps.installed.isEmpty)" in ui


def test_recorded_track_replay_and_bidirectional_follow():
    main = (IOS / "MainView.swift").read_text()
    follow = (IOS / "RecordedTrackFollow.swift").read_text()
    view = (IOS / "OfflineMapView.swift").read_text()
    assert "Воспроизвести: от начала" in main and "Воспроизвести: от конца" in main
    assert "Пройти от начала" in main and "Пройти от конца" in main
    assert "recorded_track_timeline" in main
    assert "recordedRouteRemaining" in main and "recordedRouteDeviation" in main
    assert "Array(original.reversed())" in follow
    assert "REPLAY|LOCATION" in view


def test_valhalla_local_cpp_route_engine_integration():
    project = (ROOT / "iOS/project.yml").read_text()
    engine = (IOS / "ValhallaLocalEngine.swift").read_text()
    ui = (IOS / "MainView.swift").read_text()
    assert "valhalla-mobile" in project.lower()
    assert "import Valhalla" in engine
    assert "ValhallaConfig(tileExtractTar: archive)" in engine
    assert "route(rawRequest: payload)" in engine
    assert '"pedestrian" : "auto"' in engine
    assert "ValhallaPolyline6.decode" in engine
    assert "calculateLegacyRoute" in ui
    assert "planRoute(to:" in ui
    assert "route_start_guidance" in ui


def test_valhalla_download_and_windows_builder_contract():
    engine = (IOS / "ValhallaLocalEngine.swift").read_text()
    ui = (IOS / "MainView.swift").read_text()
    builder = (ROOT / "tools/PREPARE_VALHALLA_WINDOWS.bat").read_text()
    assert "hunt-valhalla-v1" in engine
    assert "SHA256()" in engine
    startup = (IOS / "StartupSync.swift").read_text()
    assert "downloadFromHosting()" in startup  # automatic startup update, not a download button
    assert "ghcr.io/valhalla/valhalla-scripted:latest" in builder
    assert "serve_tiles=False" in builder
    assert "valhalla_tiles.tar" in builder


def test_recorded_route_guidance_handles_foreground_and_background_gps():
    model = (IOS / "FieldModel.swift").read_text()
    ui = (IOS / "MainView.swift").read_text()
    assert "startRecordedRouteGuidance" in model
    assert "stopRecordedRouteGuidance" in model
    assert "manager.authorizationStatus == .authorizedAlways" in model
    assert "model.startRecordedRouteGuidance()" in ui
    assert "model.stopRecordedRouteGuidance()" in ui


def test_valhalla_turn_by_turn_russian_directions():
    engine = (IOS / "ValhallaLocalEngine.swift").read_text()
    main = (IOS / "MainView.swift").read_text()
    assert '"language": "ru-RU"' in engine
    assert '"directions_type": "instructions"' in engine
    assert 'begin_shape_index' in engine
    assert 'ValhallaManeuver' in engine
    assert 'refreshNextTurn(at:' in main
    assert 'Следующий манёвр' in main


def test_user_can_plan_and_follow_without_manual_download_buttons():
    ui = (IOS / "MainView.swift").read_text()
    startup = (IOS / "StartupSync.swift").read_text()
    assert 'Button("Построить маршрут")' in ui
    assert 'Label("В путь"' in ui
    assert 'Label("Авто"' in ui and 'Label("Пешком"' in ui
    assert 'Скачать Valhalla' not in ui
    assert 'Загрузить карты' not in ui
    assert 'Скачать карту по сетке' not in ui
    assert 'startupSync.begin(' in ui and 'await protomaps.downloadAllAvailable()' in startup


def test_wind_prefetches_on_launch_and_progressively_refines():
    ui = (IOS / "MainView.swift").read_text()
    wind = (IOS / "WeatherGridService.swift").read_text()
    assert 'weatherGrid.load(hourOffset: 0)' in ui
    assert 'coarse.width = 3' in wind and 'coarse.height = 3' in wind
    assert 'var width: Int = 6' in wind and 'var height: Int = 4' in wind
    assert 'self.fetchGrid(region: coarse' in wind
    assert 'self.fetchGrid(region: detailed' in wind


def test_weather_grid_hourly_query_has_no_conflicting_forecast_days():
    source = (IOS / "WeatherGridService.swift").read_text()
    assert 'URLQueryItem(name: "start_hour", value: targetHour)' in source
    assert 'URLQueryItem(name: "end_hour", value: targetHour)' in source
    # forecast_days is only allowed on fallback after removing the explicit hours.
    assert 'fallback.queryItems?.removeAll' in source
    assert '$0.name == "start_hour" || $0.name == "end_hour"' in source
    assert 'fallback.queryItems?.append(URLQueryItem(name: "forecast_days", value: "8"))' in source
    assert 'http.statusCode != 200' in source


def test_weather_uses_lightweight_overlay_without_maplibre_shape_flood():
    map_view = (IOS / "OfflineMapView.swift").read_text()
    overlay = (IOS / "WeatherFieldOverlay.swift").read_text()
    wind = (IOS / "WindParticlesOverlay.swift").read_text()
    assert 'WeatherFieldOverlay(mapView: view, hostView: container)' in map_view
    assert 'WindParticlesOverlay(mapView: view, hostView: container)' in map_view
    assert 'func makeUIView(context: Context) -> UIView' in map_view
    assert 'func updateUIView(_ container: UIView, context: Context)' in map_view
    assert 'container.addSubview(view)' in map_view
    assert 'return container' in map_view
    assert 'hostView.addSubview(self)' in overlay
    assert 'mapView.addSubview(self)' not in overlay
    assert 'fieldOverlay?.configure(grid: weatherGrid, layer: weatherLayer)' in map_view
    assert 'WeatherGeometry.shade(' not in map_view
    assert 'WeatherGeometry.windArrow(' not in map_view
    assert 'let pixelStep: CGFloat = 20' in overlay
    assert 'context.fill(tile)' in overlay
    assert 'mapView.convert(screenPoint, toCoordinateFrom: self)' in overlay
    assert 'private let particleCount = 85' in wind
    assert 'link.preferredFramesPerSecond = 15' in wind


def test_weather_reuses_latest_cached_hour():
    weather = (IOS / "WeatherGridService.swift").read_text()
    assert 'private func latestCachedGrid(region: Region)' in weather
    assert 'latestCachedGrid(region: detailed) ?? latestCachedGrid(region: coarse)' in weather
    assert 'let currentHourAvailable' in weather
    assert 'if !currentHourAvailable' in weather
    assert 'lastFailedKey == key' in weather


def test_weather_layer_above_maplibre_gl_view():
    map_view = (IOS / "OfflineMapView.swift").read_text()
    field = (IOS / "WeatherFieldOverlay.swift").read_text()
    wind = (IOS / "WindParticlesOverlay.swift").read_text()
    assert 'container.addSubview(view)' in map_view
    assert 'WeatherFieldOverlay(mapView: view, hostView: container)' in map_view
    assert 'WindParticlesOverlay(mapView: view, hostView: container)' in map_view
    assert 'hostView.addSubview(self)' in field and 'hostView.addSubview(self)' in wind
    assert 'mapView.addSubview(self)' not in field and 'mapView.addSubview(self)' not in wind
    assert 'trailingAnchor.constraint(equalTo: hostView.trailingAnchor)' in field
    assert 'superview?.bringSubviewToFront(self)' in wind


def test_partial_forecast_does_not_blank_weather():
    canvas = (IOS / "WeatherFieldOverlay.swift").read_text()
    wind = (IOS / "WindParticlesOverlay.swift").read_text()
    assert 'let usable = corners.compactMap' in canvas
    assert 'totalWeight > 0.000001' in canvas
    assert 'let neighbours:' in wind
    assert 'forecast = grid' in wind


def test_startup_does_not_gate_map_on_downloads():
    startup = (IOS / "StartupSync.swift").read_text()
    main = (IOS / "MainView.swift").read_text()
    assert '@Published private(set) var presented = false' in startup
    assert 'StartupSyncBanner(sync: startupSync)' in main
    assert 'StartupSyncScreen(sync:' not in main
    assert 'Task.sleep(for: .seconds(8))' in startup
    assert 'func skip()' in startup
    assert 'active = true' in startup and 'defer { active = false }' in startup
    assert 'loadRoutingNetwork()' not in main.split('.onAppear {', 1)[1].split('.onChange(of: scenePhase)', 1)[0]
    assert 'try? await Task.sleep(for: .seconds(4))' in main
    assert 'let recentFiles = files.filter' in (IOS / "WeatherGridService.swift").read_text()


def test_cold_start_does_not_build_hidden_map_or_hash_on_main_actor():
    ui = (IOS / "MainView.swift").read_text()
    hosting = (IOS / "HostingOfflineDownloads.swift").read_text()
    maps = (IOS / "ProtomapsOfflineStore.swift").read_text()
    startup = (IOS / "StartupSync.swift").read_text()
    assert 'if tab == .map {' in ui
    assert 'if tab != .map { themedScreen }' not in ui
    assert 'Task.detached(priority: .utility)' in maps
    assert 'nonisolated private static func digest' in hosting
    assert 'func needsRouteUpdateAsync' in hosting
    assert 'hosting.needsRouteUpdateAsync(pack)' in startup
    assert 'Task.sleep(for: .seconds(8))' in startup

def test_active_gps_track_append_only_journal():
    model = (IOS / "FieldModel.swift").read_text()
    journal = (IOS / "TrackPointJournal.swift").read_text()
    assert 'private let trackJournal = TrackPointJournal()' in model
    assert 'if !trackJournal.append(point) { persist() }' in model
    assert 'CREATE TABLE IF NOT EXISTS fixes' in journal
    assert 'ORDER BY id' in journal
    assert 'pending.fixes = journalFixes' in model
    assert 'if let pending=obj.pendingTrack' not in model
