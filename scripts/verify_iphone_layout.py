#!/usr/bin/env python3
"""Check project configuration; cannot substitute Xcode or physical iPhone UI tests."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
project = (root / "iOS/project.yml").read_text()
view = (root / "iOS/HuntMap/MainView.swift").read_text()
diag = (root / "iOS/HuntMap/Diagnostics.swift").read_text()
launch = root / "iOS/HuntMap/LaunchScreen.storyboard"
assert launch.is_file(), "LaunchScreen.storyboard absent"
assert 'launchScreen="YES"' in launch.read_text()
assert "INFOPLIST_KEY_UILaunchStoryboardName: LaunchScreen" in project
assert "GENERATE_INFOPLIST_FILE: YES" in project
assert "MARKETING_VERSION: 1.4.0" in project
assert "HuntMap/Info.plist" not in project
assert "case .map: mapTab" in view
assert "case .map: mapTab.ignoresSafeArea" not in view
assert ".ignoresSafeArea(.container, edges: .all)" in view
assert "private var headerControls" in view
assert "Reserve the complete dock height" in view
assert "Overlay: does not alter the map's available height" in view
assert "CFBundleShortVersionString" in diag and "0.9.0 (source build" not in diag
print("PASS: Launch screen, generated Info.plist, full-bleed map code, real version diagnostics")
