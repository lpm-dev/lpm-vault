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
            notices = root / 'THIRD_PARTY_NOTICES.html'
            notices.write_bytes(b'notices')
            provenance = dict(repository=engine.REPOSITORY, revision='a' * 40, abiVersion=1, toolchain='1.94.0', targets=engine.TARGETS, sources={'Cargo.lock': 'b' * 64}, artifacts={'LPMEnv.xcframework/library': hashlib.sha256(b'library').hexdigest()}, notices=hashlib.sha256(b'notices').hexdigest())
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
            notices.write_bytes(b'tampered')
            with self.assertRaisesRegex(ValueError, 'notices'):
                engine.verify(root)
            notices.unlink()
            with self.assertRaisesRegex(ValueError, 'notices'):
                engine.verify(root)
            notices.write_bytes(b'notices')
            manifest.write_text(json.dumps({key: value for key, value in provenance.items() if key != 'notices'}))
            with self.assertRaisesRegex(ValueError, 'notices'):
                engine.verify(root)
            manifest.write_text(json.dumps(provenance))
            self.assertEqual(engine.verify(root), provenance)
            for field, value in [('revision', 'main'), ('repository', 'https://example.test/source'), ('sources', {'../escape': 'b' * 64})]:
                with self.subTest(field=field):
                    changed = dict(provenance, **{field: value})
                    manifest.write_text(json.dumps(changed))
                    with self.assertRaises(ValueError):
                        engine.verify(root)

    def test_contract_fixtures_match_their_recorded_hashes_exactly(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = root / 'LPMEnv.xcframework/library'
            artifact.parent.mkdir()
            artifact.write_bytes(b'library')
            (root / 'THIRD_PARTY_NOTICES.html').write_bytes(b'notices')
            fixture = root / 'fixtures/companion/markers.json'
            fixture.parent.mkdir(parents=True)
            fixture.write_bytes(b'{"cases": []}')
            provenance = dict(repository=engine.REPOSITORY, revision='a' * 40, abiVersion=1, toolchain='1.94.0', targets=engine.TARGETS, sources={'Cargo.lock': 'b' * 64}, artifacts={'LPMEnv.xcframework/library': hashlib.sha256(b'library').hexdigest()}, notices=hashlib.sha256(b'notices').hexdigest(), fixtures={'fixtures/companion/markers.json': hashlib.sha256(b'{"cases": []}').hexdigest()})
            manifest = root / 'provenance.json'
            manifest.write_text(json.dumps(provenance))
            self.assertEqual(engine.verify(root), provenance)
            fixture.write_bytes(b'{"cases": [1]}')
            with self.assertRaisesRegex(ValueError, 'fixtures'):
                engine.verify(root)
            fixture.write_bytes(b'{"cases": []}')
            unrecorded = fixture.with_name('extra.json')
            unrecorded.write_bytes(b'{}')
            with self.assertRaisesRegex(ValueError, 'fixtures'):
                engine.verify(root)
            unrecorded.unlink()
            fixture.unlink()
            with self.assertRaisesRegex(ValueError, 'fixtures'):
                engine.verify(root)


if __name__ == '__main__':
    unittest.main()
