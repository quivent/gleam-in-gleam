#!/usr/bin/env python3
"""Development-only native/upstream execution oracle for the fused assembler."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('compiler')
p.add_argument('receipt')
a = p.parse_args()
compiler = Path(a.compiler).resolve()
gleam = Path.home()/'.local/share/gleam-native/bootstrap/1.19.2/gleam'
sha = lambda b: hashlib.sha256(b).hexdigest()
inputs = {name: (ROOT/name).read_bytes() for name in ['test/fusion_probe.gleam', 'src/native/assembler.gleam', 'src/native/core.gleam']}
expected = 'True\nTrue\nTrue\nTrue\n1\n2\nTrue\n'
report = dict(schema='gta.fusion-execution/1', observedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
              harnessSHA256=sha(Path(__file__).read_bytes()), compilerSHA256=sha(compiler.read_bytes()),
              sourceSHA256={k:sha(v) for k,v in inputs.items()}, complete=False,
              checks=['forward/backward relocation bytes', 'full-name hash collision safety', 'duplicate collision',
                      'first source-order missing target', 'UTF-8 labels', 'validation callback order and early exit'])
try:
    with tempfile.TemporaryDirectory(prefix='gta-fusion-oracle-') as temp:
        work=Path(temp)
        for name,data in inputs.items():
            target=work/'src'/('main.gleam' if name.startswith('test/') else name.removeprefix('src/'))
            target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
        (work/'gleam.toml').write_text('name="fusion_oracle"\nversion="0.1.0"\ntarget="javascript"\n')
        binary=work/'probe'
        compiled=subprocess.run([str(compiler),'main.gleam',str(binary),'--source-root',str(work/'src')],capture_output=True,text=True,timeout=30)
        assert compiled.returncode==0,compiled.stderr
        actual=subprocess.run([str(binary)],capture_output=True,text=True,timeout=10)
        assert actual.returncode==0 and actual.stdout==expected and not actual.stderr,(actual.returncode,actual.stdout,actual.stderr)
        subprocess.run([str(gleam),'build','--warnings-as-errors'],cwd=work,capture_output=True,text=True,check=True,timeout=30)
        module=work/'build/dev/javascript/fusion_oracle/main.mjs'
        upstream=subprocess.run(['node','--input-type=module','-e',f'import {{main}} from {json.dumps(module.as_uri())}; main();'],capture_output=True,text=True,check=True,timeout=10)
        clean=re.sub(r'\x1b\[[0-9;]*m','',upstream.stderr)
        observed='\n'.join(line for line in clean.splitlines() if re.fullmatch(r'True|False|-?\d+',line))+'\n'
        assert observed==expected,(observed,clean)
        report.update(complete=True,nativeStdout=actual.stdout,upstreamValues=observed,programSHA256=sha(binary.read_bytes()),programBytes=binary.stat().st_size)
except BaseException as error:
    report['failure']=repr(error);raise
finally:
    (ROOT/a.receipt).write_text(json.dumps(report,indent=2)+'\n')
print('Native fusion probe and original-Gleam execution agree on all checks')
