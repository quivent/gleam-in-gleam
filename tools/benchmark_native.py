#!/usr/bin/env python3
"""Dev-only repeated native measurements; no global cache/governor changes."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import resource
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('baseline')
parser.add_argument('candidate')
parser.add_argument('receipt')
parser.add_argument('--source-revision', default='40e68af')
parser.add_argument('--compile-only', action='store_true')
parser.add_argument('--expect-candidate-image', action='store_true')
parser.add_argument('--repetitions', type=int, default=5)
parser.add_argument('--iterations', type=int, default=4_000_000)
args = parser.parse_args()
assert args.repetitions >= 5 and args.iterations >= 1000
assert platform.system() == 'Linux'
sha = lambda data: hashlib.sha256(data).hexdigest()
binaries = dict(baseline=Path(args.baseline).resolve(), candidate=Path(args.candidate).resolve())
cpu = max(os.sched_getaffinity(0))
cpu_model = next((line.split(':', 1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name')), 'unknown')
receipt = dict(schema='gleam-in-gleam.native-benchmark/1',
    observedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    harnessSHA256=sha(Path(__file__).read_bytes()),
    environment=dict(kernel=platform.release(), machine=platform.machine(),
        cpuModel=cpu_model, pinnedChildCPU=cpu, affinity=sorted(os.sched_getaffinity(0)),
        loadBefore=list(os.getloadavg())),
    binaries={name: dict(bytes=len(path.read_bytes()), sha256=sha(path.read_bytes())) for name, path in binaries.items()},
    methodology=dict(repetitions=args.repetitions, warmupsPerVariant=1,
        order='alternating baseline/candidate; reverse on odd repetitions',
        cache='OS cache uncontrolled; source frozen once; no cold-cache claim',
        wall='perf_counter around fork/exec/wait4, includes process launch',
        cpu='wait4 user and system CPU for exact owned child',
        peakRSS='Linux wait4 ru_maxrss in KiB',
        rssCaveat='Includes owned fork/pre-exec setup; small-program RSS is an upper bound, compiler RSS dominates setup',
        scope='shared host, one pinned child CPU; no global settings or unrelated processes changed'),
    complete=False, samples=[], summaries=[], qualifications=[], limitations=[
        'Single host and workload set, not a language-wide speed ranking',
        'Timing and RSS are distinct from binary size',
        'Compiler target inputs are identical; different backends may emit different images',
        'Five repeats expose variability but cannot eliminate shared-host interference'])

def git(*cmd):
    return subprocess.check_output(['git', *cmd], cwd=ROOT)

def native(binary, arguments, directory, tag):
    out, err = directory / (tag + '.stdout'), directory / (tag + '.stderr')
    started = time.perf_counter()
    pid = os.fork()
    if pid == 0:
        try:
            os.sched_setaffinity(0, {cpu})
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
            resource.setrlimit(resource.RLIMIT_CPU, (120, 120))
            for fd, target in [(1, out), (2, err)]:
                opened = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                os.dup2(opened, fd)
                os.close(opened)
            os.execve(str(binary), [str(binary), *map(str, arguments)], {'PATH': ''})
        except BaseException:
            os._exit(125)
    _, status, usage = os.wait4(pid, 0)
    result = dict(wallSeconds=time.perf_counter() - started,
        userSeconds=usage.ru_utime, systemSeconds=usage.ru_stime,
        peakRSSKiB=usage.ru_maxrss, exitCode=os.waitstatus_to_exitcode(status),
        stdout=out.read_text() if out.exists() else '', stderr=err.read_text() if err.exists() else '')
    assert result['exitCode'] == 0, result
    assert not result['stderr'], result
    return result

def measure(kind, paths, commands, expected, directory):
    # Warm-ups are qualified but not included in the measured distributions.
    for name in binaries:
        r = native(paths[name], commands[name](-1), directory, kind + '-' + name + '-warmup')
        assert r['stdout'] == expected
    for repetition in range(args.repetitions):
        order = list(binaries) if repetition % 2 == 0 else list(reversed(binaries))
        for name in order:
            r = native(paths[name], commands[name](repetition), directory, f'{kind}-{name}-{repetition}')
            assert r['stdout'] == expected
            receipt['samples'].append(dict(workload=kind, variant=name, repetition=repetition, **r))
            print(json.dumps(dict(workload=kind, variant=name, repetition=repetition, wallSeconds=r['wallSeconds'], peakRSSKiB=r['peakRSSKiB'])), flush=True)

try:
    with tempfile.TemporaryDirectory(prefix='gleam-native-bench-') as temporary:
        directory = Path(temporary)
        source_root = directory / 'compiler-source'
        source_root.mkdir()
        revision = git('rev-parse', args.source_revision + '^{commit}').decode().strip()
        paths = git('ls-tree', '-r', '--name-only', revision, 'src/native').decode().splitlines()
        frozen = {}
        for path in paths:
            if not path.endswith('.gleam'):
                continue
            data = git('show', revision + ':' + path)
            target = source_root / path.removeprefix('src/')
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            frozen[path] = sha(data)
        receipt['compilationInput'] = dict(sourceRevision=revision, sourceSHA256=frozen)
        def compile_args(name, repetition):
            return ['--build-compiler', directory / f'{name}-compiler-{repetition}', '--source-root', source_root]
        commands = {name: (lambda repetition, name=name: compile_args(name, repetition)) for name in binaries}
        measure('compile-frozen-compiler', binaries, commands, '', directory)
        compiled_hashes = {}
        probe_root = directory / 'probe'
        probe_root.mkdir()
        (probe_root / 'main.gleam').write_text('fn inc(n:Int)->Int {n+1} pub fn main()->Nil {echo 40+inc(4) Nil}')
        for name in binaries:
            images = [directory / f'{name}-compiler-{i}' for i in range(-1, args.repetitions)]
            hashes = [sha(p.read_bytes()) for p in images]
            assert len(set(hashes)) == 1, 'Nondeterministic compiler output'
            version = native(images[-1], ['--version'], directory, name + '-produced-version')
            output = directory / (name + '-probe')
            native(images[-1], ['main.gleam', output, '--source-root', probe_root], directory, name + '-produced-probe-compile')
            result = native(output, [], directory, name + '-produced-probe-run')
            assert result['stdout'] == '45\n'
            compiled_hashes[name] = hashes[0]
            receipt['qualifications'].append(dict(variant=name, producedCompilerSHA256=hashes[0], deterministic=True, versionStdout=version['stdout'], probeStdout=result['stdout'], probeSHA256=sha(output.read_bytes())))
        if args.expect_candidate_image:
            assert compiled_hashes['candidate'] == receipt['binaries']['candidate']['sha256'], 'Current-source self-build differs'
            receipt['candidateSelfBuildByteIdentical'] = True
        n, split = args.iterations, args.iterations // 2
        common = f'pub fn main()->Nil {{echo go({n},0) Nil}}'
        workloads = {
            'arithmetic': ('fn go(n:Int,a:Int)->Int {case n {0->a _->go(n-1,a+n)}} ' + common, n * (n + 1) // 2),
            'branch-join': (f'fn go(n:Int,a:Int)->Int {{case n {{0->a _->{{let next=case n<{split} {{True->a+n False->a-n}} go(n-1,next)}}}}}} ' + common, (split - 1) * split - n * (n + 1) // 2),
            'short-circuit-call': (f'fn positive(n:Int)->Bool {{n>0}} fn go(n:Int,a:Int)->Int {{case n {{0->a _->{{let next=case n<{split} && positive(n-1) {{True->a+n False->a-n}} go(n-1,next)}}}}}} ' + common, (split - 1) * split - n * (n + 1) // 2 - 2),
            'live-across-call': ('fn mix(n:Int)->Int {n*3+1} fn go(n:Int,a:Int)->Int {case n {0->a _->go(n-1,a+mix(n-1))}} ' + common, 3 * n * (n + 1) // 2 - 2 * n),
        }
        receipt['runtimeInputs'] = {}
        for kind, (source, expected) in ({} if args.compile_only else workloads).items():
            root = directory / kind
            root.mkdir()
            (root / 'main.gleam').write_text(source)
            programs = {}
            for name, binary in binaries.items():
                output = root / name
                native(binary, ['main.gleam', output, '--source-root', root], directory, kind + '-' + name + '-compile')
                programs[name] = output
            receipt['runtimeInputs'][kind] = dict(source=source, sourceSHA256=sha(source.encode()), iterations=n, expectedStdout=str(expected) + '\n', images={name: dict(bytes=len(p.read_bytes()), sha256=sha(p.read_bytes())) for name, p in programs.items()})
            measure(kind, programs, {name: lambda repetition: [] for name in binaries}, str(expected) + '\n', directory)
    for kind in dict.fromkeys(row['workload'] for row in receipt['samples']):
        variants = {}
        for name in binaries:
            rows = [s for s in receipt['samples'] if s['workload'] == kind and s['variant'] == name]
            wall = [r['wallSeconds'] for r in rows]
            variants[name] = dict(medianWallSeconds=statistics.median(wall), minWallSeconds=min(wall), maxWallSeconds=max(wall), medianCPUSeconds=statistics.median(r['userSeconds'] + r['systemSeconds'] for r in rows), maxPeakRSSKiB=max(r['peakRSSKiB'] for r in rows))
        ratio = variants['candidate']['medianWallSeconds'] / variants['baseline']['medianWallSeconds']
        receipt['summaries'].append(dict(workload=kind, variants=variants, candidateOverBaselineMedian=ratio))
    receipt['environment']['loadAfter'] = list(os.getloadavg())
    receipt['complete'] = True
except BaseException as error:
    receipt['failure'] = repr(error)
    raise
finally:
    Path(args.receipt).write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt['summaries'], indent=2), flush=True)
