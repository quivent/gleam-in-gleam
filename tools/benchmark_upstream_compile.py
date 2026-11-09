#!/usr/bin/env python3
"""Fresh full-source compilation: original Gleam JS target vs self-hosted GTA ELF."""
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

ROOT=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('native_compiler');p.add_argument('receipt')
p.add_argument('--gleam',default=str(Path.home()/'.local/share/gleam-native/bootstrap/1.19.2/gleam'))
p.add_argument('--repetitions',type=int,default=5)
p.add_argument('--qualification',default='evidence/comparison-flags-qualification.json')
p.add_argument('--native-baseline',help='Optional previous native compiler; builds the identical frozen source')
a=p.parse_args();assert a.repetitions>=5
native=Path(a.native_compiler).resolve();gleam=Path(a.gleam).resolve()
sha=lambda b:hashlib.sha256(b).hexdigest()
q=json.loads((ROOT/a.qualification).read_text())
source={path:(ROOT/path).read_bytes() for path in q['sourceSHA256']}
for path,data in source.items():assert sha(data)==q['sourceSHA256'][path]
seed_sha=sha(native.read_bytes());assert seed_sha==q['nativeCLI']['artifact']['sha256']
baseline=Path(a.native_baseline).resolve() if a.native_baseline else None
variants=['original-gleam','gta']+(['previous-native'] if baseline else [])
cpu=max(os.sched_getaffinity(0));gcc=shutil.which('gcc');node=shutil.which('node');assert gcc and node
report=dict(schema='gta.original-gleam-compilation/1',observedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),complete=False,
 harnessSHA256=sha(Path(__file__).read_bytes()),sourceSHA256=q['sourceSHA256'],sourceModules=len(source),sourceBytes=sum(map(len,source.values())),
 qualification=a.qualification,nativeCompiler=dict(bytes=native.stat().st_size,sha256=seed_sha),upstreamCompiler=dict(version=subprocess.check_output([str(gleam),'--version'],text=True).strip(),sha256=sha(gleam.read_bytes())),
 environment=dict(kernel=os.uname().release,pinnedCPU=cpu,loadBefore=list(os.getloadavg())),
 methodology=dict(repetitions=a.repetitions,warmupsPerVariant=1,order='Rotating variants; reversed on odd repetitions',compile='Fresh project/output/build directory each run; same frozen 28 source modules; OS caches uncontrolled',measurement='Small C parent: monotonic wall and wait4 CPU/RSS; one pinned CPU',targets='Original upstream Gleam emits JavaScript modules; GTA emits standalone native compiler ELF; target work differs'),
 limitations=['Upstream has no native ELF backend, so this is same-source end-to-end compilation, not identical backend work',
              'Compilation excludes executing the generated programs and excludes compiling either compiler tool itself',
              'The JavaScript output is qualified by a separately executed native-code-generation probe; that execution is not in compilation timings',
              'Single shared host; fresh builds with warm OS caches, not cold-cache tests'],samples=[],summaries=[],artifacts={},qualifications=[])
