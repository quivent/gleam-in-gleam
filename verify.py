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
suite = run(['node', '--test', 'test/native.test.mjs', 'test/modules.test.mjs', 'test/strings.test.mjs'])
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
        ('closures', '12\n22\n6\n'),
        ('record_updates', '3\n7\nTrue\n'),
        ('bit_arrays', '5\n9\n-2\n4660\n'),
        ('modules', '14\n8\n3\n'),
        ('aliases_guards', '7\n5\nTrue\nFalse\n'),
        ('strings_prelude', 'True\nTrue\nλ😀\n206\n187\n'),
        ('multi_patterns', '7\n9\n3\n'),
        ('structural_equality', 'True\nFalse\nTrue\nTrue\n'),
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
        if name in ('collections', 'custom_types', 'generics_records', 'functions', 'closures', 'record_updates', 'bit_arrays', 'modules', 'aliases_guards', 'strings_prelude', 'multi_patterns', 'structural_equality') and shutil.which('objdump'):
            entry = struct.unpack_from('<Q', data, 24)[0]
            load_base = struct.unpack_from('<Q', data, phoff + 16)[0]
            raw = Path(tmp) / f'{name}-code.bin'
            raw.write_bytes(data[entry - load_base:])
            listing = run(['objdump', '-D', '-b', 'binary', '-m', 'i386:x86-64',
                           f'--adjust-vma={entry}', str(raw)]).stdout
            # Preserve a stable path in the listing, not a disposable temp name.
            listing = listing.replace(str(raw), f'{name}-code.bin')
            listing = '\n'.join(line.rstrip() for line in listing.splitlines()) + '\n'
            listing_name = 'functions-descriptor' if name == 'functions' else name
            disassemblies.append(dict(tool=run(['objdump', '--version']).stdout.splitlines()[0],
                               entryAddress=hex(entry), rawCodeSHA256=sha(raw.read_bytes()),
                               includesTrailingStaticData=True,
                               path=f'evidence/{listing_name}-disassembly.txt'))
            (evidence / f'{listing_name}-disassembly.txt').write_text(listing)
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
    ('returned-closure-capture', 'fn make(n: Int) -> fn(Int) -> Int { fn(x) { n+x } } pub fn main() -> Nil { let f=make(7) echo f(3) Nil }', True, '10\n'),
    ('nested-closure-capture', 'fn make(n: Int) -> fn(Int) -> fn(Int) -> Int { fn(x) { fn(y) { n+x+y } } } pub fn main() -> Nil { let outer=make(7) let inner=outer(2) echo inner(3) Nil }', True, '12\n'),
    ('use-callback-scope', 'fn run(x: a,next: fn(a) -> b) -> b { next(x) } pub fn main() -> Nil { let offset=2 let value={ use x <- run(7) x+offset } echo value Nil }', True, '9\n'),
    ('use-tuple-pattern', 'fn run(x: a,next: fn(a) -> b) -> b { next(x) } pub fn main() -> Nil { let value={ use #(x,y) <- run(#(2,3)) x+y } echo value Nil }', True, '5\n'),
    ('use-lazy-continuation', 'fn skip(_next: fn() -> Int) -> Int { 7 } pub fn main() -> Nil { let value={ use <- skip() echo 999 9 } echo value Nil }', True, '7\n'),
    ('closure-wrong-return', 'fn run(f: fn(Int) -> Bool) -> Nil { Nil } pub fn main() -> Nil { run(fn(x) { x+1 }) }', False, ''),
    ('use-refutable-pattern', 'fn run(n: Int,f: fn(Int) -> Int) -> Int { f(n) } pub fn main() -> Int { use 1 <- run(1) 1 }', False, ''),
    ('discarded-callable', 'fn f(_g: fn() -> Int) -> Int { _g() } pub fn main() -> Nil { Nil }', False, ''),
    ('closure-case-context', 'fn make(n: Int,b: Bool) -> fn(Int) -> Int { case b { True -> fn(x) { n+x } False -> fn(x) { n-x } } } pub fn main() -> Nil { let f=make(7,True) echo f(3) Nil }', True, '10\n'),
    ('update-evaluation-order', 'type R { R(a: Int,b: Int) } fn old() -> R { echo 1 R(2,3) } pub fn main() -> Nil { let r=R(..old(),b: {echo 4 5},a: {echo 6 7}) echo r.a echo r.b Nil }', True, '1\n6\n4\n7\n5\n'),
    ('update-type-change', 'type Box(a) { Box(value: a) } pub fn main() -> Nil { let a=Box(1) let b=Box(..a,value: True) echo b.value Nil }', True, 'True\n'),
    ('update-unsafe-variant', 'type R { A(x: Int) B(x: Int) } fn update(r:R) -> R { A(..r,x:2) } pub fn main() -> Nil { Nil }', False, ''),
    ('update-known-variant', 'type R { A(x: Int) B(x: Int) } pub fn main() -> Nil { let a=A(1) let b=A(..a,x:2) echo b.x Nil }', True, '2\n'),
    ('update-empty', 'type R { R(x: Int) } pub fn main() -> Nil { let a=R(1) let b=R(..a) echo b.x Nil }', True, '1\n'),
    ('update-partial-type-change-rejected', 'type R(a) { R(x: a,y: a) } pub fn main() -> Nil { let a=R(1,2) let b=R(..a,x:True) Nil }', False, ''),
    ('update-unknown-label', 'type R { R(x: Int) } pub fn main() -> Nil { let a=R(1) let b=R(..a,y:2) Nil }', False, ''),
    ('update-original-effects', 'type R { R(x: Int) } pub fn main() -> Nil { let p=R(2) let q=R(..{echo 9 p},x:3) echo p.x echo q.x Nil }', True, '9\n2\n3\n'),
    ('update-zero-field-invalid', 'pub type R { R } pub fn main() -> R { let r=R R(..r) }', False, ''),
    ('update-phantom-type-change', 'type R(a) { R(x: Int) } fn change(r: R(Int)) -> R(Bool) { R(..r,x:3) } pub fn main() -> Nil { let r: R(Int)=R(1) let q=change(r) echo q.x Nil }', True, '3\n'),
    ('update-lambda-retained-context', 'type R(a) { R(f: fn(a) -> Int,x: a) } pub fn main() -> Nil { let p=R(fn(x: Int){x+1},3) let q=R(..p,f:fn(x){x+2}) let f=q.f echo f(q.x) Nil }', True, '5\n'),
    ('bits-signed-and-truncation', 'pub fn main() -> Nil { case <<257,-1,65537:16-little>> { <<a,b,c:16-little>> -> {echo a echo b echo c Nil} _ -> Nil } }', True, '1\n255\n1\n'),
    ('bits-signed-pattern', 'pub fn main() -> Nil { case <<255>> { <<n:signed>> -> {echo n Nil} _ -> Nil } }', True, '-1\n'),
    ('bits-concat-order', 'pub fn main() -> Nil { let a=<<{echo 1 7},{echo 2 <<8,9>>}:bits,{echo 3 99}:0>> case a { <<x,y,z>> -> {echo x echo y echo z Nil} _ -> Nil } }', True, '1\n2\n7\n8\n9\n'),
    ('bits-full-tail', 'pub fn main() -> Nil { let <<tail:bits>>=<<1,2>> case tail { <<x,y>> -> {echo x echo y Nil} _ -> Nil } }', True, '1\n2\n'),
    ('bits-exact-length-guard', 'fn f(a: BitArray) -> Int { case a { <<_,_,_>> -> 3 <<1,2>> -> 2 <<>> -> 0 _ -> 9 } } pub fn main() -> Nil { echo f(<<>>) echo f(<<1>>) echo f(<<1,2>>) echo f(<<1,2,3,4>>) Nil }', True, '0\n9\n2\n9\n'),
    ('bits-64-safe-range', 'pub fn main() -> Nil { case <<-2:64-little,1000000:64>> { <<a:64-little-signed,b:64>> -> {echo a echo b Nil} _ -> Nil } }', True, '-2\n1000000\n'),
    ('bits-64-literal-discard', 'pub fn main() -> Nil { let a=<<-1:64>> echo case a { <<-1:64>> -> 9 <<_:64>> -> 1 _ -> 0 } Nil }', True, '1\n'),
    ('bits-mismatching-literals', 'pub fn main() -> Nil { echo case <<255>> { <<256>> -> 9 <<-1>> -> 8 <<255:signed>> -> 7 <<-1:signed>> -> 1 _ -> 0 } Nil }', True, '1\n'),
    ('bits-unsigned-pattern', 'pub fn main() -> Nil { case <<255>> { <<n:unsigned>> -> {echo n Nil} _ -> Nil } }', True, '255\n'),
    ('bits-options-size', 'pub fn main() -> Nil { case <<4660:int-size(16)-little>> { <<n:unsigned-int-little-size(16)>> -> {echo n Nil} _ -> Nil } }', True, '4660\n'),
    ('bits-empty', 'pub fn main() -> Nil { echo case <<>> { <<>> -> 1 _ -> 0 } Nil }', True, '1\n'),
    ('bits-wrong-segment-type', 'pub fn main() -> Nil { let _a=<<True>> Nil }', False, ''),
    ('bits-wrong-concat-type', 'pub fn main() -> Nil { let _a=<<1:bits>> Nil }', False, ''),
    ('bits-pattern-only-sign', 'pub fn main() -> Nil { let _a=<<1:signed>> Nil }', False, ''),
    ('bits-pattern-only-bytes', 'pub fn main() -> Nil { let _a=<<<<1>>:bytes>> Nil }', False, ''),
    ('bits-duplicate-size', 'pub fn main() -> Nil { let _a=<<1:8-16>> Nil }', False, ''),
    ('bits-duplicate-endian', 'pub fn main() -> Nil { let _a=<<1:big-little>> Nil }', False, ''),
    ('bits-zero-pattern-size', 'fn f(a: BitArray) -> Int { case a { <<x:0>> -> x _ -> 0 } } pub fn main() -> Nil { Nil }', False, ''),
    ('bits-unsized-tail-last', 'fn f(a: BitArray) -> Int { case a { <<r:bits,x>> -> x _ -> 0 } } pub fn main() -> Nil { Nil }', False, ''),
    ('bits-nonexhaustive', 'fn f(a: BitArray) -> Int { case a { <<>> -> 0 <<_,rest:bits>> -> 1 } } pub fn main() -> Nil { Nil }', False, ''),
    ('bits-refutable-bytes-tail', 'fn f(a: BitArray) -> BitArray { let <<tail:bytes>>=a tail } pub fn main() -> Nil { Nil }', False, ''),
    ('bits-unbraced-expression', 'pub fn main() -> Nil { let _a=<<1+2>> Nil }', False, ''),
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
module_fixtures = (json.loads((ROOT / 'test/modules-fixtures.json').read_text())
                   + json.loads((ROOT / 'test/aliases-guards-fixtures.json').read_text())
                   + json.loads((ROOT / 'test/strings-prelude-fixtures.json').read_text())
                   + json.loads((ROOT / 'test/multi-pattern-fixtures.json').read_text())
                   + json.loads((ROOT / 'test/equality-fixtures.json').read_text()))
