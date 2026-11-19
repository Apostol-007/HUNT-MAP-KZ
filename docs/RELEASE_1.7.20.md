# HUNT MAP KZ 1.7.20 — MapLibre offline areas

- Added `OfflineAreaPacks.swift` using MapLibre native offline tile pyramid packs.
- One-tap download for GPS position or tapped map point, with radii 500 m, 1/2/5 km.
- Shows resource progress and allows pause, resume and deletion.
- Keeps existing raster MBTiles importer and Overpass vector-feature downloads.
- Existing marker, GPS, camera and map layout code not changed.

## Important limitations
- The default source is OpenFreeMap. Verify that your intended use and offline prefetch comply with its current service terms; replace with an explicitly licensed source when necessary.
- The selected map style must match the style of the downloaded pack for offline rendering.
- Native MapLibre offline pack APIs have not been compiled against iOS SDK in this Linux environment; run GitHub Actions and device tests before claiming release-ready.
- MapLibre pack download is not Geofabrik PBF/BBBike MBTiles conversion. Those formats need a separate pipeline.
