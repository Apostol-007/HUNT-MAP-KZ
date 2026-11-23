#!/usr/bin/env python3
"""Build downloadable Protomaps v4 regional PMTiles and static catalog for HUNT MAP KZ.

Requires official pmtiles CLI; region extraction reads only required byte ranges.
Source must be a compatible Protomaps Basemap v4 daily build, not satellite imagery.
"""
import argparse
import hashlib
import json
import math
import re
import subprocess
import urllib.request
from pathlib import Path

HOST = "https://create.web-works.kz/maps/protomaps"
SCHEMA = "hunt-protomaps-v1"

# The official build list is a JavaScript-powered page: its initial HTML may
# contain NO archive filenames. Reading the HTML alone is not a reliable resolver.
# Last build verified in the public official Protomaps build list on 2026-11-23.
KNOWN_BUILD = "20261116"
BUILD_LIST = "https://maps.protomaps.com/builds/"
ARCHIVE_ROOT = "https://build.protomaps.com/"


def source_candidates(html, today=None):
    """Newest published-looking candidates first; no whole-planet downloads."""
    import datetime
    today = today or datetime.datetime.now(datetime.timezone.utc).date()
    names = set(re.findall(r"(?<![0-9])(20[0-9]{6})\\.pmtiles", html))
    # Try recent daily uploads. Builds are not guaranteed every day.
    for delta in range(0, 15):
        names.add((today - datetime.timedelta(days=delta)).strftime("%Y%m%d"))
    names.add(KNOWN_BUILD)
    return [ARCHIVE_ROOT + name + ".pmtiles" for name in sorted(names, reverse=True)
            if name <= today.strftime("%Y%m%d")]


def probe_source(url, opener=urllib.request.urlopen):
    """Validate a remote PMTiles header using Range; never download the planet."""
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "HUNT-MAP-KZ-Protomaps/5.5",
                 "Range": "bytes=0-7", "Accept": "application/octet-stream"}
    )
    with opener(request, timeout=12) as response:
        code = getattr(response, "status", response.getcode())
        if code not in (200, 206):
            return False
        return response.read(8) == b"PMTiles" + bytes([3])


def latest_source(opener=urllib.request.urlopen, today=None):
    """Find latest working v4 daily PMTiles, even if official site renders with JS."""
    import datetime
    today = today or datetime.datetime.now(datetime.timezone.utc).date()
    html = ""
    try:
        request = urllib.request.Request(BUILD_LIST,
                     headers={"User-Agent": "Mozilla/5.0 (HUNT-MAP-KZ/5.5)"})
        with opener(request, timeout=12) as response:
            html = response.read(3_000_000).decode("utf-8", "replace")
    except (OSError, ValueError) as exc:
        print("Build list unavailable; probing official dated archives:", exc, flush=True)
    for candidate in source_candidates(html, today):
        try:
            if probe_source(candidate, opener=opener):
                print("Verified Protomaps source:", candidate, flush=True)
                return candidate
        except (OSError, ValueError) as exc:
            print("Skipped unavailable build:", candidate.rsplit("/", 1)[-1],
                  str(exc)[:100], flush=True)
    raise ValueError(
        "No official Protomaps daily PMTiles could be verified via HTTPS Range. "
        "Check internet/proxy access to build.protomaps.com or use --source "
        "https://build.protomaps.com/" + KNOWN_BUILD + ".pmtiles"
    )

def parse_bbox(value):
    numbers = [float(v.strip()) for v in value.split(",")]
    if len(numbers) != 4:
        raise ValueError("Bounding box must contain west,south,east,north")
    west, south, east, north = numbers
    if not (-180 <= west < east <= 180 and -85 <= south < north <= 85):
        raise ValueError("Invalid WGS84 bounding box")
    return numbers