module_results = []
with tempfile.TemporaryDirectory(prefix='gleam-native-module-oracle-') as tmp:
    for fixture in module_fixtures:
        name, files, accepted = fixture['name'], fixture['files'], fixture['accepted']
        project = Path(tmp) / name
        (project / 'src').mkdir(parents=True)
        (project / 'gleam.toml').write_text('name="module_oracle"\nversion="0.1.0"\ntarget="javascript"\n')
        for module_name, source in files.items():
            path = project / 'src' / (module_name + '.gleam')
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source)
        reference = subprocess.run([gleam, 'check', '--target', 'javascript'], cwd=project,
                                   capture_output=True, text=True, timeout=30)
        assert (reference.returncode == 0) == accepted, (name, reference.stdout, reference.stderr)
        output = project / 'native-program'
        native = subprocess.run(['node', str(ROOT / 'bootstrap.mjs'),
                                 str(project / 'src' / (fixture['entry'] + '.gleam')), str(output),
                                 '--source-root', str(project / 'src')],
                                capture_output=True, text=True, timeout=30)
        assert (native.returncode == 0) == accepted, (name, native.stdout, native.stderr)
        if accepted:
            actual = run([str(output)])
            assert actual.stdout == fixture['stdout'] and not actual.stderr
            built = subprocess.run([gleam, 'build'], cwd=project,
                                   capture_output=True, text=True, timeout=30)
            assert built.returncode == 0, (name, built.stderr)
            module = project / 'build/dev/javascript/module_oracle' / (fixture['entry'] + '.mjs')
            evaluated = subprocess.run(['node', '--input-type=module', '-e',
                                        'import {main} from ' + json.dumps(module.as_uri()) + '; main();'],
                                       capture_output=True, text=True, timeout=30)
            assert evaluated.returncode == 0, (name, evaluated.stderr)
            clean = re.sub(r'\x1b\[[0-9;]*m', '', evaluated.stderr)
            values = [line for line in clean.splitlines() if re.fullmatch(r'-?\d+|True|False|Nil', line)]
            rendered = '\n'.join(values) + ('\n' if values else '')
            assert rendered == fixture['stdout'], (name, clean, fixture['stdout'])
        else:
            assert not output.exists()
        module_results.append(dict(name=name, files=files, accepted=accepted,
                                   upstreamRuntimeCompared=accepted,
                                   upstreamExit=reference.returncode, nativeExit=native.returncode,
                                   upstreamDiagnostic=reference.stderr.replace(str(project), '<oracle>'),
                                   nativeDiagnostic=native.stderr.replace(str(project), '<oracle>')))
