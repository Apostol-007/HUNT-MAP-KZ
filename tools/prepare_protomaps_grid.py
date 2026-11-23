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
    names = set(re.findall(r"(?<![0-9])(20[0-9]{6})\.pmtiles", html))
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
        code = getattr(response, "status", None)
        if code is None:
            code = response.getcode()
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


def atomic_catalog(path, packs, source, base_url):
    """Persist progress after EACH successful cell; old catalog remains on failure."""
    records = sorted(packs.values(), key=lambda p: p["id"])
    payload = {
        "schema": SCHEMA, "source": str(source),
        "attribution": "© OpenStreetMap contributors (ODbL); Protomaps Basemap",
        "packs": records
    }
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8") as out:
        json.dump(payload, out, ensure_ascii=False, indent=2)
        out.flush()
        import os
        os.fsync(out.fileno())
    temporary.replace(path)


def load_catalog(path):
    if not path.is_file():
        return {}
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
        if manifest.get("schema") != SCHEMA:
            raise ValueError("Unexpected existing catalog schema; refusing to overwrite")
        return {p["id"]: p for p in manifest.get("packs", [])}
    except (KeyError, json.JSONDecodeError) as exc:
        raise ValueError(f"Existing catalog is damaged; preserved for repair: {exc}") from exc


def make_record(name, bounds, file, base_url, maxzoom):
    return {
        "id": name, "name": f"Protomaps KZ {bounds[0]:.2f},{bounds[1]:.2f}",
        "url": f"{base_url.rstrip('/')}/{name}.pmtiles",
        "bounds": bounds, "bytes": file.stat().st_size,
        "sha256": digest(file), "minzoom": 0, "maxzoom": maxzoom
    }


def cached_record(record, file, bounds, base_url, maxzoom):
    """Skip completed cells only when local file and recorded metadata agree."""
    if not record or not file.is_file():
        return False
    try:
        return (record["bounds"] == bounds and
                record["bytes"] == file.stat().st_size and
                record["maxzoom"] == maxzoom and
                record["url"] == f"{base_url.rstrip('/')}/{file.name}" and
                len(record["sha256"]) == 64 and
                (file.open("rb").read(8) == b"PMTiles" + bytes([3])))
    except (OSError, KeyError, TypeError):
        return False


def partition(items, size):
    """Iterator-based bounded batches. No entire-country geometry kept in RAM."""
    from itertools import islice
    iterator = iter(items)
    while True:
        batch = list(islice(iterator, size))
        if not batch:
            return
        yield batch


def extract_cell(pmtiles, source, dest, bbox, maxzoom):
    """Never leave a corrupt file under its final name."""
    temporary = dest.with_name("." + dest.name + ".building")
    temporary.unlink(missing_ok=True)
    try:
        command = [pmtiles, "extract", str(source), str(temporary),
                   "--bbox=" + ",".join(map(str, bbox)), "--maxzoom=" + str(maxzoom)]
        print("COMMAND:", " ".join(command), flush=True)
        subprocess.run(command, check=True, timeout=1800)
        subprocess.run([pmtiles, "verify", str(temporary)], check=True, timeout=300)
        check_pmtiles(temporary)
        temporary.replace(dest)
    finally:
        temporary.unlink(missing_ok=True)


class ConsoleAndFile:
    """Mirrors Python progress to a persistent log for double-clicked BAT runs."""
    def __init__(self, terminal, logfile):
        self.terminal, self.logfile = terminal, logfile
    def write(self, message):
        self.terminal.write(message)
        self.terminal.flush()
        self.logfile.write(message)
        self.logfile.flush()
    def flush(self):
        self.terminal.flush()
        self.logfile.flush()


