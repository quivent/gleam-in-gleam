#!/usr/bin/env python3
"""Build portable interactive documentation; no compiler/runtime dependencies."""
from pathlib import Path
import argparse
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parent.parent

def read_json(path):
    return json.loads((ROOT / path).read_text())

def build():
    roadmap = read_json('docs/roadmap.json')
    verification = read_json(roadmap['verification'])
    io = read_json(roadmap['ioVerification'])
    assert roadmap['schema'] == 'gleam-in-gleam.interactive-roadmap/1'
    assert len(roadmap['steps']) == 8
    ids = [s['id'] for s in roadmap['steps']]
    assert len(set(ids)) == 8 and roadmap['focus'] in ids
    assert 0 <= roadmap['estimate']['percent'] <= 100
    assert roadmap['estimate']['kind'] == 'subjective'
    assert re.fullmatch('[0-9a-f]{40}', roadmap['sourceRevision'])
    criteria = []
    for step in roadmap['steps']:
        assert re.fullmatch('[a-z][a-z-]+', step['id'])
        assert step['status'] in ['verified', 'next', 'partial', 'pending']
        assert step['scope'] in ['core', 'extension']
        assert step['design'] and step['acceptance'] and step['nextAction']
        assert all(id in ids for id in step['related'])
        criteria.extend(c['id'] for c in step['acceptance'])
        for item in step['evidence'] + ([dict(path=step['spec'])] if step['spec'] else []):
            target = (ROOT / item['path']).resolve()
            assert target.is_relative_to(ROOT) and target.is_file(), target
    assert len(set(criteria)) == len(criteria)
    assert verification['sourceSHA256'] == io['sourceSHA256'], 'Evidence snapshots disagree'
    assert verification['nativeCLI']['artifact'] == io['artifact'], 'CLI artifact receipts disagree'
    assert verification['tests']['failed'] == 0
    assert verification['tests']['passed'] == verification['tests']['total']
    assert not io['artifact']['dynamicLoader'] and not io['artifact']['dynamicSegment']
    roadmap['metrics'] = dict(tests=verification['tests']['passed'],
        upstream=verification['totalFreshUpstreamComparisons'],
        examples=len(verification['examples']),cliBytes=io['artifact']['bytes'],
        sourceLimitBytes=verification['nativeCLI']['sourceLimitBytes'],
        observedAt=verification['observedAt'])
    roadmap['evidenceSHA256'] = {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
                               for path in [roadmap['verification'], roadmap['ioVerification']]}
    template = (ROOT / 'docs/roadmap.template.html').read_text()
    assert template.count('__ROADMAP_DATA__') == 1
    encoded = json.dumps(roadmap, ensure_ascii=False, indent=2).replace('<', '\\u003c').replace('>', '\\u003e').replace('&', '\\u0026')
    assert template.count('__ROADMAP_PERCENT__') == 3
    return template.replace('__ROADMAP_DATA__', encoded).replace('__ROADMAP_PERCENT__', str(roadmap['estimate']['percent']))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Fail if committed HTML is stale')
    args = parser.parse_args()
    rendered = build()
    output = ROOT / 'docs/roadmap.html'
    if args.check:
        if not output.exists() or output.read_text() != rendered:
            raise SystemExit('Interactive roadmap is stale; run python3 tools/render_roadmap.py')
        print('Interactive roadmap is current; eight specs and evidence links validated')
    else:
        output.write_text(rendered)
        print('Wrote docs/roadmap.html (portable, offline, dependency-free documentation)')
