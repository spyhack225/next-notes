import gzip
import json
import unittest
from Scripts.redact_benchmark_processes import redact_report


class PublicProcessPrivacy(unittest.TestCase):
    raw=' PID %CPU RSS COMMAND\n 12 1.2 123 node --api-key PRIVATE_FAKE_KEY\n'
    def test_json_keeps_timing_and_process_numbers(self):
        raw=json.dumps({'before':{'processes':self.raw},'latency':0.125}).encode()
        fixed=redact_report('Tests/Reports/run/context.json',raw)
        self.assertNotIn(b'PRIVATE_FAKE_KEY',fixed)
        data=json.loads(fixed)
        self.assertEqual(data['latency'],0.125)
        self.assertIn('12 1.2 123',data['before']['processes'])
    def test_jsonl_and_gzip(self):
        raw=(json.dumps({'processes':self.raw})+'\n').encode()
        result=redact_report('evidence/run/machine.jsonl.gz',gzip.compress(raw))
        self.assertNotIn(b'PRIVATE_FAKE_KEY',gzip.decompress(result))
    def test_text_table(self):
        self.assertNotIn(b'PRIVATE_FAKE_KEY',redact_report('evidence/processes-before.txt',self.raw.encode()))
    def test_structured_process(self):
        raw=json.dumps({'processes':[{'pid':1,'rss':42,'command':'node --api-key PRIVATE_FAKE_KEY'}]}).encode()
        self.assertEqual(json.loads(redact_report('Tests/Reports/run/context.json',raw))['processes'],[{'pid':1,'rss':42}])
    def test_safe_numeric_context_unchanged(self):
        raw=b'{"processes":"PID %CPU RSS\\n12 1.2 123\\n"}'
        self.assertEqual(redact_report('Tests/Reports/run/context.json',raw),raw)
    def test_source_and_authored_fixture_unchanged(self):
        raw=self.raw.encode()
        self.assertEqual(redact_report('Sources/example.swift',raw),raw)
        self.assertEqual(redact_report('Tests/Reports/run/control.swift.txt',raw),raw)
    def test_headerless_titles_are_not_a_privacy_boundary(self):
        raw=json.dumps({'processes':['123 node --authorization PRIVATE_FAKE_KEY']}).encode()
        self.assertNotIn(b'PRIVATE_FAKE_KEY',redact_report('Tests/Reports/run/context.json',raw))
    def test_hardware_identifiers_omitted_not_build_pins(self):
        raw=json.dumps({'hardware_uuid':'PRIVATE_FAKE_ID','macho_uuid':'public-build-pin','latency':12}).encode()
        fixed=json.loads(redact_report('Tests/Reports/run/context.json',raw))
        self.assertNotIn('hardware_uuid',fixed)
        self.assertEqual(fixed['macho_uuid'],'public-build-pin')
