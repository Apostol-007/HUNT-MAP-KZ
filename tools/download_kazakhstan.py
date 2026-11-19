#!/usr/bin/env python3
"""Download the official Geofabrik Kazakhstan OSM PBF with resumable HTTPS.

This downloads OSM *data*, never prefetches public OSM tile servers.
"""
import argparse
import hashlib
import urllib.request
from pathlib import Path

SOURCE = 'https://download.geofabrik.de/asia/kazakhstan-latest.osm.pbf'
MAX_BYTES = 2_000_000_000


def download(destination: Path, opener=urllib.request.urlopen, chunk_size=1024 * 1024):
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    part = destination.with_name(destination.name + '.part')
    start = part.stat().st_size if part.exists() else 0
    if start > MAX_BYTES:
        raise ValueError('partial file exceeds safety limit')
    request = urllib.request.Request(SOURCE, headers={'User-Agent': 'HuntMapKZ-OfflineDataBuilder/1.7.4'})
    if start:
        request.add_header('Range', f'bytes={start}-')
    with opener(request, timeout=120) as response:
        status = response.status
        if start and status != 206:
            # Do not append a full 200 response to a partial file.
            part.unlink(missing_ok=True)
            raise RuntimeError('server did not honor resume; partial file cleared, retry command')
        if status not in (200, 206):
            raise RuntimeError(f'unexpected HTTP {status}')
        if start:
            content_range = response.headers.get('Content-Range', '')
            if not content_range.startswith(f'bytes {start}-'):
                raise RuntimeError('incorrect Content-Range; partial file retained')
        length = response.headers.get('Content-Length')
        if length is not None and int(length) + start > MAX_BYTES:
            raise ValueError('download exceeds safety limit')
        with part.open('ab' if start else 'wb') as output:
            total = start
            while True:
                chunk = response.read(chunk_size)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_BYTES:
                    raise ValueError('download exceeds safety limit')
                output.write(chunk)
    if part.stat().st_size < 1000:
        raise ValueError('downloaded file unexpectedly small')
    part.replace(destination)
    return destination


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, default=Path('maps/kazakhstan-latest.osm.pbf'))
    args = p.parse_args()
    try:
        path = download(args.output)
    except (OSError, ValueError, RuntimeError) as exc:
        p.exit(1, f'Download failed: {exc}\n')
    print(f'OSM PBF saved: {path} ({path.stat().st_size} bytes)')
    print(f'SHA-256: {sha256(path)}')
    print('Source: Geofabrik / OpenStreetMap contributors, ODbL 1.0')


if __name__ == '__main__':
    main()
