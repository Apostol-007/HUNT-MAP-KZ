#!/usr/bin/env python3
"""Static project configuration validation; simulator and physical phone still required."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
project = (root / 'iOS/project.yml').read_text(encoding='utf-8')
view = (root / 'iOS/HuntMap/MainView.swift').read_text(encoding='utf-8')
diag = (root / 'iOS/HuntMap/Diagnostics.swift').read_text(encoding='utf-8')
launch = root / 'iOS/HuntMap/LaunchScreen.storyboard'
assert launch.is_file() and 'launchScreen="YES"' in launch.read_text()
assert 'INFOPLIST_KEY_UILaunchStoryboardName: LaunchScreen' in project
assert 'GENERATE_INFOPLIST_FILE: YES' in project
assert 'MARKETING_VERSION: 3.0.0' in project
assert 'HuntMap/Info.plist' not in project
assert 'OfflineMapView(' in view and '.ignoresSafeArea(.container, edges: .all)' in view
assert 'CFBundleShortVersionString' in diag
assert 'WeatherPanel' in view
print('PASS: launch screen, Info.plist, full-bleed MapLibre, build version and diagnostics')
