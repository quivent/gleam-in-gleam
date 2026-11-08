#!/usr/bin/env python3
"""Development-only surface baseline: native Gleam, upstream Gleam/Node, GCC O2/O3.

No compiler implementation changes or third-party Python packages. The small C
measurement parent is development tooling only; generated native output stays
independent of GCC/libc/Node.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('native_compiler')
p.add_argument('receipt')
p.add_argument('--native-baseline', help='Optional earlier native compiler for a paired before/after comparison')
p.add_argument('--gleam', default=str(Path.home()/'.local/share/gleam-native/bootstrap/1.19.2/gleam'))
p.add_argument('--repetitions', type=int, default=5)
p.add_argument('--iterations', type=int, default=20_000_000)
a = p.parse_args()
assert a.repetitions >= 5 and 1000 <= a.iterations <= 20_000_000
native = Path(a.native_compiler).resolve()
gleam = Path(a.gleam).resolve()
node, gcc = shutil.which('node'), shutil.which('gcc')
assert node and gcc
sha = lambda b: hashlib.sha256(b).hexdigest()
variants = ['native', 'gleam-js', 'gcc-o2', 'gcc-o3']
native_before = Path(a.native_baseline).resolve() if a.native_baseline else None
if native_before: variants.insert(0, 'native-before')
cpu = max(os.sched_getaffinity(0))
N, M = a.iterations, 1_000_000_007
# Exact independent expectations, without executing a tested implementation.
recurrence = 0
for n in range(N, 0, -1):
    recurrence = (recurrence * 17 + n) % M
branch = sum((n * 3 + 1) if n % 7 < 3 else -(n * 3 + 1) for n in range(1, N+1))
x, y = 0, 1
for _ in range(35):
    x, y = y, x+y
list_n = 500_000
cases = {
 'startup': ('', '45', 'return 45;', 45, 0),
 'integer-recurrence': (
  'fn go(n:Int,a:Int)->Int {case n {0->a _->go(n-1,{a*17+n}%1000000007)}}',
  f'go({N},0)',
  'int64_t a=0; while(n){a=(a*17+n)%1000000007; --n;} return a;', recurrence, N),
 'branch-call': (
  'fn mix(n:Int)->Int {n*3+1} fn go(n:Int,a:Int)->Int {case n {0->a _->{let v=mix(n) let b=case n%7<3 {True->a+v False->a-v} go(n-1,b)}}}',
  f'go({N},0)',
  'int64_t a=0; while(n){int64_t v=n*3+1; a=n%7<3?a+v:a-v; --n;} return a;', branch, N),
 'recursive-fibonacci': (
  'fn fib(n:Int)->Int {case n<2 {True->n False->fib(n-1)+fib(n-2)}}',
  'fib(35)', 'return fib(n);', x, 35),
 'list-build-map-sum': (
  'fn make(n:Int,xs:List(Int))->List(Int) {case n {0->xs _->make(n-1,[n,..xs])}} '
  'fn map(xs:List(Int),ys:List(Int))->List(Int) {case xs {[]->ys [x,..rest]->map(rest,[x*3+1,..ys])}} '
  'fn sum(xs:List(Int),a:Int)->Int {case xs {[]->a [x,..rest]->sum(rest,a+x)}}',
  f'sum(map(make({list_n},[]),[]),0)',
  'Node *pool=malloc((size_t)n*2*sizeof(Node)); if(!pool)exit(71); Node *xs=0,*ys=0; '
  'int64_t k=0; for(int64_t i=n;i>0;--i){pool[k]=(Node){i,xs};xs=&pool[k++];} '
  'for(Node *p=xs;p;p=p->next){pool[k]=(Node){p->value*3+1,ys};ys=&pool[k++];} '
  'int64_t a=0; for(Node *p=ys;p;p=p->next)a+=p->value; free(pool); return a;',
  3*list_n*(list_n+1)//2+list_n, list_n),
}
receipt = dict(schema='gleam-in-gleam.surface-baselines/1',
 observedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(), complete=False,
 harnessSHA256=sha(Path(__file__).read_bytes()),
 measureSourceSHA256=sha((ROOT/'tools/measure_process.c').read_bytes()),
 nativeCompiler=dict(bytes=native.stat().st_size,sha256=sha(native.read_bytes())),
 tools={name:subprocess.check_output([binary,'--version'],text=True).splitlines()[0]
        for name,binary in [('gleam',str(gleam)),('node',node),('gcc',gcc)]},
 environment=dict(kernel=platform.release(),cpu=next(l.split(':',1)[1].strip() for l in Path('/proc/cpuinfo').read_text().splitlines() if l.startswith('model name')),pinnedCPU=cpu,loadBefore=list(os.getloadavg())),
 methodology=dict(repetitions=a.repetitions,warmupsPerVariant=1,
  compile='Fresh project/build directory per measured compile; OS caches uncontrolled, no cold-cache claim',
  runtime='Fresh process per sample; includes startup, no steady-state-only JIT claim',
  order='Rotate variants by repetition, reverse odd repetitions',
  memory='wait4 peak RSS from a small C parent; includes child setup/loader, is not live heap; zero means below Linux sampling visibility',
  cpu='wait4 user+system time for child, including waited compiler descendants',
  artifacts='Native ELF vs generated JS payload vs dynamically linked C ELF; external runtimes/libraries excluded and explicitly required'),
 limitations=['Surface microbenchmarks on one shared host, not a language ranking',
  'Native checked Int, JS Number and C int64_t differ; chosen values stay in the common exact range',
  'C has volatile runtime input and O2/O3 optimization; identical Gleam source embeds bounded inputs',
  'C list baseline uses one explicit allocation pool; JS uses managed objects; native uses a bounded bump arena',
  'Upstream wrapper calls exported run and prints integer; native main echoes it; upstream echo formatting is not timed',
  'Short startup samples approach process-launch/RSS measurement floors'],sources={},artifacts={},samples=[],summaries=[])
if native_before:
 receipt['nativeBaseline']=dict(bytes=native_before.stat().st_size,sha256=sha(native_before.read_bytes()))
try:
 with tempfile.TemporaryDirectory(prefix='gig-surface-') as temporary:
  work = Path(temporary)
  meter = work/'measure'
  subprocess.run([gcc,'-O2','-Wall','-Wextra','-Werror','-std=c11',str(ROOT/'tools/measure_process.c'),'-o',str(meter)],check=True)
  serial = 0
  def measure(command):
   global serial
   serial += 1
   prefix = work/f'measure-{serial}'
   report, out, err = (Path(str(prefix)+suffix) for suffix in ['.json','.out','.err'])
   subprocess.run([str(meter),str(cpu),str(report),str(out),str(err),*map(str,command)],check=True)
   r = json.loads(report.read_text());r['stdout']=out.read_text();r['stderr']=err.read_text()
   assert r['exitCode']==0 and not r['timedOut'],r
   return r
  for name,(functions,expression,c_body,wanted,count) in cases.items():
   source = functions+'\npub fn run()->Int {'+expression+'}\npub fn main()->Nil {echo run() Nil}\n'
   c_source = '#include <stdint.h>\n#include <stdlib.h>\n#include <stdio.h>\n#include <inttypes.h>\n'
   c_source += 'typedef struct Node {int64_t value; struct Node *next;} Node;\n'
   if name=='recursive-fibonacci':c_source+='static int64_t fib(int64_t n){return n<2?n:fib(n-1)+fib(n-2);}\n'
   c_source += 'static int64_t run(int64_t n){(void)n; '+c_body+'}\n'
   c_source += f'int main(void){{volatile int64_t input={count}; printf("%" PRId64 "\\n",run(input));return 0;}}\n'
   receipt['sources'][name]=dict(gleam=source,gleamSHA256=sha(source.encode()),c=c_source,cSHA256=sha(c_source.encode()),expectedStdout=str(wanted)+'\n',iterations=count)
   programs={}
   for repetition in range(-1,a.repetitions):
    order=variants[repetition%len(variants):]+variants[:repetition%len(variants)]
    if repetition%2:order=list(reversed(order))
    for variant in order:
     directory=work/f'{name}-{variant}-{repetition}';directory.mkdir();output=directory/'app'
     if variant=='gleam-js':
      (directory/'src').mkdir();(directory/'src/main.gleam').write_text(source)
      (directory/'gleam.toml').write_text('name="surface_baseline"\nversion="0.1.0"\ntarget="javascript"\n')
      command=[str(gleam),'build','--target','javascript']
      # Gleam accepts a project root by running under that directory.
     elif variant.startswith('native'):
      (directory/'main.gleam').write_text(source);command=[str(native_before if variant=='native-before' else native),'main.gleam',str(output),'--source-root',str(directory)]
     else:
      (directory/'main.c').write_text(c_source);command=[gcc,'-O2' if variant=='gcc-o2' else '-O3','-std=c11',str(directory/'main.c'),'-o',str(output)]
     previous=Path.cwd()
     try:
      os.chdir(directory);r=measure(command)
     finally:os.chdir(previous)
     if repetition>=0:receipt['samples'].append(dict(workload=name,phase='compile',variant=variant,repetition=repetition,**r))
     if variant=='gleam-js':
      module=directory/'build/dev/javascript/surface_baseline/main.mjs';assert module.is_file()
      runner=directory/'runner.mjs';runner.write_text(f'import {{run}} from {json.dumps(module.as_uri())};console.log(run());\n')
      program=[node,str(runner)]
      files=sorted((directory/'build/dev/javascript').rglob('*.mjs'))
      artifact=dict(kind='generated JS payload; Node runtime excluded',bytes=sum(p.stat().st_size for p in files),files={str(p.relative_to(directory)):dict(bytes=p.stat().st_size,sha256=sha(p.read_bytes())) for p in files})
     else:
      program=[str(output)];artifact=dict(kind='standalone ELF' if variant.startswith('native') else 'dynamic ELF; libc/loader excluded',bytes=output.stat().st_size,sha256=sha(output.read_bytes()))
     if repetition==0:
      programs[variant]=program;receipt['artifacts'].setdefault(name,{})[variant]=artifact
     elif repetition>0:assert artifact==receipt['artifacts'][name][variant],(name,variant,'nondeterministic output')
   # Warm up each runtime, then rotate fresh-process samples independently.
   for repetition in range(-1,a.repetitions):
    order=variants[repetition%len(variants):]+variants[:repetition%len(variants)]
    if repetition%2:order=list(reversed(order))
    for variant in order:
     r=measure(programs[variant]);assert r['stdout']==str(wanted)+'\n' and not r['stderr'],(name,variant,r)
     if repetition>=0:receipt['samples'].append(dict(workload=name,phase='run',variant=variant,repetition=repetition,**r))
   print(json.dumps(dict(workload=name,completed=True)),flush=True)
 for name in cases:
  for phase in ['compile','run']:
   for variant in variants:
    rows=[r for r in receipt['samples'] if r['workload']==name and r['phase']==phase and r['variant']==variant]
    receipt['summaries'].append(dict(workload=name,phase=phase,variant=variant,
     medianWallSeconds=statistics.median(r['wallSeconds'] for r in rows),minWallSeconds=min(r['wallSeconds'] for r in rows),maxWallSeconds=max(r['wallSeconds'] for r in rows),medianCPUSeconds=statistics.median(r['userSeconds']+r['systemSeconds'] for r in rows),maxPeakRSSKiB=max(r['peakRSSKiB'] for r in rows)))
 receipt['environment']['loadAfter']=list(os.getloadavg());receipt['complete']=True
except BaseException as error:
 receipt['failure']=repr(error)
 raise
finally:
 Path(a.receipt).write_text(json.dumps(receipt,indent=2)+'\n')
print('Surface baselines complete; checked all outputs, fresh builds and repeated runs')
