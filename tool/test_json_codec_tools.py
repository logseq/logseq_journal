#!/usr/bin/env python3
"""Exercise tool PPX compilation and the synthetic fixture admission boundary."""
import importlib.util
import json
import pathlib
import subprocess
import tempfile
import unittest
import sys

sys.dont_write_bytecode = True

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE = ROOT / 'logseq_overlay_db/tool/audit_journal_pagination.py'
spec = importlib.util.spec_from_file_location('audit_journal_pagination', MODULE)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class JsonCodecToolsTest(unittest.TestCase):
    def test_raw_probe_compiler_generates_roundtrip(self):
        source = r'''
type report = { cursor : int64; count : int option; names : string list }
[@@deriving yojson]
let () =
  let expected = { cursor = Int64.max_int; count = Some 2; names = ["a"; "b"] } in
  let wire = report_to_yojson expected in
  if report_of_yojson wire <> Ok expected then failwith "roundtrip";
  print_endline (Yojson.Safe.to_string wire)
'''
        with tempfile.TemporaryDirectory(prefix='json-codec-tools-') as directory:
            directory = pathlib.Path(directory)
            program = directory / 'probe.ml'
            program.write_text(source)
            executable = directory / 'probe'
            flags = getattr(audit, 'probe_ppx_flags', lambda: [])()
            result = subprocess.run(
                ['ocamlfind', 'ocamlopt', '-package', 'yojson,ppx_deriving_yojson.runtime',
                 '-linkpkg'] + flags + [str(program), '-o', str(executable)],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            wire = json.loads(subprocess.check_output([str(executable)], text=True))
            self.assertEqual(wire['cursor'], 9223372036854775807)
            self.assertEqual(wire['count'], 2)
            self.assertEqual(wire['names'], ['a', 'b'])

    def test_small_benchmark_reopens_generated_pending_outbox(self):
        executable = ROOT / '_build/default/logseq_overlay_db/tool/performance_benchmark.exe'
        self.assertTrue(executable.exists(), 'build performance_benchmark.exe before this integration test')
        result = subprocess.run([str(executable), '--block-count', '500', '--outbox-records', '1'],
                                cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['block_count'], 500)
        self.assertEqual(len(report['samples']), 1)
        sample = report['samples'][0]
        self.assertEqual(sample['active_outbox_records'], 1)
        self.assertGreater(sample['active_outbox_bytes'], 0)
        self.assertEqual(len(sample['reopen']), 5)
        self.assertEqual(len(sample['get_blocks_64']), 5)


if __name__ == '__main__':
    unittest.main()
