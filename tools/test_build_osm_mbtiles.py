import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from build_osm_mbtiles import build, tile_xy

class BuildTilesTests(unittest.TestCase):
    def test_mercator_origin(self):
        self.assertEqual(tile_xy(0, 0, 0), (0.5, 0.5))
    def test_real_geojson_pipeline(self):
        with tempfile.TemporaryDirectory() as td:
            source = Path(td) / 'source.geojson'
            target = Path(td) / 'out.mbtiles'
            source.write_text(json.dumps({'type':'FeatureCollection','features':[{'type':'Feature','properties':{'highway':'path'},'geometry':{'type':'LineString','coordinates':[[76.9,43.2],[76.91,43.21]]}}]}))
            self.assertGreater(build(source,target,(76.89,43.19,76.92,43.22),10,11,100),0)
            with sqlite3.connect(target) as conn:
                self.assertEqual(conn.execute('PRAGMA integrity_check').fetchone()[0], 'ok')
                self.assertEqual(conn.execute("SELECT value FROM metadata WHERE name='format'").fetchone()[0], 'png')
                self.assertGreater(conn.execute('SELECT count(*) FROM tiles').fetchone()[0],0)
    def test_empty_source_refused(self):
        with tempfile.TemporaryDirectory() as td:
            source = Path(td) / 'empty.geojson'
            source.write_text('{"type":"FeatureCollection","features":[]}')
            with self.assertRaises(ValueError): build(source,Path(td)/'out.mbtiles',(76,43,77,44),10,10,100)
    def test_tile_budget(self):
        with tempfile.TemporaryDirectory() as td:
            source = Path(td) / 'source.geojson'
            source.write_text('{"type":"FeatureCollection","features":[{"type":"Feature","properties":{},"geometry":{"type":"Point","coordinates":[76,43]}}]}')
            with self.assertRaises(ValueError): build(source,Path(td)/'out.mbtiles',(70,40,80,50),12,12,2)

if __name__ == '__main__': unittest.main()
