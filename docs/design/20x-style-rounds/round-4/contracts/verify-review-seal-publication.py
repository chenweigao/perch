#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import re


EXPECTED_RAW_HASHES = {
    'review-input-sha256-publication.json': '60f0e938812cb7750ee9d708a6ec4535ae3f7ca91e89d42bd5872f374be6992d',
    'review-image-input-sha256-publication.json': '8ce41000660971c326b46db1425884de2bf92b0242c16f643be1559659d91d96',
}


def reconstruct(publication_path):
    publication = json.loads(publication_path.read_text())
    if publication['representation'] != 'sha256-records-v1':
        raise ValueError('Unknown publication representation')
    if publication['original_byte_sha256'] != EXPECTED_RAW_HASHES[publication_path.name]:
        raise ValueError('Original identity differs from the independent-review receipt')
    if Path(publication['original_file']).name != publication_path.name.replace('-publication.json', '.json'):
        raise ValueError('Original filename does not match')
    document = dict(publication['original_document'])
    records = document['sha256']
    if not isinstance(records, list):
        raise ValueError('Expected ordered SHA256 records')
    mapping = {}
    for record in records:
        filename = record['file']
        digest = record['sha256']
        if filename in mapping or re.fullmatch(r'[0-9a-f]{64}', digest) is None:
            raise ValueError('Duplicate file or invalid SHA256')
        mapping[filename] = digest
    document['sha256'] = mapping
    original_bytes = (json.dumps(document, ensure_ascii=False, indent=2) + '\n').encode()
    if hashlib.sha256(original_bytes).hexdigest() != publication['original_byte_sha256']:
        raise ValueError('Original byte identity does not match')
    return publication, original_bytes, len(mapping)


def main():
    parser = argparse.ArgumentParser(description='Verify lossless plaintext seal publication; never changes scanner policy.')
    parser.add_argument('--restore-dir', type=Path)
    arguments = parser.parse_args()
    contracts = Path(__file__).resolve().parent
    summaries = []
    for filename in ('review-input-sha256-publication.json', 'review-image-input-sha256-publication.json'):
        publication, original_bytes, record_count = reconstruct(contracts / filename)
        original_path = Path(publication['original_file'])
        if original_path.exists() and original_path.read_bytes() != original_bytes:
            raise ValueError('Existing original bytes differ')
        if arguments.restore_dir is not None:
            arguments.restore_dir.mkdir(parents=True, exist_ok=True)
            destination = arguments.restore_dir / original_path.name
            if destination.exists():
                if destination.read_bytes() != original_bytes:
                    raise ValueError('Refusing to replace a different original')
            else:
                destination.write_bytes(original_bytes)
        summaries.append({'publication': filename, 'protected_files': record_count, 'original_byte_sha256': publication['original_byte_sha256'], 'exact_original_bytes_reconstructed': True})
    print(json.dumps({'status': 'PASS', 'seals': summaries}, indent=2))


if __name__ == '__main__':
    main()
