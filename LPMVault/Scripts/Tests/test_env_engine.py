import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('engine', Path(__file__).resolve().parents[1] / 'verify-env-engine.py')
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)


class EngineIntegrityTests(unittest.TestCase):
    def test_archive_hashing_streams_without_reading_the_complete_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'library'
            data = b'0123456789abcdef' * 262144
            path.write_bytes(data)
            with patch.object(Path, 'read_bytes', side_effect=AssertionError('whole file read')):
                self.assertEqual(engine.digest(path), hashlib.sha256(data).hexdigest())

    def test_bundle_rejects_tampering_extra_files_and_unpinned_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = root / 'LPMEnv.xcframework/library'
            artifact.parent.mkdir()
            artifact.write_bytes(b'library')
            provenance = dict(repository=engine.REPOSITORY, revision='a' * 40, abiVersion=1, toolchain='1.94.0', targets=engine.TARGETS, sources={'Cargo.lock': 'b' * 64}, artifacts={'LPMEnv.xcframework/library': hashlib.sha256(b'library').hexdigest()})
            manifest = root / 'provenance.json'
            manifest.write_text(json.dumps(provenance))
            self.assertEqual(engine.verify(root), provenance)
            artifact.write_bytes(b'tampered')
            with self.assertRaises(ValueError):
                engine.verify(root)
            artifact.write_bytes(b'library')
            extra = artifact.with_name('extra')
            extra.write_bytes(b'extra')
            with self.assertRaises(ValueError):
                engine.verify(root)
            extra.unlink()
            for field, value in [('revision', 'main'), ('repository', 'https://example.test/source'), ('sources', {'../escape': 'b' * 64})]:
                with self.subTest(field=field):
                    changed = dict(provenance, **{field: value})
                    manifest.write_text(json.dumps(changed))
                    with self.assertRaises(ValueError):
                        engine.verify(root)


if __name__ == '__main__':
    unittest.main()
