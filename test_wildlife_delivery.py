import hashlib
import json
import pytest
from fastapi.testclient import TestClient
from server import app as module
from server.wildlife import publish, validate


def sample():
    return {'schema_version':1, 'source':'TEST ONLY', 'source_url':'https://example.org/source',
        'license':'TEST ONLY', 'generated_at':'2026-11-19T06:00:00Z', 'ground_id':'DEMO',
        'taxa':[{'id':'TEST-1','scientific_name':'Fictitia exemplaria','category':'no_data','evidence_count':0}]}


def encoded(value): return json.dumps(value,ensure_ascii=False).encode()


def test_publish_manifest_download_etag(tmp_path, monkeypatch):
    monkeypatch.setattr(module,'WILDLIFE_PACKS',tmp_path)
    raw=encoded(sample())
    record=publish(raw,'catalog-v1',tmp_path)
    assert record['sha256']==hashlib.sha256(raw).hexdigest()
    c=TestClient(module.app)
    assert c.get('/v1/wildlife/manifest',params={'ground_id':'DIFFERENT'}).json()==[]
    response=c.get('/v1/wildlife/manifest',params={'ground_id':'DEMO'})
    assert response.json()==[record]
    download=c.get('/v1/wildlife/packs/catalog-v1')
    assert download.status_code==200 and download.content==raw
    assert download.headers['etag']==f'"{record["sha256"]}"'
    assert c.get('/v1/wildlife/packs/catalog-v1',headers={'If-None-Match':download.headers['etag']}).status_code==304
    assert c.get('/v1/wildlife/packs/../catalog-v1').status_code==404
    assert publish(raw,'catalog-v1',tmp_path)==record
    with pytest.raises(ValueError,match='already exists'):
        altered=sample();altered['source']='ALTERED';publish(encoded(altered),'catalog-v1',tmp_path)
    (tmp_path/'catalog-v1.json').write_bytes(b'corrupt')
    assert c.get('/v1/wildlife/packs/catalog-v1').status_code==503


def test_reject_precise_coordinates_duplicate_taxa_and_malformed_input():
    d=sample();d['taxa'][0]['latitude']=43.0
    with pytest.raises(ValueError):validate(encoded(d))
    d=sample();d['taxa']*=2
    with pytest.raises(ValueError,match='duplicate taxon'):validate(encoded(d))
    d=sample();d['taxa'][0]['category']='confirmed'
    with pytest.raises(ValueError,match='without evidence'):validate(encoded(d))
    with pytest.raises(ValueError):validate(b'{"schema_version":1,"schema_version":1}')
    with pytest.raises(ValueError):validate(b'{' + b' ' * (8*1024*1024) + b'}')


def test_unpublished_catalog_is_empty(tmp_path, monkeypatch):
    monkeypatch.setattr(module,'WILDLIFE_PACKS',tmp_path)
    c=TestClient(module.app)
    assert c.get('/v1/wildlife/manifest',params={'ground_id':'DEMO'}).json()==[]
    assert c.get('/v1/wildlife/packs/missing').status_code==404
