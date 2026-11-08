#!/usr/bin/env python3
"""Execute the workflow's shell steps against isolated GitHub CLI fixtures."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / '.github/workflows/release.yml').read_text()


def script(step):
    text = WORKFLOW.split('      - name: ' + step + '\n', 1)[1]
    text = text.split('      - name: ', 1)[0]
    lines = text.split('        run: |\n', 1)[1].splitlines()
    result = []
    for line in lines:
        if line and not line.startswith('          '):
            break
        result.append(line[10:])
    return '\n'.join(result)


class WorkflowTests(unittest.TestCase):
    def test_version_gate(self):
        with tempfile.TemporaryDirectory() as d:
            for kind, name, success in [('branch', 'main', True), ('tag', 'v1.0.0', True),
                                         ('tag', 'v9.9.9', False), ('tag', 'v1.0.0-rc1', False)]:
                root = Path(d)
                (root / 'Sources/Core').mkdir(parents=True, exist_ok=True)
                (root / 'Sources/Core/Environment.swift').write_text('static let string = "1.0.0"')
                result = subprocess.run(['bash', '-c', script('Validate version')], cwd=root,
                    env=dict(os.environ, REF_TYPE=kind, REF_NAME=name, GITHUB_OUTPUT=str(root/'output')),
                    capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, success, result.stderr)


if __name__ == '__main__':
    unittest.main()
