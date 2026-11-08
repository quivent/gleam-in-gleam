#!/usr/bin/env python3
"""Compare compilation hosting modes for the same qualified Gleam implementation."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('native_compiler')
p.add_argument('receipt')
p.add_argument('--inputs', default='evidence/comparison-flags-surface-baselines.json')
p.add_argument('--repetitions', type=int, default=5)
a = p.parse_args()
assert a.repetitions >= 5
native = Path(a.native_compiler).resolve()
inputs = json.loads(Path(a.inputs).read_text())
sha = lambda b: hashlib.sha256(b).hexdigest()
assert sha(native.read_bytes()) == inputs['nativeCompiler']['sha256']
q = json.loads((ROOT/'evidence/comparison-flags-qualification.json').read_text())
for path, digest in q['sourceSHA256'].items():
    assert sha((ROOT/path).read_bytes()) == digest, path
cpu = max(os.sched_getaffinity(0))
report = dict(schema='gta.bootstrap-comparison/1',
    observedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),complete=False,
    harnessSHA256=sha(Path(__file__).read_bytes()),
    bridgeSHA256=sha((ROOT/'bootstrap.mjs').read_bytes()),
    inputReceipt=a.inputs,inputReceiptSHA256=sha(Path(a.inputs).read_bytes()),
    nativeCompiler=inputs['nativeCompiler'],compilerSourceSHA256=q['sourceSHA256'],
    pinnedCPU=cpu,loadBefore=list(os.getloadavg()),repetitions=a.repetitions,
    methodology='Same qualified compiler logic, Node-hosted bridge versus native self-hosted CLI; fresh process/output each time; one warm-up then alternating repeats; compilation only',
    limitations=['Node lane is current compiler logic under the earlier hosting architecture, not a recreated historical code version',
                'Host IO/source preparation differs; outputs must be byte-identical',
                'OS caches uncontrolled; one shared host; no cold-cache or language-ranking claim'],
    samples=[],summaries=[],qualified=[])
node, gcc = shutil.which('node'), shutil.which('gcc')
assert node and gcc
try:
    with tempfile.TemporaryDirectory(prefix='gta-bootstrap-') as temp:
        work = Path(temp);meter = work/'measure'
        subprocess.run([gcc,'-O2','-Wall','-Wextra','-Werror','-std=c11',str(ROOT/'tools/measure_process.c'),'-o',str(meter)],check=True)
        serial = 0
        for name, case in inputs['sources'].items():
            directory = work/name;directory.mkdir();source=directory/'main.gleam';source.write_text(case['gleam'])
            for repetition in range(-1,a.repetitions):
                order=['bootstrap-node','native'] if repetition%2==0 else ['native','bootstrap-node']
                for variant in order:
                    serial += 1
                    output=directory/f'{variant}-{repetition}'
                    prefix=directory/str(serial)
                    stats,out,err=(Path(str(prefix)+ext) for ext in ['.json','.out','.err'])
                    command=[node,str(ROOT/'bootstrap.mjs'),str(source),str(output),'--source-root',str(directory)] if variant=='bootstrap-node' else [str(native),'main.gleam',str(output),'--source-root',str(directory)]
                    subprocess.run([str(meter),str(cpu),str(stats),str(out),str(err),*command],check=True)
                    r=json.loads(stats.read_text());assert r['exitCode']==0 and not r['timedOut'],err.read_text()
                    assert not out.read_text() and not err.read_text()
                    assert sha(output.read_bytes())==inputs['artifacts'][name]['native']['sha256'],(name,variant)
                    if repetition>=0:report['samples'].append(dict(workload=name,variant=variant,repetition=repetition,**r))
                    if repetition==0:
                        ran=subprocess.run([str(output)],capture_output=True,text=True,timeout=15)
                        assert ran.returncode==0 and ran.stdout==case['expectedStdout'] and not ran.stderr
                        report['qualified'].append(dict(workload=name,variant=variant,artifactSHA256=sha(output.read_bytes()),expectedResultVerified=True))
            print(name+' compilation modes verified',flush=True)
        for name in inputs['sources']:
            for variant in ['bootstrap-node','native']:
                rows=[r for r in report['samples'] if r['workload']==name and r['variant']==variant]
                report['summaries'].append(dict(workload=name,variant=variant,
                    medianCPUSeconds=statistics.median(r['userSeconds']+r['systemSeconds'] for r in rows),
                    medianWallSeconds=statistics.median(r['wallSeconds'] for r in rows),
                    minWallSeconds=min(r['wallSeconds'] for r in rows),maxWallSeconds=max(r['wallSeconds'] for r in rows),
                    maxPeakRSSKiB=max(r['peakRSSKiB'] for r in rows)))
        report['complete']=True;report['loadAfter']=list(os.getloadavg())
finally:
    Path(a.receipt).write_text(json.dumps(report,indent=2)+'\n')
