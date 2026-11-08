#!/usr/bin/env python3
"""Derive the README benchmark ledger from immutable measured receipts."""
from pathlib import Path
import argparse
import hashlib
import json
import math
import statistics

ROOT=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check',action='store_true')
args=parser.parse_args()
def read(path):return json.loads((ROOT/path).read_text())
cfg=read('benchmarks/ledger.json')
cohort=next(c for c in cfg['cohorts'] if c['id']==cfg['active'])
r=read(cohort['receipt']);q=read(cohort['qualification']);hosting=read(cfg['hostingComparison'])
assert r['complete'] and hosting['complete'] and q['tests']['failed']==0
assert r['nativeBaseline']['sha256']==cfg['fixedNativeBaseline']['compilerSHA256']
assert r['nativeCompiler']['sha256']==hosting['nativeCompiler']['sha256']
before,after=cohort['baselineVariant'],cohort['currentVariant']
labels={'startup':'Startup control','integer-recurrence':'Integer recurrence · 20M','branch-call':'Branch + call · 20M','recursive-fibonacci':'Fibonacci · n=35','list-build-map-sum':'List build/map/sum · 500K'}
def gain(base,current):
 assert base>0
 return 100*(base-current)/base
def pct(value):
 prefix='↑' if value>=1 else '↓' if value<=-1 else '≈'
 return f'{prefix} {value:+.2f}%'
def row(workload,variant,phase):return next(x for x in r['summaries'] if x['workload']==workload and x['variant']==variant and x['phase']==phase)
# Verify summaries against raw samples, and all five independent observations.
for x in r['summaries']:
 samples=[s for s in r['samples'] if all(s[k]==x[k] for k in ['workload','variant','phase'])]
 assert len(samples)>=5
 assert abs(statistics.median(s['userSeconds']+s['systemSeconds'] for s in samples)-x['medianCPUSeconds'])<1e-12
 assert all(s['exitCode']==0 and not s['timedOut'] for s in samples)
ratios=[]
for w in labels:
 if w!='startup':ratios.append(row(w,before,'run')['medianCPUSeconds']/row(w,after,'run')['medianCPUSeconds'])
speed=math.exp(sum(math.log(x) for x in ratios)/len(ratios))
lines=['<!-- GTA_BENCHMARK_LEDGER_START -->',
 '### GTA via Gleam — living benchmark ledger','',
 f'**Self-hosted native compiler · {q["tests"]["passed"]} regression checks passed.**','',
 '**Primary comparison: original upstream Gleam compilation.** '
 f'The original Gleam CLI is `{r["tools"]["gleam"]}`. '
 'It emits JavaScript; GTA emits native ELF. The source is identical within each paired experiment, '
 'but target/backend work differs. This is the original compiler, not our Node-hosted bootstrap.','',
 '| Source/workload | Original Gleam CPU | GTA CPU | CPU reduction | Original wall → GTA wall | Wall reduction |',
 '|:---|---:|---:|---:|---:|---:|']
for w in labels:
 a,b=row(w,'gleam-js','compile'),row(w,after,'compile')
 lines.append(f'| {labels[w]} | {a["medianCPUSeconds"]*1000:.3f} ms | {b["medianCPUSeconds"]*1000:.3f} ms | {pct(gain(a["medianCPUSeconds"],b["medianCPUSeconds"]))} | {a["medianWallSeconds"]*1000:.3f} → {b["medianWallSeconds"]*1000:.3f} ms | {pct(gain(a["medianWallSeconds"],b["medianWallSeconds"]))} |')
full=read(cfg['originalFullCompilation']);assert full['complete'] and full['sourceModules']==28
for x in full['summaries']:
 samples=[v for v in full['samples'] if v['variant']==x['variant']];assert len(samples)>=5
 assert abs(statistics.median(v['userSeconds']+v['systemSeconds'] for v in samples)-x['medianCPUSeconds'])<1e-12
