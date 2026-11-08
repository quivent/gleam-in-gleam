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
PREFIX = os.environ.get('GIG_VERIFY_PREFIX', 'current')
assert re.fullmatch(r'[a-z][a-z0-9-]*', PREFIX), 'Invalid evidence prefix'
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
suite = run(['node', '--test', 'test/native.test.mjs', 'test/modules.test.mjs', 'test/strings.test.mjs', 'test/native-cli.test.mjs', 'test/tail-calls.test.mjs', 'test/registers.test.mjs'],
            env={**os.environ, 'NATIVE_CLI_RECEIPT': str(ROOT / f'evidence/{PREFIX}-io-verification.json'),
                 'NATIVE_CLI_ASM': str(ROOT / f'evidence/{PREFIX}-disassembly.txt')})
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
        ('pattern_aliases', '14\n10\n'),
        ('wide_patterns', 'True\nFalse\n9007199254740991\n-2147483648\n'),
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
        if name in ('collections', 'custom_types', 'generics_records', 'functions', 'closures', 'record_updates', 'bit_arrays', 'modules', 'aliases_guards', 'strings_prelude', 'multi_patterns', 'structural_equality', 'pattern_aliases', 'wide_patterns') and shutil.which('objdump'):
            entry = struct.unpack_from('<Q', data, 24)[0]
            load_base = struct.unpack_from('<Q', data, phoff + 16)[0]
            raw = Path(tmp) / f'{name}-code.bin'
            raw.write_bytes(data[entry - load_base:])
            listing = run(['objdump', '-D', '-b', 'binary', '-m', 'i386:x86-64',
                           f'--adjust-vma={entry}', str(raw)]).stdout
            # Preserve a stable path in the listing, not a disposable temp name.
            listing = listing.replace(str(raw), f'{name}-code.bin')
            listing = '\n'.join(line.rstrip() for line in listing.splitlines()) + '\n'
            listing_name = f'{PREFIX}-' + ('functions-descriptor' if name == 'functions' else name)
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

oracle_cases = [(f['name'], f['source'], f['accepted'], f['stdout'])
                for f in json.loads((ROOT / 'test/grammar-fixtures.json').read_text())]
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
                   + json.loads((ROOT / 'test/equality-fixtures.json').read_text())
                   + json.loads((ROOT / 'test/pattern-alias-fixtures.json').read_text())
                   + json.loads((ROOT / 'test/integer-coverage-fixtures.json').read_text())
                   + json.loads((ROOT / 'test/tail-calls-fixtures.json').read_text())
                   + json.loads((ROOT / 'test/register-fixtures.json').read_text())
                   + json.loads((ROOT / 'test/branch-slots-fixtures.json').read_text())
                   + json.loads((ROOT / 'test/allocated-expression-fixtures.json').read_text()))
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
(evidence / f'{PREFIX}-project-upstream-checks.json').write_text(json.dumps(module_results, indent=2) + '\n')

(evidence / f'{PREFIX}-upstream-checks.json').write_text(json.dumps(oracle_results, indent=2) + '\n')

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
(evidence / f'owned-core-{PREFIX}-native-verification.json').write_text(json.dumps(owned_core, indent=2) + '\n')

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
(evidence / f'owned-type-system-{PREFIX}-native-verification.json').write_text(json.dumps(owned_types, indent=2) + '\n')
(evidence / f'owned-equality-{PREFIX}-native-verification.json').write_text(json.dumps(owned_equality, indent=2) + '\n')

# Run the entire owned compiler API natively; execute and compare its emitted ELF.
run(['node', 'test/probe-compiler-api.mjs', f'evidence/complete-api-{PREFIX}-probe.json'])
native_compiler_api = json.loads((evidence / f'complete-api-{PREFIX}-probe.json').read_text())
assert native_compiler_api.get('nativeCompilationVerified') is True, native_compiler_api
assert len(native_compiler_api['nativePrograms']) == 2
for path, expected_hash in native_compiler_api['sourceSHA256'].items():
    assert sha((ROOT / path).read_bytes()) == expected_hash, path

native_cli = json.loads((evidence / f'{PREFIX}-io-verification.json').read_text())
assert not native_cli['artifact']['dynamicLoader'] and not native_cli['artifact']['dynamicSegment']
assert native_cli['artifact']['nonExecutableStack']
for path, expected_hash in native_cli['sourceSHA256'].items():
    assert sha((ROOT / path).read_bytes()) == expected_hash, path
assert any(v['kind'] == 'actual-short-io' and v['positiveShortReads'] > 0 and v['positiveShortWrites'] > 0 for v in native_cli['observations'])

run(['node', 'tools/verify_self_hosting.mjs', f'evidence/{PREFIX}-native-rebuilds.json'])
self_host = json.loads((evidence / f'{PREFIX}-native-rebuilds.json').read_text())
assert self_host['selfHosting'] and self_host['sourceSHA256'] == sources
assert self_host['stages'][0]['sha256'] == native_cli['artifact']['sha256']
assert self_host['nativeCorpusSummary']['total'] == len(oracle_results) + len(module_results)

