#!/usr/bin/env python3
"""Apply reviewed effort metadata to Kimi model aliases without rewriting credentials.

Input JSON maps existing aliases to {"support_efforts": ["low", ...]}.
Only explicit metadata is stored; no levels are inferred from a model name.
"""
import argparse
import datetime
import json
import os
import pathlib
import re
import tempfile
try:
    import tomllib
except ImportError:
    from pip._vendor import tomli as tomllib


def updated_config(source, changes):
    config = tomllib.loads(source)
    additions = []
    for alias, value in changes.items():
        if alias not in config.get('models', {}): raise ValueError('Model alias is not configured: ' + alias)
        if set(value) != {'support_efforts'}: raise ValueError('Only support_efforts can be changed')
        levels = value['support_efforts']
        if not isinstance(levels, list) or not levels or not all(isinstance(x, str) and re.fullmatch('[a-z]+', x) for x in levels):
            raise ValueError('Expected a nonempty list of effort names')
        if len(set(levels)) != len(levels): raise ValueError('Duplicate effort names')
        model = config['models'][alias]
        current = model.get('overrides', {}).get('support_efforts', model.get('support_efforts'))
        if current == levels: continue
        if current is not None: raise ValueError('Refusing to overwrite existing effort metadata: ' + alias)
        # Preserve every original byte. Existing override tables need an explicit
        # edit rather than a second table with the same name.
        if 'overrides' in model: raise ValueError('An override table already exists: ' + alias)
        additions.append('\n[models.' + json.dumps(alias) + '.overrides]\nsupport_efforts = ' + json.dumps(levels) + '\n')
    result = source + ''.join(additions)
    tomllib.loads(result)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('metadata', type=pathlib.Path)
    parser.add_argument('--config', type=pathlib.Path, default=pathlib.Path.home()/'.kimi-code/config.toml')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    changes = json.loads(args.metadata.read_text())
    source = args.config.read_text()
    result = updated_config(source, changes)
    print(json.dumps({'models': list(changes), 'changed': result != source, 'applied': args.apply}, ensure_ascii=False))
    if not args.apply or result == source: return
    backup = args.config.with_name(args.config.name + '.before-perch-efforts-' + datetime.datetime.now().strftime('%Y%m%d%H%M%S%f'))
    # Backups contain the user's existing secrets and remain private, beside the config.
    fd = os.open(backup, os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as f: f.write(source)
    fd, temporary = tempfile.mkstemp(dir=args.config.parent, prefix='.perch-efforts-')
    try:
        with os.fdopen(fd, 'w') as f: f.write(result)
        if args.config.read_text() != source: raise RuntimeError('Configuration changed during the update')
        os.replace(temporary, args.config)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)
    print('Saved a private backup next to the config.')


if __name__ == '__main__': main()
