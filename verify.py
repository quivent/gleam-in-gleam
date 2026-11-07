#!/usr/bin/env python3
"""Development-only verifier; not a delivered compiler/runtime dependency."""
from pathlib import Path
import datetime
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
PRIVATE_BOOTSTRAP = Path.home() / '.local/share/gleam-native/bootstrap/1.19.2/gleam'
gleam = os.environ.get('GLEAM') or shutil.which('gleam') or str(PRIVATE_BOOTSTRAP)


def run(args, **kwargs):
    result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True,
                            timeout=60, **kwargs)
    if result.returncode:
        raise SystemExit(result.stdout + result.stderr)
    return result


def sha(data):
    return hashlib.sha256(data).hexdigest()


run([gleam, 'format', '--check', 'src', 'test/oracle.gleam', 'examples'])
run([gleam, 'build', '--warnings-as-errors'])
suite = run(['node', '--test', 'test/native.test.mjs'])
tests = int(re.search(r'^# tests (\d+)$', suite.stdout, re.M)[1])
passed = int(re.search(r'^# pass (\d+)$', suite.stdout, re.M)[1])
failed = int(re.search(r'^# fail (\d+)$', suite.stdout, re.M)[1])
assert tests == passed and failed == 0
manifest = (ROOT / 'manifest.toml').read_text()
assert re.search(r'packages = \[\s*\]', manifest)
sources = {str(p.relative_to(ROOT)): sha(p.read_bytes())
           for p in sorted((ROOT / 'src').rglob('*.gleam'))}
examples = []
with tempfile.TemporaryDirectory(prefix='gleam-native-qualification-') as tmp:
    for name, expected in [
        ('fibonacci', '55\n'),
        ('control', '14\nfourteen\nFalse\nTrue\n-12345\n0\n-2\n'),
    ]:
        output = Path(tmp) / name
        run(['node', 'bootstrap.mjs', f'examples/{name}.gleam', str(output)])
        result = run([str(output)])
        assert result.stdout == expected and not result.stderr
        data = output.read_bytes()
        assert data[:4] == b'\x7fELF'
        phoff = struct.unpack_from('<Q', data, 32)[0]
        phentsize, phnum = struct.unpack_from('<HH', data, 54)
        headers = [struct.unpack_from('<II', data, phoff + i * phentsize)
                   for i in range(phnum)]
        assert all(kind not in (2, 3) for kind, _ in headers)
        assert (0x6474e551, 6) in headers
        examples.append(dict(name=name, bytes=len(data), sha256=sha(data),
                             exitCode=result.returncode, stdout=result.stdout,
                             dynamicLoader=False, dynamicLibraries=[],
                             nonExecutableStack=True))
        # Verify the stage-0 bridge preserves existing output bytes on retry.
        before = output.read_bytes()
        refused = subprocess.run(['node', 'bootstrap.mjs', f'examples/{name}.gleam', str(output)],
                                 cwd=ROOT, capture_output=True, text=True, timeout=10)
        assert refused.returncode != 0 and output.read_bytes() == before

receipt = dict(
    schema='gleam-in-gleam.seed-verification/1',
    observedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    bootstrapCompiler=run([gleam, '--version']).stdout.strip(),
    bootstrapNode=run(['node', '--version']).stdout.strip(),
    compilerSourceLanguage='Gleam',
    compilerModules=len(sources),
    compilerSourceLines=sum(len(p.read_text().splitlines()) for p in (ROOT / 'src').rglob('*.gleam')),
    declaredPackageDependencies=[],
    tests=dict(total=tests, passed=passed, failed=failed),
    sourceSHA256=sources,
    examples=examples,
    compilerRunsNatively=False,
    selfHosting=False,
    fullGleamCompatibility=False,
    nativeTarget='linux-x86_64',
    externalCodegenTools=[],
    limitations=['Subset compiler; bootstrap still uses upstream Gleam and Node',
                 'No lists/ADTs/closures/module imports or polymorphic inference yet',
                 'No native compiler file IO or automatic memory management yet',
                 'Fixed-width integer and diagnostic formatting limitations documented in README'],
)
evidence = ROOT / 'evidence'
evidence.mkdir(exist_ok=True)
(evidence / 'seed-verification.json').write_text(json.dumps(receipt, indent=2) + '\n')
(evidence / 'seed-test-output.tap').write_text(suite.stdout)
print(json.dumps({k: v for k, v in receipt.items() if k != 'sourceSHA256'}, indent=2))