fa=next(x for x in full['summaries'] if x['variant']=='original-gleam');fb=next(x for x in full['summaries'] if x['variant']=='gta')
lines.insert(7, f'**Full-source headline:** original Gleam **{fa["medianCPUSeconds"]:.3f} s CPU**, GTA **{fb["medianCPUSeconds"]:.3f} s CPU** — GTA uses **{fb["medianCPUSeconds"]/fa["medianCPUSeconds"]:.2f}×** the CPU on this build. Measured {full["observedAt"][:10]}.')
lines.insert(8, '')
lines.append(f'| **Full compiler · 28 modules** | **{fa["medianCPUSeconds"]:.3f} s** | **{fb["medianCPUSeconds"]:.3f} s** | **{pct(gain(fa["medianCPUSeconds"],fb["medianCPUSeconds"]))}** | **{fa["medianWallSeconds"]:.3f} → {fb["medianWallSeconds"]:.3f} s** | **{pct(gain(fa["medianWallSeconds"],fb["medianWallSeconds"]))}** |')
lines+=['',
 f'Full-source maximum RSS: original Gleam **{fa["maxPeakRSSKiB"]/1024:.1f} MiB**, '
 f'GTA **{fb["maxPeakRSSKiB"]/1024:.1f} MiB**. '
 'The full-source row has its own paired cohort; do not combine its timings with the tiny-program cohort. '
 'Positive reduction favors GTA; a negative percentage exposes a regression. '
 'Read the larger-source result alongside the tiny-input startup advantage.','',
 '[Full-source raw samples](evidence/original-gleam-full-compilation.json) · '
 '[Small-source raw samples](evidence/comparison-flags-surface-baselines.json)','',
 '**Secondary comparison: generated-program runtime against our previous native version.** '
 f'Frozen native baseline: `{cfg["fixedNativeBaseline"]["sourceRevision"][:7]}` ({cfg["fixedNativeBaseline"]["bytes"]:,} B). '
 f'Current measured code: `{cohort["sourceRevision"][:7]}` ({r["nativeCompiler"]["bytes"]:,} B). '
 'This tracks optimization of our own generated code; it is separate from original-Gleam compilation speed.','',
 'Median CPU milliseconds; positive percentages reduce cost. '
 '`≈` marks changes under 1%, not a statistical confidence claim.','',
 '| Workload | Previous native CPU | GTA CPU | CPU reduction | Wall reduction | Target-size reduction |',
 '|:---|---:|---:|---:|---:|---:|']
for w in labels:
 a,b=row(w,before,'run'),row(w,after,'run');old=r['artifacts'][w][before];new=r['artifacts'][w][after]
 lines.append(f'| {labels[w]} | {a["medianCPUSeconds"]*1000:.3f} ms | {b["medianCPUSeconds"]*1000:.3f} ms | {pct(gain(a["medianCPUSeconds"],b["medianCPUSeconds"]))} | {pct(gain(a["medianWallSeconds"],b["medianWallSeconds"]))} | {pct(gain(old["bytes"],new["bytes"]))} |')
lines+=['',f'**Suite CPU:** {speed:.3f}× the baseline throughput, or **{gain(1,1/speed):+.2f}% less CPU** '
 '(geometric mean of the four longer workload ratios; startup excluded). '
 'This summary does not replace the per-workload regressions/controls above.','',
 '**Earlier hosting architecture versus self-hosting.** The same qualified compiler logic '
 'runs under the Node bootstrap and as native GTA. These are compilation measurements, '
 'including startup; output ELF bytes and results match. This is not an older source revision.','',
 '| Compile workload | Node-hosted CPU | Self-hosted GTA CPU | CPU reduction | Wall reduction | Peak-RSS reduction |',
 '|:---|---:|---:|---:|---:|---:|']