receipt = dict(
    schema='gleam-in-gleam.self-hosting-qualification/1',
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
                                  path=f'evidence/{PREFIX}-upstream-checks.json'),
    bitArrayRepresentation='arena descriptor: aligned size, tag -1, byte length, data pointer, root owner; owned payload or shared slice',
    bitArraySubset='byte-aligned construction/concat, fixed integer widths 0..64 construction and 8..64 matching; signed/unsigned matching, endian options, final unsized bits/bytes tails',
    projectCompilation=dict(sourceLanguage='Gleam', imports='local module aliases and qualified values/types/constructors', namespace='unlexable module-qualified internal names', dependencyOrder='deterministic DFS postorder, cycles rejected, shared modules linked once', nativeLinker='owned Gleam relocation emitter, no external linker', selectiveImports=False),
    projectUpstreamChecks=dict(total=len(module_results), agreed=len(module_results), path=f'evidence/{PREFIX}-project-upstream-checks.json'),
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
    integerCoverageFixturesSHA256=sha((ROOT / 'test/integer-coverage-fixtures.json').read_bytes()),
    integerLiteralRange='decimal magnitudes 0..9007199254740991; pre-accumulation bound and exact digit grouping preserve bootstrap precision',
    integerPatternLowering='signed imm32 compare where exact; otherwise movabs rdx, imm64 then cmp rax, rdx',
    singleCaseCoverage='legacy fast path/diagnostics, existing constructor-product matrix fallback with one subject column; guarded arms excluded',
    patternAliasFixturesSHA256=sha((ROOT / 'test/pattern-alias-fixtures.json').read_bytes()),
    patternAliases='whole-value aliases reuse matched stack slots; aliases preserve underlying coverage and typed bindings; nested aliases, guards, alternatives and captures',
    equalityFixturesSHA256=sha((ROOT / 'test/equality-fixtures.json').read_bytes()),
    structuralEquality='type-directed static helper graph; lists loop over tails; nominal tags checked before variant fields; strings/bits compare bytes; no heap allocation during comparison',
    equalityLimits='128 shape nodes per root; erased stored fields and function values explicitly unsupported; unresolved inference-only fields trap if visited',
    ownedTypeSystem=owned_types,
    ownedEqualityPlanner=owned_equality,
    aliases='transparent, scoped expansion; cycle/arity/parameter/visibility checks; no target wrappers',
    guards='restricted pure expressions, typed Bool; failed alternative guard retries alternatives then later arms; guarded arms do not prove exhaustiveness',
    functionValueRepresentation='arena descriptor: size, tag0, code pointer, copied captures',
    compilerRunsNatively=True,
    nativeCompilerAPI=dict(path=f'evidence/complete-api-{PREFIX}-probe.json',
                           bytes=native_compiler_api['artifact']['bytes'],
                           emittedPrograms=len(native_compiler_api['nativePrograms']),
                           byteIdenticalToBootstrap=True,
                           nativeCLI=False),
    nativeCLI=dict(path=f"evidence/{PREFIX}-io-verification.json",
                   artifact=native_cli["artifact"],sourceLimitBytes=native_cli["limits"]["sourceBytes"],
                   compilerArenaBytes=native_cli["limits"]["arenaBytes"],
                   sourceConvention="module path relative to explicit root or cwd",
                   syscallBoundary="typed pure Gleam request state machine + owned Linux effect runner",
                   disassembly=native_cli["disassembly"]),
    selfHosting=True,
    selfHostingProof=f"evidence/{PREFIX}-native-rebuilds.json",
    nativeCorpus=self_host["nativeCorpusSummary"],
    tailCalls="direct returned self calls in blocks and cases; arguments evaluated before parameter replacement",
    fullGleamCompatibility=False,
    nativeTarget='linux-x86_64',
    externalCodegenTools=[],
    limitations=['Self-hosted subset compiler; initial bootstrap uses upstream Gleam and Node',
                 'No polymorphic named function values/labelled function calls/selective imports or package resolution yet; guard construction remains unsupported',
                 'Anonymous parameters require annotations or a sufficiently resolved expected function type',
                 'Bounded native CLI: 128 KiB per source, 512 MiB compiler arena; ordinary emitted programs retain 64 MiB; no GC or mutual/indirect TCO',
                 'Erased stored-field/function equality, compound printing and full coverage are not implemented; equality graphs are bounded to 128 shape nodes',
                 'Unaligned/dynamic-size/float and UTF8 codepoint pattern segments are not implemented; unsigned 64-bit extraction above native signed Int range exits 70',
                 'Fixed-width integer and diagnostic formatting limitations documented in README'],
)
(evidence / f'{PREFIX}-qualification.json').write_text(json.dumps(receipt, indent=2) + '\n')
(evidence / f'{PREFIX}-test-output.tap').write_text(suite.stdout)
print(json.dumps({k: v for k, v in receipt.items() if k != 'sourceSHA256'}, indent=2))
