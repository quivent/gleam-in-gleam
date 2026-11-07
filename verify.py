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


run([gleam, 'format', '--check', 'src', 'test', 'examples'])
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
disassemblies = []
evidence = ROOT / 'evidence'
evidence.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='gleam-native-qualification-') as tmp:
    for name, expected in [
        ('fibonacci', '55\n'),
        ('control', '14\nfourteen\nFalse\nTrue\n-12345\n0\n-2\n'),
        ('collections', '6\n3\n6\n6\n'),
        ('custom_types', '5\n23\n0\n'),
        ('generics_records', '21\n2\n21\n2\n'),
        ('functions', '22\n3\n4\n'),
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
        if name in ('collections', 'custom_types', 'generics_records', 'functions') and shutil.which('objdump'):
            entry = struct.unpack_from('<Q', data, 24)[0]
            load_base = struct.unpack_from('<Q', data, phoff + 16)[0]
            raw = Path(tmp) / f'{name}-code.bin'
            raw.write_bytes(data[entry - load_base:])
            listing = run(['objdump', '-D', '-b', 'binary', '-m', 'i386:x86-64',
                           f'--adjust-vma={entry}', str(raw)]).stdout
            # Preserve a stable path in the listing, not a disposable temp name.
            listing = listing.replace(str(raw), f'{name}-code.bin')
            listing = '\n'.join(line.rstrip() for line in listing.splitlines()) + '\n'
            disassemblies.append(dict(tool=run(['objdump', '--version']).stdout.splitlines()[0],
                               entryAddress=hex(entry), rawCodeSHA256=sha(raw.read_bytes()),
                               includesTrailingStaticData=True,
                               path=f'evidence/{name}-disassembly.txt'))
            (evidence / f'{name}-disassembly.txt').write_text(listing)
        examples.append(dict(name=name, bytes=len(data), sha256=sha(data),
                             exitCode=result.returncode, stdout=result.stdout,
                             dynamicLoader=False, dynamicLibraries=[],
                             nonExecutableStack=True))
        # Verify the stage-0 bridge preserves existing output bytes on retry.
        before = output.read_bytes()
        refused = subprocess.run(['node', 'bootstrap.mjs', f'examples/{name}.gleam', str(output)],
                                 cwd=ROOT, capture_output=True, text=True, timeout=10)
        assert refused.returncode != 0 and output.read_bytes() == before

oracle_cases = [
    ('known-local-variant', 'type A { Zero One(Int) } pub fn main() -> Nil { let a = One(7) let One(x) = a echo x Nil }', True, '7\n'),
    ('zero-field-is-not-callable', 'pub type A { Zero } pub fn main() -> A { Zero() }', False, ''),
    ('private-type-in-public-api', 'type A { Zero } pub fn main() -> A { Zero }', False, ''),
    ('unknown-variant-let', 'type A { Zero One(Int) } fn read(a: A) -> Int { let One(x) = a x } pub fn main() -> Nil { Nil }', False, ''),
    ('custom-result-names', 'type Result { Ok(Int) Error(String) } pub fn main() -> Nil { let Ok(x) = Ok(7) echo x Nil }', True, '7\n'),
    ('missing-variant', 'type A { First Second } fn read(a: A) -> Int { case a { First -> 1 } } pub fn main() -> Nil { Nil }', False, ''),
    ('wrong-field-type', 'pub type A { One(Int) } pub fn main() -> A { One(True) }', False, ''),
    ('nested-constructor-not-refined', 'type A { Zero One(Int) } type B { B(A) } pub fn main() -> Int { let B(One(x)) = B(One(1)) x }', False, ''),
    ('generic-repeated-parameter', 'type Same(a) { Same(a,a) } pub fn main() -> Nil { let x = Same(1,True) Nil }', False, ''),
    ('generic-argument-mismatch', 'type Box(a) { Box(a) } fn take(x: Box(Bool)) -> Nil { Nil } pub fn main() -> Nil { take(Box(1)) }', False, ''),
    ('label-declaration-order', 'type Pair { Pair(first: Int,second: Int) } pub fn main() -> Nil { let p = Pair(second: echo 2,first: echo 1) echo p.first echo p.second Nil }', True, '1\n2\n1\n2\n'),
    ('generic-record', 'type Box(a) { Box(value: a,count: Int) } pub fn main() -> Nil { let box = Box(count: 2,value: 7) let Box(value:,..) = box echo value echo box.count Nil }', True, '7\n2\n'),
    ('record-offset-mismatch', 'type V { A(x: Int,y: Bool) B(y: Bool,x: Int) } fn read(v: V) -> Int { v.x } pub fn main() -> Nil { Nil }', False, ''),
    ('record-template-mismatch', 'type V(a) { A(x: a) B(x: Int) } fn read(v: V(Int)) -> Int { v.x } pub fn main() -> Nil { Nil }', False, ''),
    ('label-positional-order', 'type Pair { Pair(x: Int,y: Int) } pub fn main() -> Nil { let p = Pair(y: 2,1) Nil }', False, ''),
    ('generic-function-instantiation', 'fn identity(x: a) -> a { x } pub fn main() -> Nil { echo identity(7) echo identity(True) Nil }', True, '7\nTrue\n'),
    ('higher-order-function', 'fn inc(x: Int) -> Int { x+1 } fn apply(f: fn(a) -> b,x: a) -> b { f(x) } pub fn main() -> Nil { echo apply(inc,7) Nil }', True, '8\n'),
    ('indirect-evaluation-order', 'fn add(a: Int,b: Int) -> Int { a+b } fn target() -> fn(Int,Int) -> Int { echo 1 add } pub fn main() -> Nil { echo target()(echo 2,echo 3) Nil }', True, '1\n2\n3\n5\n'),
    ('generic-rigid-body', 'fn f(x: a) -> a { 1 } pub fn main() -> Nil { Nil }', False, ''),
    ('generic-self-recursion', 'fn f(x: a) -> Int { f([x]) } pub fn main() -> Nil { Nil }', False, ''),
    ('generic-mutual-recursion', 'fn f(x: a) -> Int { g([x]) } fn g(y: b) -> Int { f(y) } pub fn main() -> Nil { Nil }', True, ''),
    ('private-function-type', 'type Private { Private } pub fn expose(f: fn(Private) -> Int) -> Nil { Nil } pub fn main() -> Nil { Nil }', False, ''),
]
oracle_results = []
with tempfile.TemporaryDirectory(prefix='gleam-native-upstream-acceptance-') as tmp:
    for name, source, accepted, expected in oracle_cases:
        project = Path(tmp) / name
        (project / 'src').mkdir(parents=True)
        (project / 'gleam.toml').write_text('name="grammar_oracle"\nversion="0.1.0"\ntarget="javascript"\n')
        (project / 'src/grammar_oracle.gleam').write_text(source)
        reference = subprocess.run([gleam, 'check', '--target', 'javascript'], cwd=project,
                                   capture_output=True, text=True, timeout=30)
        assert (reference.returncode == 0) == accepted, (name, reference.stdout, reference.stderr)
        executable = project / 'program'
        native = subprocess.run(['node', 'bootstrap.mjs', str(project / 'src/grammar_oracle.gleam'), str(executable)],
                                cwd=ROOT, capture_output=True, text=True, timeout=30)
        assert (native.returncode == 0) == accepted, (name, native.stdout, native.stderr)
        if accepted:
            observed = run([str(executable)])
            assert observed.stdout == expected
            built = subprocess.run([gleam, 'build'], cwd=project,
                                   capture_output=True, text=True, timeout=30)
            assert built.returncode == 0, (name, built.stdout, built.stderr)
            module = project / 'build/dev/javascript/grammar_oracle/grammar_oracle.mjs'
            evaluated = subprocess.run(['node', '--input-type=module', '-e',
                                        'import {main} from ' + json.dumps(module.as_uri()) + '; main();'],
                                       capture_output=True, text=True, timeout=30)
            assert evaluated.returncode == 0, (name, evaluated.stderr)
            clean = re.sub(r'\x1b\[[0-9;]*m', '', evaluated.stderr)
            values = [line for line in clean.splitlines()
                      if re.fullmatch(r'-?\d+|True|False|Nil', line)]
            rendered = '\n'.join(values) + ('\n' if values else '')
            assert rendered == expected, (name, clean, expected)
        else:
            assert not executable.exists()
        oracle_results.append(dict(name=name, source=source, accepted=accepted,
                                   upstreamRuntimeCompared=accepted,
                                   upstreamExit=reference.returncode, nativeExit=native.returncode,
                                   upstreamDiagnostic=reference.stderr.replace(str(project), '<oracle>'),
                                   nativeDiagnostic=native.stderr))
(evidence / 'functions-upstream-checks.json').write_text(json.dumps(oracle_results, indent=2) + '\n')

receipt = dict(
    schema='gleam-in-gleam.functions-verification/1',
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
    disassemblies=disassemblies,
    upstreamAcceptanceChecks=dict(total=len(oracle_results), agreed=len(oracle_results),
                                  path='evidence/functions-upstream-checks.json'),
    compilerRunsNatively=False,
    selfHosting=False,
    fullGleamCompatibility=False,
    nativeTarget='linux-x86_64',
    externalCodegenTools=[],
    limitations=['Subset compiler; bootstrap still uses upstream Gleam and Node',
                 'No polymorphic named function values/labelled function calls/record updates/closures/module imports yet',
                 'Bounded arena only: no collection or native compiler file IO yet',
                 'Compound structural equality/printing and complex coverage are not implemented',
                 'Fixed-width integer and diagnostic formatting limitations documented in README'],
)
(evidence / 'functions-verification.json').write_text(json.dumps(receipt, indent=2) + '\n')
(evidence / 'functions-test-output.tap').write_text(suite.stdout)
print(json.dumps({k: v for k, v in receipt.items() if k != 'sourceSHA256'}, indent=2))
