#!/usr/bin/env python3
"""Execute complete Gleam examples from GUIDE.md with a selected native compiler."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('compiler')
parser.add_argument('receipt')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
compiler = Path(args.compiler).resolve()
guide = root / 'GUIDE.md'
sha = lambda data: hashlib.sha256(data).hexdigest()
examples = re.findall(r'```gleam\n(.*?)```', guide.read_text(), re.S)
expected = ['42\n', '56\n', '7\nseven\n', '7\n', '14\n8\n',
            '15\n', '6\n', 'prefix:λ😀\n', '1\nTrue\n']
assert len(examples) == len(expected), 'Review expected behavior when editing guide examples'
report = dict(schema='gleam-in-gleam.guide-execution/1',
              observedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
              guideSHA256=sha(guide.read_bytes()),
              compilerSHA256=sha(compiler.read_bytes()),
              scope='Native compile/run of complete guide examples; not a new upstream conformance claim',
              complete=False, examples=[])
try:
    with tempfile.TemporaryDirectory(prefix='gig-guide-') as temporary:
        for index, (source, wanted) in enumerate(zip(examples, expected), 1):
            directory = Path(temporary) / str(index)
            directory.mkdir()
            (directory / 'main.gleam').write_text(source)
            output = directory / 'app'
            built = subprocess.run([str(compiler), 'main.gleam', str(output),
                                    '--source-root', str(directory)],
                                   capture_output=True, text=True, timeout=30, env={'PATH': ''})
            assert built.returncode == 0 and not built.stderr, (index, built.stderr)
            ran = subprocess.run([str(output)], capture_output=True, text=True,
                                 timeout=10, env={'PATH': ''})
            assert ran.returncode == 0 and ran.stdout == wanted and not ran.stderr, (index, ran)
            report['examples'].append(dict(example=index, sourceSHA256=sha(source.encode()),
                artifactSHA256=sha(output.read_bytes()), exitCode=ran.returncode, stdout=ran.stdout))
    report['complete'] = True
finally:
    Path(args.receipt).write_text(json.dumps(report, indent=2) + '\n')
print(f'{len(examples)} guide examples compiled and executed correctly')
