#!/usr/bin/env python3
"""Dev-only static inspection of an exact native image and owned symbol map.

These are emitted instruction counts, NOT dynamic spill counts or benchmarks.
No disassembler or Python becomes a compiler/runtime dependency.
"""
import argparse
import bisect
import collections
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('symbols')
parser.add_argument('image')
parser.add_argument('receipt')
parser.add_argument('assembly')
args = parser.parse_args()
symbols = json.loads(Path(args.symbols).read_text())
image = Path(args.image).read_bytes()
digest = hashlib.sha256(image).hexdigest()
assert digest == symbols['artifact']['sha256'], 'Image does not match symbol map'
assert image[:4] == b'\x7fELF'
entry = struct.unpack_from('<Q', image, 24)[0]
phoff = struct.unpack_from('<Q', image, 32)[0]
base = struct.unpack_from('<Q', image, phoff + 16)[0]
with tempfile.TemporaryDirectory(prefix='gleam-frame-traffic-') as directory:
    raw = Path(directory) / 'code.bin'
    raw.write_bytes(image[entry - base:])
    result = subprocess.run(['objdump', '-D', '--no-show-raw-insn', '-b', 'binary',
                             '-m', 'i386:x86-64', f'--adjust-vma={entry}', str(raw)],
                            check=True, capture_output=True, text=True)
listing = result.stdout
instructions = []
for line in listing.splitlines():
    match = re.match(r'^\s*([0-9a-f]+):\s+([a-z][a-z0-9]*)\s*(.*)$', line)
    if match:
        instructions.append((int(match[1], 16), match[2], match[3], line))
rows = []
windows = []
addresses = [i[0] for i in instructions]
for function in symbols['functions']:
    body = instructions[bisect.bisect_left(addresses, function['start']):
                        bisect.bisect_left(addresses, function['end'])]
    counts = collections.Counter()
    for address, op, operands, line in body:
        counts['instructions'] += 1
        if '(%rbp)' in operands:
            counts['frameMemoryInstructions'] += 1
            # LEA computes an address; it does not load/store frame memory.
            if op.startswith('lea'):
                counts['frameAddressInstructions'] += 1
            elif operands.rsplit(',', 1)[-1].strip().endswith('(%rbp)'):
                counts['frameWrites'] += 1
            else:
                counts['frameReadsOrComparisons'] += 1
        if op.startswith('push'):
            counts['pushInstructions'] += 1
        if op.startswith('pop'):
            counts['popInstructions'] += 1
        if op.startswith('call'):
            counts['callInstructions'] += 1
    rows.append({**function, **counts})
    if function['name'] in ['valid@native/utf8', 'concat@native/core',
                            'binary@native/x64', 'tail_expression@native/x64']:
        windows.append('\n# ' + function['name'] + '\n' + '\n'.join(i[3] for i in body))
rows.sort(key=lambda r: r.get('frameMemoryInstructions', 0), reverse=True)
receipt = dict(schema='gleam-in-gleam.static-frame-traffic/1',
               artifact=symbols['artifact'], sourceSHA256=symbols['sourceSHA256'],
               emitterSHA256=symbols['emitterSHA256'],
               method='objdump actual image, named-function symbol ranges only',
               limitations=['Static counts are not execution frequencies or dynamic spill counts',
                            'Frame slots include locals and parameters, not just spills',
                            'Closure and runtime helpers are outside named-function ranges'],
               functions=rows,
               totals=dict(sum((collections.Counter({k: v for k, v in row.items()
                    if k not in ['name', 'start', 'end', 'frameBytes']}) for row in rows),
                    collections.Counter())))
Path(args.receipt).write_text(json.dumps(receipt, indent=2) + '\n')
Path(args.assembly).write_text('# Exact image SHA256 ' + digest + '\n' + '\n'.join(windows) + '\n')
print(json.dumps({'artifact': symbols['artifact'], 'functions': len(rows),
                  'totals': receipt['totals'], 'topFrameTraffic': rows[:3]}, indent=2))