(evidence / 'structural-equality-project-upstream-checks.json').write_text(json.dumps(module_results, indent=2) + '\n')

(evidence / 'structural-equality-upstream-checks.json').write_text(json.dumps(oracle_results, indent=2) + '\n')

trace_script = f"""
import {{readFileSync}} from 'node:fs';
import {{BitArray,toList}} from {json.dumps((ROOT / 'build/dev/javascript/gleam_native/gleam.mjs').as_uri())};
import {{link,Source}} from {json.dumps((ROOT / 'build/dev/javascript/gleam_native/native/project.mjs').as_uri())};
const files = [
  ['modules','examples/modules.gleam'],
  ['module_demo/box','examples/module_demo/box.gleam'],
  ['module_demo/numbers','examples/module_demo/numbers.gleam']
];
const result=link('modules',toList(files.map(([name,path])=>new Source(name,new BitArray(readFileSync(path))))));
if (!result.isOk()) throw new Error(result[0]);
console.log(JSON.stringify({{functions:result[0].functions.toArray().map(f=>f.name),types:result[0].custom_types.toArray().map(t=>t.name),remainingImports:result[0].imports.toArray().length,remainingAliases:result[0].aliases.toArray().length}}));
"""
module_trace = json.loads(run(['node', '--input-type=module', '-e', trace_script]).stdout)
assert module_trace == dict(functions=['add@module_demo/numbers', 'twice@module_demo/numbers',
                                       'increment@module_demo/numbers', 'main'],
                            types=['Box@module_demo/box'], remainingImports=0, remainingAliases=0)

