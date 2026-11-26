#!/usr/bin/env python3
"""Build QAZ TRAIL address SQLite from a Kazakhstan OSM PBF.
Install: python -m pip install osmium
Run: python tools/build_address_index.py kazakhstan-latest.osm.pbf kazakhstan-addresses.sqlite
Source: https://download.geofabrik.de/asia/kazakhstan.html
Data © OpenStreetMap contributors, ODbL 1.0. Building way coordinates are representative
points, not surveyed entrances. Only explicitly tagged addresses are exported.
"""
import argparse
import math
import sqlite3
from pathlib import Path

SCHEMA = """
CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT INTO metadata VALUES('schema','qaz-address-v1'),('source','OpenStreetMap'),('license','ODbL-1.0');
CREATE VIRTUAL TABLE addresses USING fts5(title,address,house,lat UNINDEXED,lon UNINDEXED, tokenize='unicode61');
"""
def house(value):
    return value.lower().translate(str.maketrans("абвс", "abvc")).replace(" ", "")

def build(source, output):
    import osmium
    output = Path(output)
    temp = output.with_suffix(output.suffix + ".tmp")
    if temp.exists():
        temp.unlink()
    db = sqlite3.connect(temp)
    try:
        db.executescript(SCHEMA)
        batch = []
        count = 0
        class Handler(osmium.SimpleHandler):
            def add(self, tags, lat, lon):
                nonlocal count
                street = tags.get("addr:street") or tags.get("addr:place") or ""
                number = tags.get("addr:housenumber") or ""
                city = tags.get("addr:city") or tags.get("addr:town") or tags.get("addr:village") or ""
                name = tags.get("name") or ""
                if not street or not number or not math.isfinite(lat) or not math.isfinite(lon):
                    return
                if not (40 <= lat <= 56 and 46 <= lon <= 88):
                    return
                title = f"{street}, {number}"
                address = ", ".join(filter(None, (city, title, name, tags.get("name:ru"), tags.get("name:kk"))))
                batch.append((title,address,house(number),lat,lon))
                count += 1
                if len(batch) >= 5000:
                    flush()
            def node(self, n):
                if n.location.valid():
                    self.add(n.tags, n.location.lat, n.location.lon)
            def way(self, w):
                if not w.tags.get("addr:housenumber"):
                    return
                pts = [(n.location.lat,n.location.lon) for n in w.nodes if n.location.valid()]
                if pts:
                    self.add(w.tags, sum(p[0] for p in pts)/len(pts), sum(p[1] for p in pts)/len(pts))
        def flush():
            db.executemany("INSERT INTO addresses VALUES(?,?,?,?,?)", batch)
            batch.clear()
        Handler().apply_file(str(source), locations=True, idx="flex_mem")
        flush()
        if count == 0:
            raise RuntimeError("No tagged addresses found; check the PBF extract")
        db.execute("INSERT INTO addresses(addresses) VALUES('optimize')")
        db.commit()
        print(f"Exported {count:,} address records")
    except BaseException:
        db.close()
        temp.unlink(missing_ok=True)
        raise
    else:
        db.close()
        temp.replace(output)
        print(output, output.stat().st_size, "bytes")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pbf", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    build(args.pbf, args.output)