def run(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default="auto",
                        help="Protomaps daily PMTiles HTTPS URL or local kazakhstan.pmtiles")
    parser.add_argument("--bbox", default="46.49,40.56,87.31,55.44",
                        help="west,south,east,north; default WHOLE KAZAKHSTAN rectangle")
    parser.add_argument("--step", type=float, default=0.5,
                        help="WGS84 cell in degrees, whole country default 0.5")
    parser.add_argument("--batch-size", type=int, default=100,
                        help="Maximum cells processed in each bounded batch")
    parser.add_argument("--max-cells", type=int, default=100_000,
                        help="Total safety guard, NOT the batch size")
    parser.add_argument("--maxzoom", type=int, default=15)
    parser.add_argument("--pmtiles", default="pmtiles")
    parser.add_argument("--out", type=Path, default=Path("hosting_upload/protomaps"))
    parser.add_argument("--base-url", default=HOST)
    parser.add_argument("--retry-delay", type=float, default=15.0,
                        help="Seconds before retrying failed cells, increasing to 5 minutes")
    args = parser.parse_args(argv)
    if not (0.1 <= args.step <= 1.0) or not (0 <= args.maxzoom <= 15) or not (1 <= args.batch_size <= 100):
        parser.error("step must be 0.1..1.0, maxzoom 0..15, batch-size 1..100")
    if not (1 <= args.max_cells <= 100_000) or not (0.1 <= args.retry_delay <= 300):
        parser.error("Invalid max-cells or retry-delay")
    if not args.base_url.startswith("https://"):
        parser.error("--base-url must be HTTPS")

    bounds = parse_bbox(args.bbox)
    xs = range(math.floor(bounds[0] / args.step), math.ceil(bounds[2] / args.step))
    ys = range(math.floor(bounds[1] / args.step), math.ceil(bounds[3] / args.step))
    total = len(xs) * len(ys)
    if total > args.max_cells:
        parser.error(f"Requested {total} cells, exceeds --max-cells={args.max_cells}")
    args.out.mkdir(parents=True, exist_ok=True)
    log_path = args.out / "prepare_protomaps.log"
    import sys
    import time
    with log_path.open("a", encoding="utf-8") as log:
        old_stdout, old_stderr = sys.stdout, sys.stderr
        sys.stdout = ConsoleAndFile(old_stdout, log)
        sys.stderr = ConsoleAndFile(old_stderr, log)
        try:
            print("\n========== Protomaps country extraction ==========", flush=True)
            print(f"Bounds: {bounds}; grid step: {args.step}; total cells: {total}; batch size: {args.batch_size}")
            print(f"Output: {args.out.resolve()}; log: {log_path.resolve()}")
            source = latest_source() if args.source == "auto" else args.source
            if not (source.startswith("https://") or Path(source).is_file()):
                raise ValueError("Missing source PMTiles; use a real local file or HTTPS URL")
            print("Source:", source, flush=True)
            completed = load_catalog(args.out / "catalog.json")
            all_cells = cells(bounds, args.step, args.max_cells)
            failures = []
            processed = 0
            for batch_index, batch in enumerate(partition(all_cells, args.batch_size), 1):
                print(f"\nBATCH {batch_index}: {len(batch)} cells", flush=True)
                for name, bbox in batch:
                    processed += 1
                    dest = args.out / f"{name}.pmtiles"
                    if cached_record(completed.get(name), dest, bbox, args.base_url, args.maxzoom):
                        print(f"[{processed}/{total}] SKIP completed {name}", flush=True)
                        continue
                    # A valid archive from an interrupted previous run can be
                    # indexed without downloading again.
                    if dest.is_file():
                        try:
                            check_pmtiles(dest)
                            completed[name] = make_record(name, bbox, dest, args.base_url, args.maxzoom)
                            atomic_catalog(args.out / "catalog.json", completed, source, args.base_url)
                            print(f"[{processed}/{total}] REINDEX {name}", flush=True)
                            continue
                        except (OSError, ValueError):
                            dest.unlink(missing_ok=True)
                    try:
                        print(f"[{processed}/{total}] Extract {name} {bbox}", flush=True)
                        extract_cell(args.pmtiles, source, dest, bbox, args.maxzoom)
                        completed[name] = make_record(name, bbox, dest, args.base_url, args.maxzoom)
                        atomic_catalog(args.out / "catalog.json", completed, source, args.base_url)
                        print(f"[{processed}/{total}] SAVED {name} ({dest.stat().st_size} bytes)", flush=True)
                    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError, ValueError) as exc:
                        failures.append((name, bbox))
                        print(f"[{processed}/{total}] WILL RETRY {name}: {exc}", flush=True)
                print(f"BATCH {batch_index} finished; catalog has {len(completed)} packs; pending errors: {len(failures)}")
            # Retry only failed cells; never restart already completed batches.
            retry_round = 0
            while failures:
                retry_round += 1
                delay = min(300.0, args.retry_delay * 2 ** min(retry_round - 1, 5))
                print(f"\nRETRY ROUND {retry_round}: {len(failures)} cells; delay {delay:g}s; Ctrl+C to stop safely")
                time.sleep(delay)
                remaining = []
                for batch in partition(failures, args.batch_size):
                    for name, bbox in batch:
                        dest = args.out / f"{name}.pmtiles"
                        if cached_record(completed.get(name), dest, bbox, args.base_url, args.maxzoom):
                            continue
                        try:
                            extract_cell(args.pmtiles, source, dest, bbox, args.maxzoom)
                            completed[name] = make_record(name, bbox, dest, args.base_url, args.maxzoom)
                            atomic_catalog(args.out / "catalog.json", completed, source, args.base_url)
                            print(f"RECOVERED {name}; saved {len(completed)}/{total}")
                        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError, ValueError) as exc:
                            print(f"RETRY FAILED {name}: {exc}")
                            remaining.append((name, bbox))
                failures = remaining
                print(f"RETRY ROUND {retry_round} done; outstanding: {len(failures)}")
            print(f"\nSUCCESS: {len(completed)}/{total} PMTiles, catalog.json")
            print(f"Upload files to {args.base_url}/ (keep names).")
            return 0
        except KeyboardInterrupt:
            print("\nINTERRUPTED safely. Already saved PMTiles/catalog.json are kept.")
            return 130
        except (ValueError, OSError, subprocess.CalledProcessError) as exc:
            print(f"FATAL: {exc}")
            return 1
        finally:
            sys.stdout, sys.stderr = old_stdout, old_stderr


if __name__ == "__main__":
    import sys
    sys.exit(run(sys.argv[1:]))
