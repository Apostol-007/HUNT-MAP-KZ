#!/usr/bin/env python3
"""Validate the current generated-Xcode project contract, not physical UI rendering.

Device runtime, background GPS, memory and map appearance must be tested on iPhone.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
project = (root / "iOS/project.yml").read_text(encoding="utf-8")
main = (root / "iOS/HuntMap/MainView.swift").read_text(encoding="utf-8")
map_view = (root / "iOS/HuntMap/OfflineMapView.swift").read_text(encoding="utf-8")
diag = (root / "iOS/HuntMap/Diagnostics.swift").read_text(encoding="utf-8")
launch = (root / "iOS/HuntMap/LaunchScreen.storyboard").read_text(encoding="utf-8")

assert 'launchScreen="YES"' in launch
assert 'UILaunchStoryboardName: LaunchScreen' in project
assert 'GENERATE_INFOPLIST_FILE: NO' in project
assert 'path: HuntMap/Info.plist' in project
assert re.search(r"MARKETING_VERSION:\s*\d+\.\d+\.\d+", project)
assert re.search(r"CURRENT_PROJECT_VERSION:\s*\d+", project)
assert 'OfflineMapView(' in main and '.ignoresSafeArea(.container, edges: .all)' in main
assert 'func makeUIView(context: Context) -> UIView' in map_view
assert 'container.addSubview(view)' in map_view
assert 'CFBundleShortVersionString' in diag
assert 'WeatherMapSheet' in main
assert '@State private var tab: Tab = .home' in main
assert '@State private var mapOpened = false' in main
assert 'if mapOpened || tab == .map {' in main
assert 'if value == .map { mapOpened = true }' in main
assert 'if tab != .map { mapOpened = false }' in main
assert 'active: tab == .map' in main
assert 'guard active else {' in map_view
print("PASS: launch screen, XcodeGen Info.plist, fullscreen map, lazy MapLibre and version")