# Compile the actual owned core source, not a hand-copied implementation.
core_source = (ROOT / 'src/native/core.gleam').read_bytes()
core_driver = (ROOT / 'test/owned-core-driver.source').read_bytes()
with tempfile.TemporaryDirectory(prefix='gleam-owned-core-native-') as tmp:
    source = Path(tmp) / 'owned_core.gleam'
    output = Path(tmp) / 'owned-core'
    source.write_bytes(core_source + b'\n' + core_driver)
    run(['node', 'bootstrap.mjs', str(source), str(output)])
    observed = run([str(output)])
    assert observed.stdout == '3\n1234\nTrue\nTrue\n7\n3\n4\n9\nTrue\nTrue\n' and not observed.stderr
    owned_core = dict(source='src/native/core.gleam', sourceSHA256=sha(core_source),
                      driver='test/owned-core-driver.source', driverSHA256=sha(core_driver),
                      executableSHA256=sha(output.read_bytes()), bytes=len(output.read_bytes()),
                      exitCode=observed.returncode, stdout=observed.stdout,
                      oracle='native test compares current upstream-compiled core function results',
                      allSourceFunctionsCompiled=True, fullCompilerSelfHosting=False)
(evidence / 'owned-core-native-verification.json').write_text(json.dumps(owned_core, indent=2) + '\n')