def cells(bounds, step, max_cells):
    west, south, east, north = bounds
    xs = range(math.floor(west / step), math.ceil(east / step))
    ys = range(math.floor(south / step), math.ceil(north / step))
    if len(xs) * len(ys) > max_cells:
        raise ValueError("Too many cells; choose smaller bbox, larger --step, or --max-cells")
    for y in ys:
        for x in xs:
            b = [round(x * step, 6), round(y * step, 6),
                 round((x + 1) * step, 6), round((y + 1) * step, 6)]
            yield f"kz_{x:+06d}_{y:+06d}".replace("+", "p").replace("-", "m"), b

def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()

def check_pmtiles(path):
    with path.open("rb") as source:
        header = source.read(8)
    if header != b"PMTiles" + bytes([3]):
        raise ValueError(f"{path} is not a PMTiles v3 archive")

def run(args):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default="auto", help="Protomaps v4 daily PMTiles URL or existing local .pmtiles")
    parser.add_argument("--bbox", default="76.7,43.1,77.2,43.5", help="west,south,east,north")
    parser.add_argument("--step", type=float, default=0.1, help="WGS84 grid size in degrees")
    parser.add_argument("--maxzoom", type=int, default=15)
    parser.add_argument("--max-cells", type=int, default=100)
    parser.add_argument("--pmtiles", default="pmtiles")
    parser.add_argument("--out", type=Path, default=Path("hosting_upload/protomaps"))
    parser.add_argument("--base-url", default=HOST)
    args = parser.parse_args(args)
    if not (0.01 <= args.step <= 1.0) or not (0 <= args.maxzoom <= 15):
        parser.error("--step must be 0.01..1.0 and --maxzoom 0..15")
    try:
        source = latest_source() if args.source == "auto" else args.source
        print("PMTiles source:", source, flush=True)
        if not (source.startswith("https://") or Path(source).is_file()):
            raise ValueError("Source must be HTTPS URL or existing local PMTiles")
        if not args.base_url.startswith("https://"):
            raise ValueError("--base-url must be HTTPS")
        bounds = parse_bbox(args.bbox)
        args.out.mkdir(parents=True, exist_ok=True)
        packs = []
        for index, (name, bbox) in enumerate(cells(bounds, args.step, args.max_cells), 1):
            dest = args.out / f"{name}.pmtiles"
            if not dest.exists():
                temporary = args.out / f".{name}.building.pmtiles"
                temporary.unlink(missing_ok=True)
                try:
                    print(f"[{index}] Extract {bbox} -> {dest}", flush=True)
                    subprocess.run([args.pmtiles, "extract", str(source), str(temporary),
                                    "--bbox=" + ",".join(map(str, bbox)),
                                    "--maxzoom=" + str(args.maxzoom)], check=True)
                    subprocess.run([args.pmtiles, "verify", str(temporary)], check=True)
                    check_pmtiles(temporary)
                    temporary.replace(dest)
                except BaseException:
                    temporary.unlink(missing_ok=True)
                    raise
            check_pmtiles(dest)
            packs.append({
                "id": name, "name": f"Protomaps KZ {bbox[0]:.2f},{bbox[1]:.2f}",
                "url": f"{args.base_url.rstrip('/')}/{name}.pmtiles",
                "bounds": bbox, "bytes": dest.stat().st_size,
                "sha256": digest(dest), "minzoom": 0, "maxzoom": args.maxzoom
            })
        catalog = {"schema": SCHEMA, "source": str(source),
                   "attribution": "© OpenStreetMap contributors (ODbL); Protomaps Basemap",
                   "packs": packs}
        tmp = args.out / "catalog.json.tmp"
        tmp.write_text(json.dumps(catalog, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(args.out / "catalog.json")
        print(f"READY: {len(packs)} PMTiles + catalog.json in {args.out}")
        print(f"Upload this directory to {args.base_url}/ as-is. Keep URLs and checksums unchanged.")
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"Protomaps preparation failed: {exc}\n")

if __name__ == "__main__":
    import sys
    run(sys.argv[1:])
