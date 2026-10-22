"""Boundary tests for registration, public projection and evidence discovery; no models."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import sys
import subprocess
import io
import tarfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('benchmarks', Path(__file__).with_name('benchmarks.py'))
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.old = b.ROOT
        b.ROOT = self.root
        self.addCleanup(setattr, b, 'ROOT', self.old)
        (self.root / 'Benchmarks/runs').mkdir(parents=True)
        (self.root / 'Tests/Reports').mkdir(parents=True)
        (self.root / 'Tests/Reports/evidence.json').write_text('{"private_transcript":"DO_NOT_PUBLISH"}')
        self.run = json.loads((self.old / 'Benchmarks/templates/run.json').read_text())
        self.run.update(id='2026-10-22-test', sources=['Tests/Reports/evidence.json'])

    def save(self, run=None):
        run = run or self.run
        (self.root / 'Benchmarks/runs' / (run['id'] + '.json')).write_text(json.dumps(run))

    def test_unreviewed_run_never_reaches_public_page(self):
        self.save()
        with patch.object(b, 'scan', return_value=[]):
            generated = b.outputs()
        public = json.loads(generated[self.root / 'site/src/generated/benchmarks.json'])
        self.assertEqual(public['runs'], [])
        self.assertIn(self.run['title'], generated[self.root / 'Benchmarks/README.md'])

    def test_public_projection_does_not_read_raw_payload_or_export_provenance(self):
        self.run['publication'] = dict(approved=True, reviewed_by='reviewer', reviewed_on='2026-10-22')
        self.run['provenance'] = {'private_value': 'DO_NOT_PUBLISH'}
        self.run['extra_private_field'] = 'DO_NOT_PUBLISH'
        self.save()
        with patch.object(b, 'scan', return_value=[]):
            public = b.outputs()[self.root / 'site/src/generated/benchmarks.json']
        self.assertNotIn('DO_NOT_PUBLISH', public)
        self.assertNotIn('sources', public)
        self.assertEqual(len(json.loads(public)['runs']), 1)

    def test_reject_external_traversal_symlink_and_missing_sources(self):
        for source in ['/etc/passwd', '../private.txt', 'missing.json']:
            with self.subTest(source=source), self.assertRaises(AssertionError):
                b.validate(dict(self.run, sources=[source]))
        (self.root / 'escape').symlink_to('/etc/passwd')
        with self.assertRaises(AssertionError):
            b.validate(dict(self.run, sources=['escape']))

    def test_publication_requires_reviewer(self):
        self.run['publication']['approved'] = True
        with self.assertRaises(AssertionError):
            b.validate(self.run)

    def test_unrun_rejects_measurement_and_nan(self):
        metric = dict(name='first PCM', value=10, unit='ms', boundary='request to generated PCM', samples=1, aggregation='single observation')
        self.run['metrics'] = [metric]
        with self.assertRaises(AssertionError):
            b.validate(self.run)
        self.run['status'] = 'measured'
        b.validate(self.run)
        metric['value'] = float('nan')
        with self.assertRaises(AssertionError):
            b.validate(self.run)

    def test_unknown_sample_count_stays_unknown(self):
        self.run['status'] = 'partial'
        self.run['metrics'] = [dict(name='legacy median', value=10, unit='ms', boundary='unknown legacy clock', samples=None, aggregation='reported median')]
        self.assertIsNone(b.validate(self.run)['metrics'][0]['samples'])

    def test_generator_is_deterministic_and_check_detects_stale_output(self):
        self.save()
        with patch.object(b, 'scan', return_value=[]):
            b.render()
            b.render(check=True)
            (self.root / 'Benchmarks/README.md').write_text('stale')
            with self.assertRaises(AssertionError):
                b.render(check=True)

    def test_unique_filename_and_new_result_auto_discovery(self):
        self.save()
        other = copy.deepcopy(self.run)
        other['id'] += '-successor'
        self.save(other)
        self.assertEqual(len(b.load_runs()), 2)
        p = self.root / 'Benchmarks/runs' / (other['id'] + '.json')
        manifest = self.root / 'incoming.json'
        manifest.write_text(json.dumps(other))
        with patch.object(sys, 'argv', ['benchmarks.py', 'add', str(manifest)]):
            with self.assertRaises(FileExistsError):
                b.main()
        other['id'] = self.run['id']
        p.write_text(json.dumps(other))
        with self.assertRaises(AssertionError):
            b.load_runs()

    def test_active_log_append_does_not_make_catalog_stale(self):
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        for name in ('bench', 'docs', 'roadmap'):
            (self.root / name).mkdir()
        self.save()
        before = b.outputs()
        evidence = self.root / 'Tests/Reports/evidence.json'
        evidence.write_text('{"private_transcript":"DO_NOT_PUBLISH_MORE"}')
        self.assertEqual(before, b.outputs())

    def test_uncommitted_peer_report_cannot_create_missing_repo_links(self):
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        for name in ('bench', 'docs', 'roadmap'):
            (self.root / name).mkdir()
        subprocess.run(['git', '-C', str(self.root), 'add', 'Tests/Reports/evidence.json'], check=True)
        self.save()
        before = b.outputs()
        # Another agent has not checkpointed this report: a clean CI checkout
        # cannot resolve a generated link to it. Registered runs remain separate.
        (self.root / 'Tests/Reports/peer-in-progress.md').write_text('Synthetic unfinished peer report')
        self.assertEqual(before, b.outputs())

    def test_retired_snapshot_evidence_remains_discoverable(self):
        def git(*args):
            return subprocess.check_output(['git', '-C', str(self.root), '-c', 'user.name=Catalog fixture',
                '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false', '-c', 'gc.auto=0', *args], stderr=subprocess.DEVNULL).decode().strip()
        git('init', '-q', '-b', 'main')
        (self.root / 'README.md').write_text('Synthetic root')
        git('add', 'README.md')
        git('commit', '-qm', 'root')
        initial = git('rev-parse', 'HEAD')
        legacy = self.root / 'Tests/Reports/legacy.md'
        legacy.write_text('Synthetic historical measurement')
        archive = self.root / '.worktree-preservation/ignored.tar.gz'
        archive.parent.mkdir()
        with tarfile.open(archive, 'w:gz') as tf:
            payload = b'Synthetic ignored measurement'
            member = tarfile.TarInfo('Tests/Reports/ignored.md')
            member.size = len(payload)
            tf.addfile(member, io.BytesIO(payload))
        git('add', str(legacy.relative_to(self.root)), str(archive.relative_to(self.root)))
        git('commit', '-qm', 'candidate snapshot')
        snapshot = git('rev-parse', 'HEAD')
        blob = git('rev-parse', snapshot + ':.worktree-preservation/ignored.tar.gz')
        git('checkout', '-q', '-B', 'main', initial)
        git('merge', '--no-ff', '-s', 'ours', '-m', 'retain candidate history', snapshot)
        self.assertFalse(legacy.exists())
        for name in ('bench', 'docs', 'roadmap'):
            (self.root / name).mkdir(exist_ok=True)
        registry = self.root / 'Benchmarks/inventory/worktree-repair-fixture/snapshots.json'
        registry.parent.mkdir(parents=True)
        registry.write_text(json.dumps([dict(name='fixture', snapshot_commit=snapshot,
            ignored_paths=['Tests/Reports/ignored.md'], ignored_archive_git_blob=blob)]))
        b.audit()
        summary = json.loads((self.root / 'Benchmarks/inventory/git-audit-summary.json').read_text())
        sources = [r for r in summary['refs'] if r['ref'] == 'preserved/fixture']
        self.assertEqual(len(sources), 1)
        self.assertEqual(sources[0]['evidence_files'], 2)
        historical = (self.root / 'Benchmarks/inventory/historical.md').read_text()
        self.assertIn('git show ' + snapshot + ':Tests/Reports/legacy.md', historical)
        self.assertIn('| tar -xzOf - Tests/Reports/ignored.md', historical)

    def test_evidence_scope_excludes_vendor_references_and_assets(self):
        self.assertTrue(b.evidence_path('roadmap/done/MEETING/README.md'))
        self.assertTrue(b.evidence_path('Tests/Reports/failed-run.json'))
        self.assertFalse(b.evidence_path('roadmap/references/vendor/README.md'))
        self.assertFalse(b.evidence_path('docs/assets/private.json'))


if __name__ == '__main__':
    unittest.main()
