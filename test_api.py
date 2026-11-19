import hashlib
import json
from fastapi.testclient import TestClient
from server import app as module

def test_empty_real_catalog():
    c=TestClient(module.app)
    assert c.get('/health').json()['status']=='ok'
    assert c.get('/v1/catalog/grounds').json()==[]
    assert c.get('/v1/packs/manifest',params={'scope':'country','id':'KZ'}).json()==[]
    assert c.get('/v1/packs/no-pack').status_code==404

def test_range_integrity_and_paths(tmp_path,monkeypatch):
    monkeypatch.setattr(module,'PACKS',tmp_path)
    data=b'no-real-geodata-example'
    (tmp_path/'demo.bin').write_bytes(data)
    record={'pack_id':'demo','scope':'ground','scope_id':'DEMO','size_bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'source_version':'demo','license':'test-only','verified':False,'layers':['geometry']}
    (tmp_path/'catalog.json').write_text(json.dumps([record]))
    c=TestClient(module.app)
    assert c.get('/v1/packs/demo').content==data
    r=c.get('/v1/packs/demo',headers={'Range':'bytes=0-3'})
    assert r.status_code==206 and r.content==data[:4] and r.headers['content-range']==f'bytes 0-3/{len(data)}'
    assert c.get('/v1/packs/demo',headers={'Range':'bytes=999-'}).status_code==416
    assert c.get('/v1/packs/..%2Fsecret').status_code in (404,422)
    (tmp_path/'demo.bin').write_bytes(b'corrupted')
    assert c.get('/v1/packs/demo').status_code==503


def test_resume_range_if_range_and_head(tmp_path, monkeypatch):
    monkeypatch.setattr(module, 'PACKS', tmp_path)
    payload = b'0123456789abcdef'
    digest = hashlib.sha256(payload).hexdigest()
    (tmp_path/'demo.bin').write_bytes(payload)
    (tmp_path/'catalog.json').write_text(json.dumps([{
        'pack_id':'demo', 'scope':'country', 'scope_id':'KZ', 'size_bytes':len(payload),
        'sha256':digest, 'source_version':'1', 'license':'test-only',
        'verified':False, 'layers':['raster-mbtiles']
    }]))
    client = TestClient(module.app)
    good = client.get('/v1/packs/demo',headers={'Range':'bytes=4-7','If-Range':f'"{digest}"'})
    assert good.status_code == 206
    assert good.content == b'4567'
    assert good.headers['content-range'] == 'bytes 4-7/16'
    stale = client.get('/v1/packs/demo',headers={'Range':'bytes=4-7','If-Range':'"stale"'})
    assert stale.status_code == 200 and stale.content == payload
    head = client.head('/v1/packs/demo')
    assert head.status_code == 200 and head.headers['content-length'] == str(len(payload))
    assert head.content == b''
    assert client.get('/v1/packs/demo',headers={'Range':'bytes=-3'}).content == b'def'
    assert client.get('/v1/packs/demo',headers={'Range':'bytes=1-0'}).status_code == 416