for w in labels:
 a=next(x for x in hosting['summaries'] if x['workload']==w and x['variant']=='bootstrap-node');b=next(x for x in hosting['summaries'] if x['workload']==w and x['variant']=='native')
 lines.append(f'| {labels[w]} | {a["medianCPUSeconds"]*1000:.3f} ms | {b["medianCPUSeconds"]*1000:.3f} ms | {pct(gain(a["medianCPUSeconds"],b["medianCPUSeconds"]))} | {pct(gain(a["medianWallSeconds"],b["medianWallSeconds"]))} | {pct(gain(a["maxPeakRSSKiB"],b["maxPeakRSSKiB"]))} |')
lines+=['','Tiny-input hosting gains are dominated by launch/module initialization. '
 'They do not establish whole-project compilation speedups.','',
 '**Compiler self-build optimization history.** Each row is its own paired experiment '
 'on frozen source; percentages are not chained across different runs.','',
 '| Experiment | CPU before → after | CPU reduction | Wall reduction | Peak-RSS reduction |',
 '|:---|---:|---:|---:|---:|']
for entry in cfg['compilerExperiments']:
 data=read(entry['receipt']);assert data['complete'];m=next(x for x in data['summaries'] if x['workload']=='compile-frozen-compiler')['variants'];a,b=m['baseline'],m['candidate']
 lines.append(f'| {entry["label"]} | {a["medianCPUSeconds"]:.3f} → {b["medianCPUSeconds"]:.3f} s | {pct(gain(a["medianCPUSeconds"],b["medianCPUSeconds"]))} | {pct(gain(a["medianWallSeconds"],b["medianWallSeconds"]))} | {pct(gain(a["maxPeakRSSKiB"],b["maxPeakRSSKiB"]))} |')
lines+=['','**External references — same runtime cohort.** CPU ratios below 1× favor GTA; '
 'above 1× favor the reference. These compare supported workloads, not complete language implementations.','',
 '| Workload | GTA / upstream Gleam-Node CPU | GTA / GCC O2 CPU | GTA / GCC O3 CPU |',
 '|:---|---:|---:|---:|']
for w in labels:
 current=row(w,after,'run')['medianCPUSeconds'];values=[current/row(w,v,'run')['medianCPUSeconds'] for v in ['gleam-js','gcc-o2','gcc-o3']]
 lines.append('| '+labels[w]+' | '+' | '.join(f'{v:.3f}×' for v in values)+' |')
lines+=['','Every runtime/compile table uses five measured repeats after a warm-up; '
 'CPU affinity is pinned, source/results are checked, and fresh processes include startup. '
 'Shared-host noise and allocator/runtime differences remain material. '
 'The regression count is correctness evidence, not another benchmark score.','',
 '[Raw paired samples](evidence/comparison-flags-surface-baselines.json) · '
 '[Hosting samples](evidence/bootstrap-hosting-baseline.json) · '
 '[Full interpretation](PERFORMANCE.md) · '
 '[Ledger configuration](benchmarks/ledger.json)','',
 'Regenerate with `python3 tools/render_benchmark_ledger.py`; '
 '`--check` rejects stale README figures. Append a qualified cohort and rerun against '
 'the frozen native image to track the next optimization.','',
 '<!-- GTA_BENCHMARK_LEDGER_END -->']
block='\n'.join(lines)
readme=ROOT/'README.md';text=readme.read_text();start='<!-- GTA_BENCHMARK_LEDGER_START -->';end='<!-- GTA_BENCHMARK_LEDGER_END -->'
if start in text:
 a=text.index(start);b=text.index(end,a)+len(end);result=text[:a]+block+text[b:]
else:
 marker='## 07 · Memory & performance\n';assert marker in text;result=text.replace(marker,marker+'\n'+block+'\n',1)
if args.check:assert result==text,'README benchmark ledger is stale'
else:readme.write_text(result)
print('Benchmark ledger '+('verified' if args.check else 'rendered')+': fixed baseline, CPU/wall/RSS/size changes, hosting comparison and external references')
