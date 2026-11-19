import json
import sqlite3
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from map_catalog_server import catalog, handler_factory


class CatalogServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.folder = Path(self.temp.name)
        self.file = self.folder / 'almaty_osm.mbtiles'
        with sqlite3.connect(self.file) as db:
            db.execute('CREATE TABLE metadata (name TEXT PRIMARY KEY, value TEXT)')
            db.executemany('INSERT INTO metadata VALUES (?,?)', [('format', 'png'), ('bounds', '76.9,43.2,77.0,43.3'), ('name', 'Almaty'), ('version', '1')])
            db.execute('CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB)')
            db.execute('INSERT INTO tiles VALUES (9,1,1,?)', (b'PNG',))
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), handler_factory(self.folder))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f'http://127.0.0.1:{self.server.server_port}'

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(); self.temp.cleanup()

    def get(self, route, headers=None):
        with urlopen(Request(self.base + route, headers=headers or {})) as response:
            return response.status, dict(response.headers), response.read()

    def test_point_coverage(self):
        _, _, body = self.get('/v1/packs/at-point?lat=43.25&lon=76.95')
        self.assertEqual(json.loads(body)[0]['pack_id'], 'almaty_osm')
        _, _, body = self.get('/v1/packs/at-point?lat=44&lon=77')
        self.assertEqual(json.loads(body), [])

    def test_manifest_matches_client_schema(self):
        _, _, body = self.get('/v1/packs/manifest?scope=region&id=Almaty')
        pack = json.loads(body)[0]
        self.assertEqual(pack['layers'], ['raster-mbtiles'])
        self.assertEqual(len(pack['sha256']), 64)
        self.assertEqual(pack['size_bytes'], self.file.stat().st_size)

    def test_range_and_etag(self):
        pack = catalog(self.folder)[0][0]
        status, headers, body = self.get('/v1/packs/almaty_osm', {'Range': 'bytes=0-127', 'If-Range': '"'+pack['sha256']+'"'})
        self.assertEqual(status, 206)
        self.assertEqual(len(body), 128)
        self.assertEqual(headers['Content-Range'], f'bytes 0-127/{pack["size_bytes"]}')
        self.assertEqual(body, self.file.read_bytes()[:128])

    def test_bad_range_rejected(self):
        with self.assertRaises(HTTPError) as context:
            self.get('/v1/packs/almaty_osm', {'Range': 'bytes=0-999999999'})
        self.assertEqual(context.exception.code, 416)

    def test_path_traversal_rejected(self):
        with self.assertRaises(HTTPError):
            self.get('/v1/packs/..%2Fsecret')

    def test_invalid_coords(self):
        with self.assertRaises(HTTPError) as context:
            self.get('/v1/packs/at-point?lat=NaN&lon=77')
        self.assertEqual(context.exception.code, 400)


if __name__ == '__main__':
    unittest.main()
