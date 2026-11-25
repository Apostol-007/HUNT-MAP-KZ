# Release gate — HUNT MAP KZ 6.0
Baseline: deb65e2fe6d970a8cd48f14fe9c2c843caeeac2c (5.12.3 build 83).
Do not promote a candidate until Core, server, simulator smoke tests and physical-device IPA build pass for its exact SHA.
Use temporary ci/* refs for candidates. Never force-update main. Preserve existing user data.
The first smoke suite checks launch, startup skip and five tabs, plus the grounds entry. It is not exhaustive feature verification.
UI screenshots are actual XCTest attachments; data availability, offline maps, GPS and weather realism still require dedicated tests and device validation.
