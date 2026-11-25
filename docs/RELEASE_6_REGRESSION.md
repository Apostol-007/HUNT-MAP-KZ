# Release 6.0 — regression gate

Baseline: 5.19.0 (95), CI run 229, all three jobs passed.
Candidate: 5.19.1 (96). A green candidate verifies only the tests actually executed.

## Added checks
- Startup gate skipped through real UI, not a bypass flag.
- Observation created through editor, saved, app terminated and relaunched, record must remain.
- Backup create button must produce a share action.
- Existing navigation, astronomy, field mode, SOS, catalog and settings smoke checks remain enabled.

## Open acceptance items (not passed by smoke tests)
- Physical iPhone XR / 14: launch latency, memory, sustained GPS and battery, offline airplane-mode usage.
- Active track recovery/resumption, segment-aware statistics and elevation gain/loss; return notifications and deviation regression on real tracks.
- Full MapLibre ground editing and overlap checks between neighboring grounds.
- Offline pack filtering by actual selected geometry, resumable PMTiles, DEM, verified download progress.
- Weather cache by multiple points; solar comparison against external ephemerides; lunar accuracy.
- Wildlife licensed images and descriptions, multiple photos, map layer.
- Backup encrypted ZIP format, multi-file crash-atomic recovery and full restore UI tests.
- 26 actual screenshot acceptance and motion recordings, adaptive layout coverage.

Do not label the remaining requirements complete until evidence exists. No release tag is created by this candidate.
