#!/usr/bin/env python3
"""Dev-only byte/diagnostic equivalence between native compilers over the full corpus."""
import argparse,datetime,hashlib,json,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser(description=__doc__);p.add_argument('baseline');p.add_argument('candidate');p.add_argument('receipt');a=p.parse_args()
sha=lambda b:hashlib.sha256(b).hexdigest()
proof=json.loads((ROOT/'evidence/static-parameters-native-rebuilds.json').read_text());fixtures=[]
for path,h in proof['fixtureSHA256'].items():
 b=(ROOT/path).read_bytes();assert sha(b)==h;data=json.loads(b)
 if path.endswith('grammar-fixtures.json'):data=[dict(f,entry='main',files={'main':f['source']}) for f in data]
 fixtures+=data
binaries={'baseline':Path(a.baseline).resolve(),'candidate':Path(a.candidate).resolve()}
r=dict(schema='gta.parameter-output-equivalence/1',observedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),harnessSHA256=sha(Path(__file__).read_bytes()),complete=False,binaries={n:sha(p.read_bytes()) for n,p in binaries.items()},fixtureSHA256=proof['fixtureSHA256'],cases=[])
try:
 with tempfile.TemporaryDirectory(prefix='gta-binding-equivalence-') as temp:
  work=Path(temp)
  for i,f in enumerate(fixtures):
   folder=work/str(i);folder.mkdir();src=folder/'src';src.mkdir()
   for name,text in f['files'].items():target=src/(name+'.gleam');target.parent.mkdir(parents=True,exist_ok=True);target.write_text(text)
   observations={}
   for variant,binary in binaries.items():
    out=folder/variant
    ran=subprocess.run([str(binary),f['entry']+'.gleam',str(out),'--source-root',str(src)],capture_output=True,text=True,timeout=10)
    assert (ran.returncode==0)==f['accepted'],(f['name'],variant,ran.returncode,ran.stderr)
    if f['accepted']:
     assert not ran.stdout and not ran.stderr;observations[variant]=dict(outputSHA256=sha(out.read_bytes()),bytes=out.stat().st_size)
    else:
     assert ran.returncode in [1,2] and not out.exists();observations[variant]=dict(exitCode=ran.returncode,diagnostic=ran.stderr)
   assert observations['baseline']==observations['candidate'],(f['name'],observations)
   r['cases'].append(dict(name=f['name'],accepted=f['accepted'],identical=True,**observations['candidate']))
 r.update(complete=True,total=len(r['cases']),accepted=sum(f['accepted'] for f in r['cases']),rejected=sum(not f['accepted'] for f in r['cases']))
except BaseException as error:r['failure']=repr(error);raise
finally:(ROOT/a.receipt).write_text(json.dumps(r,indent=2)+'\n')
print('Native byte/diagnostic equivalence:',r['total'],'cases')
