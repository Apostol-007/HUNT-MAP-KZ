"""Select a deterministic available iPhone, preferring 390pt devices."""
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    devices = json.load(f)["devices"]
candidates = []
preferences = ["iPhone 14", "iPhone 16", "iPhone 15", "iPhone 16e", "iPhone SE"]
for runtime, items in devices.items():
    if ".iOS-" not in runtime:
        continue
    version = tuple(int(p) for p in runtime.split(".iOS-")[-1].split("-"))
    for item in items:
        if not item.get("isAvailable") or not item["name"].startswith("iPhone"):
            continue
        rank = preferences.index(item["name"]) if item["name"] in preferences else len(preferences)
        candidates.append((rank, tuple(-p for p in version), item["name"], item["udid"]))
if not candidates:
    raise SystemExit("No available iPhone simulator")
_, _, _, udid = min(candidates)
print("HUNT_SIMULATOR_ID=" + udid)
