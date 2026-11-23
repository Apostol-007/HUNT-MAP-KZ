#!/usr/bin/env python3
"""Static guardrails only; this does not substitute for iPhone screenshot tests."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
main = (root / 'iOS/HuntMap/MainView.swift').read_text(encoding='utf-8')
map_view = (root / 'iOS/HuntMap/OfflineMapView.swift').read_text(encoding='utf-8')
checks = {
    'MapLibre is a background, not inside a native TabView': 'TabView {' not in main and 'OfflineMapView(' in main,
    'Map covers full safe area': '.ignoresSafeArea(.container, edges: .all)' in main,
    'Navigation has five sections': all(x in main for x in ['case map = "Карта"', 'tracks = "Маршруты"', 'markers = "Маркеры"', 'wildlife = "Животные"', 'downloads = "Загрузки"']),
    'GPS, marker, and record actions remain': all(x in main for x in ['model.requestGPS()', 'model.addMarker()', 'model.startTrack()', 'model.stopTrack()']),
    'Map retains selection and weather': 'selectedZone: $selectedZone' in main and 'weatherGrid:' in main,
    'Map does not use hardcoded height': '.frame(height:' not in main[main.index('    private var mapTab: some View {'):main.index('    private func fieldControl(')],
    'Runtime map geometry diagnostic retained': 'hunt.diag.fullscreenMap' in map_view,
}
for title, ok in checks.items():
    print(('OK ' if ok else 'FAIL ') + title)
if not all(checks.values()):
    raise SystemExit(1)
