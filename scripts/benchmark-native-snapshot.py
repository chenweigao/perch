#!/usr/bin/env python3
"""Isolated handler snapshot work; imports no user state and starts no agents."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import statistics
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('root', type=Path)
parser.add_argument('variant', choices=['baseline', 'candidate'])
args = parser.parse_args()
with tempfile.TemporaryDirectory() as directory:
    os.environ['AWB_NATIVE_ROOT'] = directory
    spec = importlib.util.spec_from_file_location('broker', args.root / 'remote/native-agent-service.py')
    broker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(broker)
    rows = [{'id': str(i), 'role': 'assistant', 'content': [
        {'type': 'text', 'text': '中文结果 and English identifiers. ' * 24},
        {'type': 'tool_result', 'output': {'rows': ['synthetic'] * 16}}]} for i in range(400)]
    session = broker.Session(dict(id='fixture', provider='omp', cwd='/fixture', title='Fixture',
                                  model='', busy=False, archived=False, updated=0, revision=7,
                                  completed=200, messages=rows, interactions=[], error=None))
    def read(revision):
        if args.variant == 'candidate':
            return session.snapshot(revision)
        value = session.snapshot()
        return {'unchanged': True} if revision == str(value['revision']) else value
    assert read('7') == {'unchanged': True}
    assert len(read('6')['messages']) == 400
    results = {'variant': args.variant, 'messages': 400, 'turns': 200}
    for label, revision in [('idle_revision_hit', '7'), ('changed_snapshot', '6')]:
        samples = []
        for _ in range(7):
            start = time.perf_counter()
            for _ in range(100):
                read(revision)
            samples.append((time.perf_counter() - start) * 10)
        results[label] = {'median_ms': statistics.median(samples), 'min_ms': min(samples), 'max_ms': max(samples)}
    print(json.dumps(results, indent=2, sort_keys=True))
