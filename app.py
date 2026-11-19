"""Prototype public pack distribution API. No unlicensed real hunting boundaries included."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
from typing import Literal
from fastapi import FastAPI, HTTPException, Header, Query, Request
from fastapi.responses import Response, StreamingResponse
from pydantic import BaseModel

ROOT = Path(__file__).resolve().parent
PACKS = ROOT / 'packs'
app = FastAPI(title='HUNT MAP KZ Pack API (prototype)', version='0.8.0')
WILDLIFE_PACKS = ROOT / 'wildlife_packs'
BOUNDARIES = ROOT / 'boundaries'

class ManifestRecord(BaseModel):
    pack_id: str
    scope: Literal['region', 'ground', 'country']
    scope_id: str
    size_bytes: int
    sha256: str
    source_version: str
    license: str
    verified: bool
    layers: list[str]


def catalog() -> list[ManifestRecord]:
    manifest = PACKS / 'catalog.json'
    if not manifest.exists():
        return []
    return [ManifestRecord.model_validate(row) for row in json.loads(manifest.read_text())]

@app.get('/health')
def health():
    return {'status':'ok', 'published_packs':len(catalog())}

@app.get('/v1/catalog/regions')
def regions():
    # Empty until authoritative, redistributable region list is ingested.
    return []

@app.get('/v1/catalog/grounds')
def grounds(region_id: str | None = None):
    # Region filtering requires verified region mappings, not inferred IDs.
    if region_id is not None:
        return []
    index = BOUNDARIES / 'catalog.json'
    return json.loads(index.read_text('utf-8')) if index.is_file() else []


@app.get('/v1/grounds/{ground_id}')
def ground(ground_id: str):
    from server.boundary_ingest import ID
    if not ID.fullmatch(ground_id):
        raise HTTPException(404, 'Unknown ground')
    entry = next((item for item in grounds() if item['ground_id'] == ground_id), None)
    if entry is None:
        raise HTTPException(404, 'Unknown ground')
    return entry


@app.get('/v1/grounds/{ground_id}/geojson')
def ground_geojson(ground_id: str, if_none_match: str | None = Header(default=None, alias='If-None-Match')):
    entry = ground(ground_id)
    file = BOUNDARIES / f"{entry['sha256']}.geojson"
    if not file.is_file() or file.stat().st_size > 20_000_000:
        raise HTTPException(503, 'Boundary unavailable')
    data = file.read_bytes()
    if hashlib.sha256(data).hexdigest() != entry['sha256']:
        raise HTTPException(503, 'Boundary integrity mismatch')
    etag = '"' + entry['sha256'] + '"'
    headers = {'ETag': etag, 'Cache-Control': 'public, max-age=3600', 'X-Content-Type-Options': 'nosniff'}
    if if_none_match == etag:
        return Response(status_code=304, headers=headers)
    return Response(data, media_type='application/geo+json', headers=headers)


@app.get('/v1/packs/manifest', response_model=list[ManifestRecord])
def manifest(scope: Literal['region','ground','country'], id: str = Query(...), layers: str = ''):
    wanted=set(filter(None, layers.split(',')))
    return [p for p in catalog() if p.scope == scope and p.scope_id == id and (not wanted or wanted.issubset(p.layers))]

@app.api_route('/v1/packs/{pack_id}', methods=['GET', 'HEAD'])
def pack(request: Request, pack_id: str, range_header: str | None = Header(default=None, alias='Range'), if_range: str | None = Header(default=None, alias='If-Range')):
    entry=next((p for p in catalog() if p.pack_id == pack_id),None)
    if entry is None or not pack_id.isascii() or not all(ch.isalnum() or ch in '-_' for ch in pack_id):
        raise HTTPException(404,'Pack not found')
    path=PACKS / (pack_id+'.bin')
    if not path.is_file():
        raise HTTPException(404,'Pack binary unavailable')
    # Stream multi-gigabyte packs without loading them into application RAM.
    actual_size=path.stat().st_size
    if actual_size != entry.size_bytes:
        raise HTTPException(503,'Integrity validation failed')
    digest=hashlib.sha256()
    with path.open('rb') as check:
        for block in iter(lambda: check.read(1024*1024), b''):
            digest.update(block)
    if digest.hexdigest() != entry.sha256:
        raise HTTPException(503,'Integrity validation failed')
    headers={'Accept-Ranges':'bytes','ETag':'"'+entry.sha256+'"','Cache-Control':'public, max-age=3600'}
    # A changed package cannot be appended to an older partially downloaded version.
    # RFC 9110: mismatching If-Range -> full response, which the iOS range client rejects.
    if if_range is not None and if_range != headers['ETag']:
        range_header = None
    import re
    if range_header is None:
        start, end, status = 0, actual_size-1, 200
    else:
        match=re.fullmatch(r'bytes=(\d*)-(\d*)',range_header.strip())
        if not match or (not match[1] and not match[2]):
            raise HTTPException(416,'Invalid Range',headers={'Content-Range':f'bytes */{actual_size}'})
        if match[1]:
            start=int(match[1]);end=int(match[2]) if match[2] else actual_size-1
        else:
            suffix=int(match[2]);start=max(0,actual_size-suffix);end=actual_size-1
        if start>=actual_size or end<start or actual_size==0:
            raise HTTPException(416,'Unsatisfiable Range',headers={'Content-Range':f'bytes */{actual_size}'})
        end=min(end,actual_size-1)
        headers['Content-Range']=f'bytes {start}-{end}/{actual_size}'
        status=206
    headers['Content-Length']=str(end-start+1)
    def chunks():
        with path.open('rb') as source:
            source.seek(start)
            remaining=end-start+1
            while remaining:
                block=source.read(min(1024*1024,remaining))
                if not block: break
                remaining-=len(block)
                yield block
    if request.method == 'HEAD':
        return Response(status_code=status, media_type='application/octet-stream', headers=headers)
    return StreamingResponse(chunks(), status_code=status, media_type='application/octet-stream',headers=headers)


@app.get('/v1/wildlife/manifest')
def wildlife_manifest(ground_id: str = Query(..., min_length=1, max_length=150)):
    """Published versions only. An empty response does not mean species are absent."""
    index = WILDLIFE_PACKS / 'catalog.json'
    if not index.is_file():
        return []
    return [record for record in json.loads(index.read_text(encoding='utf-8'))
            if record['ground_id'] == ground_id]


@app.get('/v1/wildlife/packs/{pack_id}')
def wildlife_pack(pack_id: str, if_none_match: str | None = Header(default=None, alias='If-None-Match')):
    from server.wildlife import ID, MAX_BYTES
    if not ID.fullmatch(pack_id):
        raise HTTPException(404, 'Unknown wildlife package')
    index_file = WILDLIFE_PACKS / 'catalog.json'
    entries = json.loads(index_file.read_text(encoding='utf-8')) if index_file.is_file() else []
    entry = next((r for r in entries if r['pack_id'] == pack_id), None)
    if entry is None:
        raise HTTPException(404, 'Unknown wildlife package')
    file = WILDLIFE_PACKS / f'{pack_id}.json'
    if not file.is_file() or file.stat().st_size > MAX_BYTES or file.stat().st_size != entry['size_bytes']:
        raise HTTPException(503, 'Unavailable/corrupted package')
    data = file.read_bytes()
    if hashlib.sha256(data).hexdigest() != entry['sha256']:
        raise HTTPException(503, 'Package checksum mismatch')
    etag = '"' + entry['sha256'] + '"'
    headers = {'ETag':etag,'Cache-Control':'public, max-age=3600','X-Content-Type-Options':'nosniff'}
    if if_none_match == etag:
        return Response(status_code=304,headers=headers)
    return Response(data,media_type='application/json',headers=headers)