if baseline:report['nativeBaseline']=dict(bytes=baseline.stat().st_size,sha256=sha(baseline.read_bytes()))
try:
 with tempfile.TemporaryDirectory(prefix='gta-upstream-') as temporary:
  work=Path(temporary);meter=work/'measure'
  subprocess.run([gcc,'-O2','-Wall','-Wextra','-Werror','-std=c11',str(ROOT/'tools/measure_process.c'),'-o',str(meter)],check=True)
  for repetition in range(-1,a.repetitions):
   start=repetition%len(variants);order=variants[start:]+variants[:start]
   if repetition%2:order=list(reversed(order))
   for variant in order:
    directory=work/f'{variant}-{repetition}';directory.mkdir()
    for path,data in source.items():target=directory/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
    (directory/'gleam.toml').write_text('name="gleam_native"\nversion="0.1.0"\ntarget="javascript"\n')
    output=directory/'compiler';stats=directory/'measurement.json';out=directory/'stdout';err=directory/'stderr'
    command=[str(gleam),'build','--target','javascript'] if variant=='original-gleam' else [str(native if variant=='gta' else baseline),'--build-compiler',str(output),'--source-root',str(directory/'src')]
    previous=Path.cwd()
    try:
     os.chdir(directory);subprocess.run([str(meter),str(cpu),str(stats),str(out),str(err),*command],check=True)
    finally:os.chdir(previous)
    result=json.loads(stats.read_text());assert result['exitCode']==0 and not result['timedOut'],err.read_text()
    if variant!='original-gleam':
     assert sha(output.read_bytes())==seed_sha
     artifact=dict(kind='standalone ELF',bytes=output.stat().st_size,sha256=sha(output.read_bytes()))
    else:
     build=directory/'build/dev/javascript';paths=sorted(build.rglob('*.mjs'));assert len(list((build/'gleam_native/native').glob('*.mjs')))==len(source)
     artifact=dict(kind='JavaScript modules; Node runtime excluded',bytes=sum(p.stat().st_size for p in paths),files={str(p.relative_to(build)):dict(bytes=p.stat().st_size,sha256=sha(p.read_bytes())) for p in paths})
    if variant not in report['artifacts']:report['artifacts'][variant]=artifact
    else:assert artifact==report['artifacts'][variant],'Non-deterministic output'
    if repetition>=0:report['samples'].append(dict(variant=variant,repetition=repetition,**result))
    if repetition==0:
     if variant!='original-gleam':
      ran=subprocess.run([str(output),'--version'],capture_output=True,text=True,check=True);assert 'gleam-native' in ran.stdout
      report['qualifications'].append(dict(variant=variant,selfBuildByteIdentical=variant=='gta',outputMatchesCandidateSeed=True,versionStdout=ran.stdout))
     else:
      base=directory/'build/dev/javascript/gleam_native';probe=directory/'probe'
      script=f"import {{compile}} from {json.dumps((base/'native/compiler.mjs').as_uri())};import {{BitArray}} from {json.dumps((base/'gleam.mjs').as_uri())};import {{writeFileSync}} from 'node:fs';const r=compile(new BitArray(Buffer.from('pub fn main()->Nil {{echo 45 Nil}}')));if(!r.isOk())throw Error(r[0]);writeFileSync({json.dumps(str(probe))},r[0].rawBuffer,{{mode:0o755,flag:'wx'}});"
      subprocess.run([node,'--input-type=module','-e',script],check=True,capture_output=True)
      ran=subprocess.run([str(probe)],check=True,capture_output=True,text=True);assert ran.stdout=='45\n' and not ran.stderr
      report['qualifications'].append(dict(variant=variant,compiledModules=len(source),generatedCompilerProbeStdout=ran.stdout,probeSHA256=sha(probe.read_bytes()),probeOutsideTimedBuild=True))
    print(json.dumps(dict(variant=variant,repetition=repetition,wallSeconds=result['wallSeconds'],cpuSeconds=result['userSeconds']+result['systemSeconds'],peakRSSKiB=result['peakRSSKiB'])),flush=True)
 for variant in variants:
  rows=[r for r in report['samples'] if r['variant']==variant]
  report['summaries'].append(dict(variant=variant,medianCPUSeconds=statistics.median(r['userSeconds']+r['systemSeconds'] for r in rows),medianWallSeconds=statistics.median(r['wallSeconds'] for r in rows),minWallSeconds=min(r['wallSeconds'] for r in rows),maxWallSeconds=max(r['wallSeconds'] for r in rows),maxPeakRSSKiB=max(r['peakRSSKiB'] for r in rows)))
 report['complete']=True;report['environment']['loadAfter']=list(os.getloadavg())
except BaseException as error:
 report['failure']=repr(error);raise
finally:(ROOT/a.receipt).write_text(json.dumps(report,indent=2)+'\n')
