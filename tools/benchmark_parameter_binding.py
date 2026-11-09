#!/usr/bin/env python3
"""Dev-only paired whole-compiler measurement on identical qualified frozen input."""
import argparse,datetime,hashlib,json,os,shutil,statistics,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser(description=__doc__);p.add_argument('baseline');p.add_argument('candidate');p.add_argument('receipt');p.add_argument('--qualification',default='evidence/static-parameters-qualification.json');p.add_argument('--repetitions',type=int,default=9);a=p.parse_args();assert a.repetitions>=5
sha=lambda b:hashlib.sha256(b).hexdigest()
q=json.loads((ROOT/a.qualification).read_text());baseq=json.loads((ROOT/'evidence/fusion-qualification.json').read_text())
binaries={'baseline':Path(a.baseline).resolve(),'candidate':Path(a.candidate).resolve()}
assert sha(binaries['baseline'].read_bytes())==baseq['nativeCLI']['artifact']['sha256']
assert sha(binaries['candidate'].read_bytes())==q['nativeCLI']['artifact']['sha256']
for f,h in q['sourceSHA256'].items():assert sha((ROOT/f).read_bytes())==h
revision='c2f565438c5c1ff308eb1160bd66131c3fe8eba1'
sources={f:subprocess.check_output(['git','show',revision+':'+f],cwd=ROOT) for f in baseq['sourceSHA256']}
assert {f:sha(b) for f,b in sources.items()}==baseq['sourceSHA256']
expected=baseq['nativeCLI']['artifact']['sha256'];cpu=max(os.sched_getaffinity(0))
r=dict(schema='gta.parameter-binding-benchmark/1',observedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),harnessSHA256=sha(Path(__file__).read_bytes()),complete=False,qualification=a.qualification,binaries={n:dict(bytes=b.stat().st_size,sha256=sha(b.read_bytes())) for n,b in binaries.items()},compilationInput=dict(sourceRevision=revision,sourceSHA256=baseq['sourceSHA256'],sourceBytes=sum(map(len,sources.values())),sourceModules=len(sources)),expectedOutputSHA256=expected,methodology=dict(repetitions=a.repetitions,warmupsPerVariant=1,order='alternating; reversed on odd repetitions',measurement='Small C parent: monotonic wall, wait4 CPU and RSS; one pinned CPU; fresh output per sample',cache='OS caches uncontrolled; no cold-cache claim',scope='whole native compiler process including source IO and output, no external process run by the compiler'),environment=dict(kernel=os.uname().release,pinnedCPU=cpu,loadBefore=list(os.getloadavg())),samples=[],summaries=[],limitations=['Shared virtual host; no general language-wide ranking','Hardware instruction/cycle counts are separate from CPU time and elapsed time'])
try:
 probe=['sudo','-n','perf','stat','-x,','-e','cycles:u,instructions:u','--',str(binaries['baseline']),'--version']
 try:
  perf=subprocess.run(probe,capture_output=True,text=True,timeout=10)
  r['hardwareCounterProbe']=dict(command=probe,exitCode=perf.returncode,stdout=perf.stdout,stderr=perf.stderr,available=perf.returncode==0 and '<not supported>' not in perf.stderr and '<not counted>' not in perf.stderr)
 except (OSError,subprocess.TimeoutExpired) as e:r['hardwareCounterProbe']=dict(available=False,error=repr(e))
 with tempfile.TemporaryDirectory(prefix='gta-binding-bench-') as temp:
  work=Path(temp);src=work/'src';src.mkdir();meter=work/'meter'
  subprocess.run([shutil.which('gcc'),'-O2','-Wall','-Wextra','-Werror','-std=c11',str(ROOT/'tools/measure_process.c'),'-o',str(meter)],check=True)
  for f,b in sources.items():target=src/f.removeprefix('src/');target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(b)
  for repeat in range(-1,a.repetitions):
   order=list(binaries) if repeat%2==0 else list(reversed(binaries))
   for variant in order:
    folder=work/(variant+'-'+str(repeat));folder.mkdir();out=folder/'compiler';stats=folder/'stats.json'
    subprocess.run([str(meter),str(cpu),str(stats),str(folder/'stdout'),str(folder/'stderr'),str(binaries[variant]),'--build-compiler',str(out),'--source-root',str(src)],check=True)
    sample=json.loads(stats.read_text());assert sample['exitCode']==0 and not sample['timedOut'];assert not (folder/'stdout').read_bytes() and not (folder/'stderr').read_bytes();assert sha(out.read_bytes())==expected
    if repeat>=0:r['samples'].append(dict(variant=variant,repetition=repeat,outputSHA256=expected,**sample))
    print(json.dumps(dict(variant=variant,repetition=repeat,cpuSeconds=sample['userSeconds']+sample['systemSeconds'],wallSeconds=sample['wallSeconds'],peakRSSKiB=sample['peakRSSKiB'])),flush=True)
 for variant in binaries:
  rows=[s for s in r['samples'] if s['variant']==variant]
  r['summaries'].append(dict(variant=variant,medianCPUSeconds=statistics.median(s['userSeconds']+s['systemSeconds'] for s in rows),medianWallSeconds=statistics.median(s['wallSeconds'] for s in rows),minWallSeconds=min(s['wallSeconds'] for s in rows),maxWallSeconds=max(s['wallSeconds'] for s in rows),maxPeakRSSKiB=max(s['peakRSSKiB'] for s in rows)))
 r['environment']['loadAfter']=list(os.getloadavg());r['complete']=True
except BaseException as error:r['failure']=repr(error);raise
finally:(ROOT/a.receipt).write_text(json.dumps(r,indent=2)+'\n')
