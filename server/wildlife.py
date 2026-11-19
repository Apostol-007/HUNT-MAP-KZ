"""Offline wildlife catalog publisher. No scraping, no legal hunting claims."""
from __future__ import annotations
import hashlib
import json
import os
import re
import tempfile
from datetime import datetime
from pathlib import Path
from urllib.parse import urlsplit

MAX_BYTES = 8 * 1024 * 1024
CATEGORIES = {'confirmed', 'probable', 'historical', 'no_data'}
ROOT_KEYS = {'schema_version', 'source', 'source_url', 'license', 'generated_at', 'ground_id', 'taxa'}
TAXON_KEYS = {'id', 'scientific_name', 'name_ru', 'name_kk', 'category', 'evidence_count', 'latest_evidence_at', 'source_record_url'}
ID = re.compile(r'[A-Za-z0-9_-]{1,150}\Z')


def iso_date(value):
    if not isinstance(value, str): return False
    try:
        datetime.fromisoformat(value.replace('Z', '+00:00'))
        return 'T' in value and (value.endswith('Z') or '+' in value[10:] or '-' in value[10:])
    except ValueError: return False


def https(value):
    if not isinstance(value, str): return False
    try:
        parts = urlsplit(value)
        return parts.scheme == 'https' and bool(parts.hostname) and not parts.username and not parts.password
    except ValueError: return False


def text(value, limit=200):
    return isinstance(value, str) and bool(value.strip()) and len(value) <= limit


def validate(raw: bytes) -> dict:
    if len(raw) > MAX_BYTES: raise ValueError('catalog too large')
    def reject_duplicates(pairs):
        out = {}
        for k, v in pairs:
            if k in out: raise ValueError('duplicate JSON property')
            out[k] = v
        return out
    try: doc = json.loads(raw, object_pairs_hook=reject_duplicates)
    except (ValueError, UnicodeDecodeError) as exc: raise ValueError('invalid JSON') from exc
    if not isinstance(doc, dict) or set(doc) != ROOT_KEYS: raise ValueError('unknown/missing catalog fields')
    if not (type(doc['schema_version']) is int and doc['schema_version'] == 1
            and text(doc['source']) and https(doc['source_url']) and text(doc['license'])
            and iso_date(doc['generated_at']) and text(doc['ground_id'], 150)
            and isinstance(doc['taxa'], list) and len(doc['taxa']) <= 10000):
        raise ValueError('invalid catalog metadata')
    seen = set()
    for taxon in doc['taxa']:
        if not isinstance(taxon, dict) or not set(taxon).issubset(TAXON_KEYS) or not {'id','scientific_name','category','evidence_count'}.issubset(taxon):
            raise ValueError('unexpected taxon fields (possibly private coordinates)')
        if not (text(taxon['id'],150) and text(taxon['scientific_name']) and taxon['category'] in CATEGORIES
                and type(taxon['evidence_count']) is int and taxon['evidence_count'] >= 0):
            raise ValueError('invalid taxon')
        if taxon['category'] == 'confirmed' and taxon['evidence_count'] < 1: raise ValueError('confirmed without evidence')
        for name in ('name_ru','name_kk'):
            if taxon.get(name) is not None and not text(taxon[name]): raise ValueError('invalid taxon name')
        if taxon.get('latest_evidence_at') is not None and not iso_date(taxon['latest_evidence_at']): raise ValueError('invalid evidence date')
        if taxon.get('source_record_url') is not None and not https(taxon['source_record_url']): raise ValueError('invalid record URL')
        if taxon['id'] in seen: raise ValueError('duplicate taxon ID')
        seen.add(taxon['id'])
    return doc


def publish(raw: bytes, pack_id: str, directory: Path):
    if not ID.fullmatch(pack_id): raise ValueError('invalid pack_id')
    doc = validate(raw)
    directory.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256(raw).hexdigest()
    target = directory / f'{pack_id}.json'
    # Immutable binaries: never overwrite an existing package version.
    if target.exists():
        if hashlib.sha256(target.read_bytes()).hexdigest() != digest: raise ValueError('pack_id already exists with different bytes')
    else:
        fd, temporary = tempfile.mkstemp(prefix='.wildlife-', dir=directory)
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(raw); stream.flush(); os.fsync(stream.fileno())
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary): os.unlink(temporary)
    index_file = directory / 'catalog.json'
    index = json.loads(index_file.read_text()) if index_file.exists() else []
    record = {'pack_id':pack_id, 'ground_id':doc['ground_id'],'sha256':digest,'size_bytes':len(raw),
              'generated_at':doc['generated_at'],'source':doc['source'],'license':doc['license'],
              'source_url':doc['source_url'],'taxa_count':len(doc['taxa'])}
    if any(row['pack_id'] == pack_id and row != record for row in index): raise ValueError('index conflict')
    index = [row for row in index if row['pack_id'] != pack_id] + [record]
    fd, temporary = tempfile.mkstemp(prefix='.index-', dir=directory)
    try:
        with os.fdopen(fd,'w',encoding='utf-8') as stream:
            json.dump(index,stream,ensure_ascii=False,indent=2);stream.flush();os.fsync(stream.fileno())
        os.replace(temporary,index_file)
    finally:
        if os.path.exists(temporary):os.unlink(temporary)
    return record


if __name__ == '__main__':
    import argparse
    p=argparse.ArgumentParser(description='Publish an approved wildlife JSON pack')
    p.add_argument('file',type=Path);p.add_argument('--id',required=True);p.add_argument('--directory',type=Path,default=Path(__file__).resolve().parent/'wildlife_packs')
    a=p.parse_args()
    print(json.dumps(publish(a.file.read_bytes(),a.id,a.directory),indent=2,ensure_ascii=False))
