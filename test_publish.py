import hashlib
import sqlite3
import pytest
from fastapi.testclient import TestClient
from server.publish_mbtiles import publish
from server import app as module


def raster_file(path):
    with sqlite3.connect(path) as db:
        db.execute('create table metadata (name text, value text)')
        db.execute('create table tiles (zoom_level integer, tile_column integer, tile_row integer, tile_data blob)')
        db.execute("insert into metadata values ('format','png')")
        db.execute("insert into tiles values (0,0,0,?)", (b'fake-png-payload',))


def test_publish_and_range(tmp_path, monkeypatch):
    source = tmp_path / 'source.mbtiles'
    raster_file(source)
    folder = tmp_path / 'published'
    result = publish(source, 'kz-demo-v1', 'country', 'KZ', 'test-only', '1.0', False, folder)
    assert result['tile_count'] == 1
    assert result['sha256'] == hashlib.sha256((folder / 'kz-demo-v1.bin').read_bytes()).hexdigest()
    monkeypatch.setattr(module, 'PACKS', folder)
    client = TestClient(module.app)
    manifest = client.get('/v1/packs/manifest', params={'scope': 'country', 'id': 'KZ'}).json()
    assert manifest[0]['layers'] == ['raster-mbtiles']
    assert client.get('/v1/packs/kz-demo-v1', headers={'Range':'bytes=0-9'}).status_code == 206
    with pytest.raises(ValueError):
        publish(source, 'kz-demo-v1', 'country', 'KZ', 'test-only', '1.0', False, folder)


def test_reject_nonraster(tmp_path):
    path = tmp_path / 'empty.mbtiles'
    with sqlite3.connect(path) as db:
        db.execute('create table metadata(name text,value text)')
        db.execute('create table tiles(zoom_level integer,tile_column integer,tile_row integer,tile_data blob)')
        db.execute("insert into metadata values ('format','pbf')")
        db.execute("insert into tiles values (0,0,0,?)", (b'data',))
    with pytest.raises(ValueError):
        publish(path, 'test', 'country', 'KZ', 'test-only', '1.0', False, tmp_path / 'output')
