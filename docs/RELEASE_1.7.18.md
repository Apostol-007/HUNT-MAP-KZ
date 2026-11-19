# HUNT MAP KZ 1.7.18 — GPS AR compass / markers / OSM regions

## Fixes
- Restore actual MLNPointAnnotation objects for all saved markers. Prior v1.7.17 had removed them from `updateAnnotations` and placed noninteractive UIKit images under MapLibre's internal rendering layers.
- Restore MapLibre native annotation image delegate and selection callback; keep map long-press repositioning.
- New AR camera compass, target marker selector, heading and geodesic GPS distance. This is NOT optical distance measurement, LiDAR ranging, or reliable object recognition. Camera and heading require physical iPhone testing.
- OSM download supports radius up to 10 km using small sequential Overpass requests with per-cell persistent commits and partial-failure diagnostics. Still feature overlays only, not raster/vector basemap. Public servers can throttle or reject downloads; large requests can take significant time.

## Validation
- Swift parser: passed (Linux Swift 6.2.1)
- Core XCTest: 14 passed
- Core Swift Testing: 11 passed
- iOS Xcode/MapLibre/AVFoundation compilation: NOT available locally, NOT verified
- iPhone camera, compass and network integration: NOT verified