def owned_project_receipt(entry, modules, driver_name, expected):
    driver = (ROOT / driver_name).read_bytes()
    source_hashes = {}
    with tempfile.TemporaryDirectory(prefix='gleam-owned-component-') as tmp:
        root = Path(tmp)
        for module in modules:
            original = (ROOT / 'src' / (module + '.gleam')).read_bytes()
            source_hashes['src/' + module + '.gleam'] = sha(original)
            output = root / (module + '.gleam')
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(original + (b'\n' + driver if module == entry else b''))
        output = root / 'component'
        run(['node', 'bootstrap.mjs', str(root / (entry + '.gleam')), str(output), '--source-root', str(root)])
        observed = run([str(output)])
        assert observed.stdout == expected and not observed.stderr
        return dict(entry=entry, sourceSHA256=source_hashes, driver=driver_name,
                    driverSHA256=sha(driver), executableSHA256=sha(output.read_bytes()),
                    bytes=len(output.read_bytes()), exitCode=observed.returncode, stdout=observed.stdout,
                    allSourceFunctionsCompiled=True, fullCompilerSelfHosting=False,
                    oracle='native test compares current upstream-compiled owned module function results')

owned_types = owned_project_receipt('native/type_system', ['native/type_system','native/core','native/ast'],
                    'test/owned-type-system-driver.source', 'Box(Int)\nTrue\nTrue\nTrue\nTrue\nTrue\nTrue\n')
owned_equality = owned_project_receipt('native/equality', ['native/equality','native/definitions','native/type_system','native/core','native/ast','native/prelude'],
                    'test/owned-equality-driver.source', '3\n0\n')
(evidence / 'owned-type-system-native-verification.json').write_text(json.dumps(owned_types, indent=2) + '\n')
(evidence / 'owned-equality-native-verification.json').write_text(json.dumps(owned_equality, indent=2) + '\n')

