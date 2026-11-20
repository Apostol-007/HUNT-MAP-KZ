import sqlite3
import tempfile
import unittest
from pathlib import Path
from build_raster_mbtiles import build

class MBTilesTests(unittest.TestCase):
    def test_xyz_to_tms(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            tile = root / 'xyz/2/1/2.png'
            tile.parent.mkdir(parents=True)
            tile.write_bytes(b'\x89PNG\r\n\x1a\nexample')
            out = root / 'map.mbtiles'
            self.assertEqual(build(root / 'xyz', out, 'Test', 'Test data')['tiles'], 1)
            with sqlite3.connect(out) as db:
                self.assertEqual(db.execute('SELECT zoom_level,tile_column,tile_row FROM tiles').fetchone(), (2,1,1))
                self.assertEqual(db.execute("SELECT value FROM metadata WHERE name='format'").fetchone()[0], 'png')
    def test_missing_attribution(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(ValueError): build(Path(d), Path(d)/'a.mbtiles', 'Test', '')
    def test_empty(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(ValueError): build(Path(d), Path(d)/'a.mbtiles', 'Test', 'Test')

if __name__ == '__main__': unittest.main()
