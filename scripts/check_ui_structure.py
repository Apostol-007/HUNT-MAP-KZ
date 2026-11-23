#!/usr/bin/env python3
"""Static UI reference contract; not a visual iPhone rendering test."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
main = (root / 'iOS/HuntMap/MainView.swift').read_text(encoding='utf-8')
reference = (root / 'iOS/HuntMap/ReferenceDesign.swift').read_text(encoding='utf-8')
map_view = (root / 'iOS/HuntMap/OfflineMapView.swift').read_text(encoding='utf-8')
styles = (root / 'iOS/HuntMap/MapSources.swift').read_text(encoding='utf-8')
map_code = main.split('    private var mapScreen:', 1)[1].split('    // MARK: - Screen 3:', 1)[0]
checks = {
    'Old view deleted': not (root / 'iOS/HuntMap/LegacyMainView.swift').exists() and 'LegacyMainView' not in main,
    'Local MBTiles source': 'LocalMBTilesServer.shared' in map_view and 'URL(string: "mbtiles://' not in map_view,
    'Five tabs preserved': all(name in main for name in ['case home = "Главная"', 'map = "Карта"', 'data = "Данные"', 'services = "Сервисы"', 'more = "Ещё"']),
    'Reference components installed': all(name in reference for name in ['ReferenceActionCard', 'ReferenceLayerRow', 'ReferencePrimaryButton', 'ReferenceChip']),
    'Eight-screen navigation targets': all(name in main for name in ['homeScreen', 'mapScreen', 'layerSheet', 'weatherContent', 'routesContent', 'markersContent', 'wildlifeContent', 'moreScreen']),
    'No native TabView constraining map': 'TabView {' not in main,
    'MapLibre is full bleed': 'OfflineMapView(' in map_code and '.ignoresSafeArea(.container, edges: .all)' in map_code,
    'Map no fixed viewport height': '.frame(height:' not in map_code.split('LinearGradient(colors:', 1)[0],
    'GPS and tracking actions retained': all(name in main for name in ['model.requestGPS()', 'model.insertMarker(', 'model.startTrack()', 'model.stopTrack()']),
    'Map controls are interactive': all(name in main for name in ['showSearch = true', 'zoomCommand += 1', 'zoomCommand -= 1', 'centerRequest += 1']),
    'Layers real state': all(name in main for name in ['showGrounds ?', 'satelliteBinding', 'weatherEnabledBinding']),
    'Disabled unavailable wildlife map overlay': 'available: false' in main,
    'Vector remote source and offline fallback': 'api.maptiler.com/maps/' in styles and 'OfflineMapStyle.url' in map_view,
    'Map telemetry preserved': 'hunt.diag.fullscreenMap' in map_view,
}
for name, passed in checks.items():
    print(('OK   ' if passed else 'FAIL ') + name)
if not all(checks.values()):
    raise SystemExit(1)
