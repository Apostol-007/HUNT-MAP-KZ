import json, sys, math
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert data["type"] == "FeatureCollection"
assert len(data["features"]) == 153
for feature in data["features"]:
    assert feature["properties"]["name"]
    assert feature["geometry"]["type"] == "MultiPolygon"
    for polygon in feature["geometry"]["coordinates"]:
        assert polygon
        for ring in polygon:
            assert len(ring) >= 4 and ring[0] == ring[-1]
            assert len(set(map(tuple, ring))) >= 3
            assert all(math.isfinite(x) and math.isfinite(y) and -180 <= x <= 180 and -90 <= y <= 90 for x, y in ring)
print("PASS: 153 bundled grounds and valid coordinate rings")
