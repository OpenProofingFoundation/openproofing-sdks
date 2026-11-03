"""Offline provenance checks for the versioned engineering reference copies."""
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
ARXIV_VERSION = re.compile(r'\d{4}\.\d{4,5}v\d+')


def check(root=ROOT):
    folder = root/'governance/research'
    papers = folder/'papers'
    if folder.is_symlink() or papers.is_symlink():
        raise ValueError('Research reference directory cannot be a symlink')
    manifest = json.loads((folder/'manifest.json').read_text())
    entries = manifest['papers']
    expected = {entry['localPath'] for entry in entries}
    actual = {'papers/'+path.name for path in papers.iterdir()}
    if not entries or len(expected) != len(entries) or expected != actual:
        raise ValueError('Research PDF inventory mismatch')
    for entry in entries:
        validate_entry(folder, entry)
    return len(entries)


def validate_entry(folder, entry):
    identifier = entry['id']
    if ARXIV_VERSION.fullmatch(identifier) is None:
        raise ValueError('Research source requires an immutable arXiv version')
    if entry['url'] != 'https://arxiv.org/abs/'+identifier or entry['pdfURL'] != 'https://arxiv.org/pdf/'+identifier:
        raise ValueError('Research source URL differs from version pin')
    if entry['localPath'] != 'papers/'+identifier+'.pdf':
        raise ValueError('Research path differs from version pin')
    path = folder/entry['localPath']
    if path.is_symlink() or not path.is_file():
        raise ValueError('Research source must be a regular file')
    body = path.read_bytes()
    if not body.startswith(b'%PDF-') or len(body) != entry['bytes'] or hashlib.sha256(body).hexdigest() != entry['sha256']:
        raise ValueError('Research source digest, length or PDF signature mismatch')
    if not entry.get('reviewedSections') or not entry.get('licenseURLs') or not entry.get('authors'):
        raise ValueError('Research source requires review scope, author and licence provenance')


if __name__ == '__main__':
    print('PASS pinned research reference copies: '+str(check()))
