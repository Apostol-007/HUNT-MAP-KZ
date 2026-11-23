#!/usr/bin/env python3
"""Static regressions checks, not a substitute for a real iPhone layout test."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
main = (root / 'iOS/HuntMap/MainView.swift').read_text(encoding='utf-8')
map_view = (root / 'iOS/HuntMap/OfflineMapView.swift').read_text(encoding='utf-8')
styles = (root / 'iOS/HuntMap/MapSources.swift').read_text(encoding='utf-8')
checks = {
    'Rebuilt five-tab navigation': all(name in main for name in ['case home = "Главная"', 'map = "Карта"', 'data = "Данные"', 'services = "Сервисы"', 'more = "Ещё"']),
    'New app does not use native TabView': 'TabView {' not in main,
    'MapLibre remains full-bleed': 'OfflineMapView(' in main and '.ignoresSafeArea(.container, edges: .all)' in main,
    'No fixed-height map': '.frame(height:' not in main[main.index('    private var mapScreen:'):main.index('    private func mapAction(')],
    'GPS tracking controls retained': all(x in main for x in ['model.requestGPS()', 'model.addMarker()', 'model.startTrack()', 'model.stopTrack()']),
    'Weather and hunting ground selections wired': 'weatherGrid:' in main and 'selectedZone: $zone' in main,
    'Satellite requires API key': 'case .satellite: return nil' in styles,
    'User-supplied MapTiler source': 'api.maptiler.com/maps/' in styles,
    'MapLibre uses the selected style': 'selectedStyle' in map_view,
    'Map geometry diagnostics retained': 'hunt.diag.fullscreenMap' in map_view,
}
for title, ok in checks.items():
    print(('OK ' if ok else 'FAIL ') + title)
if not all(checks.values()):
    raise SystemExit(1)
