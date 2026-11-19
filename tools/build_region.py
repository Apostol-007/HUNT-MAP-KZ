#!/usr/bin/env python3
"""One-command small-area real OSM MBTiles build, internet required."""
import argparse
from pathlib import Path
from fetch_osm_region import fetch, validate_bbox
from build_osm_mbtiles import build

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bbox', required=True, help='west,south,east,north')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--zoom', default='9:14')
    parser.add_argument('--max-tiles', type=int, default=20000)
    parser.add_argument('--api', default=None)
    args = parser.parse_args()
    try:
        bbox = tuple(float(v) for v in args.bbox.split(','))
        validate_bbox(bbox)
        low, high = map(int, args.zoom.split(':'))
        geojson = args.output.with_suffix('.osm-source.geojson')
        count = fetch(bbox, geojson, args.api) if args.api else fetch(bbox, geojson)
        tiles = build(geojson, args.output, bbox, low, high, args.max_tiles)
    except (ValueError, OSError) as exc:
        parser.exit(1, f'Build failed: {exc}\n')
    print(f'Created {args.output}: {tiles} tiles from {count} real OSM ways. Source preserved: {geojson}')

if __name__ == '__main__': main()