receipt = dict(
    schema='gleam-in-gleam.structural-equality-verification/1',
    observedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    bootstrapCompiler=run([gleam, '--version']).stdout.strip(),
    bootstrapNode=run(['node', '--version']).stdout.strip(),
    bootstrapBridgeSHA256=sha((ROOT / 'bootstrap.mjs').read_bytes()),
    compilerSourceLanguage='Gleam',
    compilerModules=len(sources),
    compilerSourceLines=sum(len(p.read_text().splitlines()) for p in (ROOT / 'src').rglob('*.gleam')),
    declaredPackageDependencies=[],
    tests=dict(total=tests, passed=passed, failed=failed),
    sourceSHA256=sources,
    examples=examples,
    disassemblies=disassemblies,
    upstreamAcceptanceChecks=dict(total=len(oracle_results), agreed=len(oracle_results),
                                  path='evidence/structural-equality-upstream-checks.json'),
    bitArrayRepresentation='arena descriptor: aligned size, tag -1, byte length, data pointer, root owner; owned payload or shared slice',
    bitArraySubset='byte-aligned construction/concat, fixed integer widths 0..64 construction and 8..64 matching; signed/unsigned matching, endian options, final unsized bits/bytes tails',
    projectCompilation=dict(sourceLanguage='Gleam', imports='local module aliases and qualified values/types/constructors', namespace='unlexable module-qualified internal names', dependencyOrder='deterministic DFS postorder, cycles rejected, shared modules linked once', nativeLinker='owned Gleam relocation emitter, no external linker', selectiveImports=False),
    projectUpstreamChecks=dict(total=len(module_results), agreed=len(module_results), path='evidence/structural-equality-project-upstream-checks.json'),
    totalFreshUpstreamComparisons=len(oracle_results)+len(module_results),
    linkedExampleSymbols=module_trace,
    exactSingleModuleEquivalenceFixture='nested-path-default-alias (native test)',
    moduleFixturesSHA256=sha((ROOT / 'test/modules-fixtures.json').read_bytes()),
    aliasesGuardsFixturesSHA256=sha((ROOT / 'test/aliases-guards-fixtures.json').read_bytes()),
    stringsPreludeFixturesSHA256=sha((ROOT / 'test/strings-prelude-fixtures.json').read_bytes()),
    stringRepresentation='static length/UTF8/newline; owned arena buffers have size/tag -2 preceding value pointer; prefix tails copy payload',
    implicitPrelude='reserved Result(a,e)/Ok/Error, shared across modules; local declarations shadow each name; not re-exported',
    nativeOwnedComponentTest='src/native/utf8.gleam compiled by this compiler and executed on valid/invalid byte sequences',
    multiPatternsFixturesSHA256=sha((ROOT / 'test/multi-pattern-fixtures.json').read_bytes()),
    multiPatterns='subjects evaluated once left-to-right into stack slots; alternatives share bindings/body; failed guard retries next alternative; finite constructor-product coverage',
    ownedCore=owned_core,
    equalityFixturesSHA256=sha((ROOT / 'test/equality-fixtures.json').read_bytes()),
    structuralEquality='type-directed static helper graph; lists loop over tails; nominal tags checked before variant fields; strings/bits compare bytes; no heap allocation during comparison',
    equalityLimits='128 shape nodes per root; erased stored fields and function values explicitly unsupported; unresolved inference-only fields trap if visited',
    ownedTypeSystem=owned_types,
    ownedEqualityPlanner=owned_equality,
    aliases='transparent, scoped expansion; cycle/arity/parameter/visibility checks; no target wrappers',
    guards='restricted pure expressions, typed Bool; failed alternative guard retries alternatives then later arms; guarded arms do not prove exhaustiveness',
    functionValueRepresentation='arena descriptor: size, tag0, code pointer, copied captures',
    compilerRunsNatively=False,
    selfHosting=False,
    fullGleamCompatibility=False,
    nativeTarget='linux-x86_64',
    externalCodegenTools=[],
    limitations=['Subset compiler; bootstrap still uses upstream Gleam and Node',
                 'No polymorphic named function values/labelled function calls/selective imports or package resolution yet; guard construction remains unsupported',
                 'Anonymous parameters require annotations or a sufficiently resolved expected function type',
                 'Bounded arena only: no collection or native compiler file IO yet',
                 'Erased stored-field/function equality, compound printing and full coverage are not implemented; equality graphs are bounded to 128 shape nodes',
                 'Unaligned/dynamic-size/float and UTF8 codepoint pattern segments are not implemented; unsigned 64-bit extraction above native signed Int range exits 70',
                 'Fixed-width integer and diagnostic formatting limitations documented in README'],
)
(evidence / 'structural-equality-verification.json').write_text(json.dumps(receipt, indent=2) + '\n')
(evidence / 'structural-equality-test-output.tap').write_text(suite.stdout)
print(json.dumps({k: v for k, v in receipt.items() if k != 'sourceSHA256'}, indent=2))
