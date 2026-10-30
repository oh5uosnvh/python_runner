import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2] / 'main'
HOOKS = [ROOT / 'assets/python_hooks/http_debug_hook.py', ROOT / 'python/http_debug_hook.py']
PREFIX = '__HTTP_RECORD__'


class InterleavingStream:
    """Force two old-style print calls to write payloads before newlines."""
    def __init__(self):
        self.parts = []
        self.barrier = threading.Barrier(2)
        self.lock = threading.Lock()

    def write(self, text):
        with self.lock:
            self.parts.append(text)
        if text.startswith(PREFIX):
            self.barrier.wait(timeout=5)
        return len(text)

    def flush(self):
        pass


class HTTPRecordFramingTest(unittest.TestCase):
    def load_hook(self, path):
        old = os.environ.get('PYRUNNER_HTTP_HOOK_CONFIG')
        os.environ['PYRUNNER_HTTP_HOOK_CONFIG'] = '{"record_requests": false}'
        try:
            spec = importlib.util.spec_from_file_location('test_hook', path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            module._CFG['record_requests'] = True
            return module
        finally:
            if old is None:
                os.environ.pop('PYRUNNER_HTTP_HOOK_CONFIG', None)
            else:
                os.environ['PYRUNNER_HTTP_HOOK_CONFIG'] = old

    def test_old_print_can_generate_a_blank_line_and_corrupt_record(self):
        stream = InterleavingStream()
        def emit(i):
            print(PREFIX + json.dumps({'id': i}), file=stream, flush=True)
        threads = [threading.Thread(target=emit, args=(i,)) for i in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(6)
            self.assertFalse(thread.is_alive())
        lines = ''.join(stream.parts).splitlines()
        self.assertEqual(len(lines), 2)
        self.assertEqual(lines[1], '')
        with self.assertRaises(json.JSONDecodeError):
            json.loads(lines[0][len(PREFIX):])

    def test_concurrent_records_are_complete_and_real_blank_lines_survive(self):
        for path in HOOKS:
            with self.subTest(path=path):
                hook = self.load_hook(path)
                stream = io.StringIO()
                original = sys.stdout
                sys.stdout = stream
                try:
                    threads = [threading.Thread(target=lambda n=n: [hook._send_record({'id': n * 100 + i}) for i in range(100)]) for n in range(16)]
                    for thread in threads:
                        thread.start()
                    for thread in threads:
                        thread.join(10)
                        self.assertFalse(thread.is_alive())
                    print('')
                finally:
                    sys.stdout = original
                lines = stream.getvalue().splitlines()
                self.assertEqual(lines[-1], '')
                self.assertEqual(len(lines), 1601)
                records = [json.loads(line[len(PREFIX):]) for line in lines[:-1] if line.startswith(PREFIX)]
                self.assertEqual(len(records), 1600)
                self.assertEqual(len({record['id'] for record in records}), 1600)

    def test_limit_and_reset(self):
        for path in HOOKS:
            with self.subTest(path=path):
                hook = self.load_hook(path)
                hook._MAX_RECORDS_PER_SCRIPT = 2
                stream = io.StringIO()
                original = sys.stdout
                sys.stdout = stream
                try:
                    for i in range(5):
                        hook._send_record({'id': i})
                    hook._reset_record_count()
                    hook._send_record({'id': 99})
                finally:
                    sys.stdout = original
                records = [json.loads(line[len(PREFIX):]) for line in stream.getvalue().splitlines()]
                self.assertEqual([r.get('id') for r in records], [0, 1, None, 99])
                self.assertIn('note', records[2])


if __name__ == '__main__':
    unittest.main()
