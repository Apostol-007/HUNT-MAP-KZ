import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from prepare_offline_map import PRESETS, prepare, validate_mbtiles

class PipelineTests(unittest.TestCase):
    def test_presets_are_bounded(self):
        from build_from_pbf import parse_bbox
        for bbox in PRESETS.values():
            self.assertEqual(parse_bbox(','.join(map(str,bbox))), bbox)
    def test_offline_without_pbf_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(ValueError, 'offline mode'):
                prepare(preset='almaty-city', cache=Path(temp)/'missing.pbf', offline=True)
    def test_invalid_tile_budget_does_not_download(self):
        with patch('prepare_offline_map.download') as downloader:
            with self.assertRaisesRegex(ValueError, 'tile budget'):
                prepare(preset='almaty-city', max_tiles=1)
            downloader.assert_not_called()
    def test_existing_pbf_skips_download_and_publishes_atomically(self):
        with tempfile.TemporaryDirectory() as temp:
            pbf = Path(temp)/'source.osm.pbf'
            pbf.write_bytes(b'fake')
            output = Path(temp)/'map.mbtiles'
            def fake_builder(source, staging, bounds, zmin, zmax, max_tiles, osmium):
                import sqlite3
                with sqlite3.connect(staging) as db:
                    db.execute('CREATE TABLE metadata (name TEXT, value TEXT)')
                    db.execute("INSERT INTO metadata VALUES ('format','png')")
                    db.execute('CREATE TABLE tiles (zoom_level INT,tile_column INT,tile_row INT,tile_data BLOB)')
                    db.execute("INSERT INTO tiles VALUES (9,1,1,x'89504e47')")
                return 1, 3
            with patch('prepare_offline_map.download') as downloader, patch('prepare_offline_map.build_pbf', fake_builder):
                result = prepare(preset='almaty-city', pbf=pbf, output=output)
            downloader.assert_not_called()
            self.assertEqual(validate_mbtiles(output), 1)
            self.assertEqual(result['features'], 3)
            self.assertTrue(output.with_suffix('.manifest.json').exists())
            self.assertFalse(output.with_name(output.name+'.building.mbtiles').exists())

if __name__ == '__main__': unittest.main()
