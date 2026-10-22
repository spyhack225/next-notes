"""Public comparison and pinned download contracts, without model downloads."""
import json
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]

class CatalogTests(unittest.TestCase):
 def test_measured_values_match_retained_evidence(self):
  actual=json.loads((ROOT/'shared/asr-models.json').read_text())
  evidence=json.loads((ROOT/'Tests/Reports/asr-live-latency-2026-10-22-resumed/comparison.json').read_text())['rows']
  self.assertEqual(len(actual),8)
  self.assertEqual({r['id'] for r in actual},{r['id'] for r in evidence})
  for row in actual:
   source=next(r for r in evidence if r['id']==row['id'])
   self.assertEqual(row['bytes'],source['model_bytes'])
   for lang,metrics in row['languages'].items():
    measured=source['languages'][lang]
    self.assertEqual(metrics['firstMs'],measured['first_text_ms']['median'])
    self.assertEqual(metrics['finalMs'],measured['release_to_final_ms']['median'])
    self.assertAlmostEqual(metrics['wordAccuracy'],100*(1-measured['previous_full_fixture_wer']))
 def test_downloads_only_publishable_model_artifacts(self):
  files=json.loads((ROOT/'shared/asr-artifacts.json').read_text())
  self.assertEqual(len(files),7) # Installed v3 uses its existing verified cache.
  for specs in files.values():
   self.assertTrue(specs)
   for s in specs:
    self.assertFalse(s['path'].startswith(('.', '/')))
    self.assertNotIn('..',s['path'].split('/'))
    self.assertTrue(s['url'].startswith('https://huggingface.co/'))
    self.assertEqual(len(s['sha256']),64)
    self.assertGreater(s['bytes'],0)

if __name__=='__main__':unittest.main()
