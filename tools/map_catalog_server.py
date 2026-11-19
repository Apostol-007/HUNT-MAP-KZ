#!/usr/bin/env python3
"""Read-only HTTPS-ready HUNT MAP KZ raster MBTiles catalog.

Run behind a TLS reverse proxy; never expose plain HTTP to the iPhone.
Publish only MBTiles that you own or may redistribute. No OSM tile scraping.
"""
import argparse
import hashlib
import json
import re
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

PACK_ID = re.compile(r'^[A-Za-z0-9_-]{1,100}$')
MAX_RANGE = 4 * 1024 * 1024


def catalog(folder):
    result = []
    for path in sorted(Path(folder).glob('*.mbtiles')):
        if not PACK_ID.fullmatch(path.stem) or not path.is_file():
            continue
        try:
            with sqlite3.connect(f'file:{path.resolve()}?mode=ro', uri=True) as db:
                meta = dict(db.execute('SELECT name,value FROM metadata'))
                if meta.get('format') not in ('png', 'jpg', 'jpeg', 'webp'):
                    continue
                if not db.execute('SELECT 1 FROM tiles LIMIT 1').fetchone():
                    continue
            bbox = tuple(float(x) for x in meta['bounds'].split(','))
            if len(bbox) != 4 or not (-180 <= bbox[0] < bbox[2] <= 180 and -90 <= bbox[1] < bbox[3] <= 90):
                continue
            digest = hash_file(path)
            result.append((dict(pack_id=path.stem, scope='region', scope_id=meta.get('name', path.stem),
                                size_bytes=path.stat().st_size, sha256=digest, source_version=meta.get('version', '1'),
                                license=meta.get('license', '© OpenStreetMap contributors · ODbL 1.0'),
                                verified=False, layers=['raster-mbtiles']), bbox, path))
        except (sqlite3.Error, ValueError, KeyError, OSError):
            continue
    return result


def hash_file(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def covers(bounds, lat, lon):
    return bounds[0] <= lon <= bounds[2] and bounds[1] <= lat <= bounds[3]


def handler_factory(folder):
    class Handler(BaseHTTPRequestHandler):
        def reply_json(self, value, status=200):
            body = json.dumps(value, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            parsed = urlsplit(self.path)
            if parsed.path == '/health':
                return self.reply_json({'status': 'ok'})
            packs = catalog(folder)
            if parsed.path == '/v1/packs/at-point':
                try:
                    query = parse_qs(parsed.query)
                    lat, lon = float(query['lat'][0]), float(query['lon'][0])
                    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
                        raise ValueError('invalid coordinates')
                except (KeyError, IndexError, ValueError):
                    return self.reply_json({'error': 'invalid coordinates'}, 400)
                return self.reply_json([p for p, bbox, _ in packs if covers(bbox, lat, lon)])
            if parsed.path == '/v1/packs/manifest':
                query = parse_qs(parsed.query)
                scope, region = query.get('scope', [''])[0], query.get('id', [''])[0]
                return self.reply_json([p for p, _, _ in packs if (not scope or scope == p['scope']) and
                                        (not region or region == p['scope_id'] or region == p['pack_id'] or region == 'KZ')])
            if parsed.path.startswith('/v1/packs/'):
                pack_id = parsed.path.removeprefix('/v1/packs/')
                if not PACK_ID.fullmatch(pack_id):
                    return self.reply_json({'error': 'invalid pack'}, 404)
                match = next(((p, path) for p, _, path in packs if p['pack_id'] == pack_id), None)
                if match is None:
                    return self.reply_json({'error': 'not found'}, 404)
                pack, path = match
                match_range = re.fullmatch(r'bytes=(\d+)-(\d+)', self.headers.get('Range', ''))
                if not match_range:
                    self.send_response(416); self.send_header('Content-Range', f'bytes */{pack["size_bytes"]}'); self.end_headers(); return
                start, end = map(int, match_range.groups())
                if start > end or start >= pack['size_bytes'] or end >= pack['size_bytes'] or end - start + 1 > MAX_RANGE:
                    self.send_response(416); self.send_header('Content-Range', f'bytes */{pack["size_bytes"]}'); self.end_headers(); return
                if_range = self.headers.get('If-Range')
                if if_range and if_range.strip('"').lower() != pack['sha256']:
                    self.send_response(412); self.end_headers(); return
                self.send_response(206)
                self.send_header('Content-Type', 'application/octet-stream')
                self.send_header('Accept-Ranges', 'bytes')
                self.send_header('ETag', f'"{pack["sha256"]}"')
                self.send_header('Content-Range', f'bytes {start}-{end}/{pack["size_bytes"]}')
                self.send_header('Content-Length', str(end - start + 1))
                self.end_headers()
                with path.open('rb') as stream:
                    stream.seek(start)
                    remaining = end - start + 1
                    while remaining:
                        chunk = stream.read(min(65536, remaining))
                        if not chunk: break
                        self.wfile.write(chunk)
                        remaining -= len(chunk)
                return
            return self.reply_json({'error': 'not found'}, 404)
    return Handler


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--maps', type=Path, default=Path('maps/published'))
    p.add_argument('--host', default='127.0.0.1')
    p.add_argument('--port', type=int, default=8765)
    args = p.parse_args()
    args.maps.mkdir(parents=True, exist_ok=True)
    print(f'Catalog: http://{args.host}:{args.port} (LOCAL ONLY; use HTTPS reverse proxy for iPhone)', flush=True)
    ThreadingHTTPServer((args.host, args.port), handler_factory(args.maps)).serve_forever()


if __name__ == '__main__':
    main()
