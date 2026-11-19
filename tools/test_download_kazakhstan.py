import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from download_kazakhstan import download, sha256

class Response(io.BytesIO):
    def __init__(self, data, status=200, headers=None):
        super().__init__(data)
        self.status = status
        self.headers = headers or {'Content-Length': str(len(data))}

class DownloadTests(unittest.TestCase):
    def test_new_download(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp)/'kz.pbf'
            download(dest, opener=lambda *a, **kw: Response(b'X'*2048))
            self.assertEqual(dest.read_bytes(), b'X'*2048)
            self.assertFalse(dest.with_name('kz.pbf.part').exists())
    def test_resume(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp)/'kz.pbf'
            dest.with_name('kz.pbf.part').write_bytes(b'X'*1024)
            download(dest, opener=lambda *a, **kw: Response(b'Y'*1024,206,{'Content-Length':'1024','Content-Range':'bytes 1024-2047/2048'}))
            self.assertEqual(dest.read_bytes(), b'X'*1024+b'Y'*1024)
    def test_bad_resume_never_appends(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp)/'kz.pbf'
            dest.with_name('kz.pbf.part').write_bytes(b'X'*1024)
            with self.assertRaises(RuntimeError):
                download(dest, opener=lambda *a, **kw: Response(b'Y'*2048))
            self.assertFalse(dest.exists())
    def test_checksum(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'x';p.write_bytes(b'abc')
            self.assertEqual(sha256(p),'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')

if __name__ == '__main__': unittest.main()
