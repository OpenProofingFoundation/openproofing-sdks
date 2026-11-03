#!/usr/bin/env python3
"""Build one content-addressed AXON corpus and transactionally retire verified source trees."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import time
from data import external_directory
from axon_bulk import IMAGE_EXTENSIONS, VIDEO_EXTENSIONS, sha256

CANONICAL_DIRECTORY = 'data/canonical'

SCHEMA = '''
CREATE TABLE IF NOT EXISTS datasets (
 ref TEXT NOT NULL, version INTEGER NOT NULL, title TEXT NOT NULL, license TEXT,
 archive_sha256 TEXT NOT NULL, manifest_sha256 TEXT NOT NULL,
 expected_files INTEGER NOT NULL, state TEXT NOT NULL,
 PRIMARY KEY(ref,version));
CREATE TABLE IF NOT EXISTS media (
 sha256 TEXT PRIMARY KEY, kind TEXT NOT NULL, path TEXT NOT NULL UNIQUE,
 bytes INTEGER NOT NULL, format TEXT, width INTEGER, height INTEGER);
CREATE TABLE IF NOT EXISTS observations (
 observation_id TEXT PRIMARY KEY, media_sha256 TEXT NOT NULL REFERENCES media(sha256),
 dataset_ref TEXT NOT NULL, dataset_version INTEGER NOT NULL, source_locator TEXT NOT NULL,
 task_hint TEXT NOT NULL, attack_hint TEXT, hint_basis TEXT NOT NULL,
 label_state TEXT NOT NULL, verified_subject_id TEXT, verified_session_id TEXT, split TEXT,
 UNIQUE(dataset_ref,dataset_version,source_locator));
CREATE TABLE IF NOT EXISTS annotations (
 dataset_ref TEXT NOT NULL, dataset_version INTEGER NOT NULL, source_locator TEXT NOT NULL,
 sha256 TEXT NOT NULL, bytes INTEGER NOT NULL, content BLOB NOT NULL,
 PRIMARY KEY(dataset_ref,dataset_version,source_locator));
'''


def dataset_key(ref, version):
    return hashlib.sha256((ref+'@'+str(version)).encode()).hexdigest()


def hints(ref):
    if any(token in ref for token in ['selfie-and-official', 'recognition', 'historic-current']):
        return 'face_identity', None
    families = [('silicone', 'silicone_mask'), ('latex', 'latex_mask'), ('resin', 'resin_mask'),
                ('rubber', 'resin_mask'), ('mannequin', 'mannequin'), ('textile', 'cloth_mask'),
                ('wrapped', 'wrapped_paper_mask'), ('3d-paper', 'paper_3d_mask'),
                ('print-mask', 'cardboard_mask'), ('cut-out', 'paper_cutout'), ('cutout', 'paper_cutout'),
                ('photo-print', 'photo_print'), ('paper', 'paper_attack'), ('replay', 'display_replay')]
    if 'anti-spoofing-live' in ref:
        return 'face_pad', 'bona_fide'
    if 'children-faces-synthetic' in ref:
        return 'synthetic_face', None
    return 'face_pad', next((family for token, family in families if token in ref), None)


def connect(root):
    folder = root/CANONICAL_DIRECTORY; folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    connection = sqlite3.connect(folder/'index.sqlite')
    connection.execute('PRAGMA foreign_keys=ON')
    connection.executescript(SCHEMA)
    return connection


def verify_source_row(source, row):
    original = source/'files'/row['path']
    if original.is_symlink() or not original.resolve().is_relative_to((source/'files').resolve()):
        raise ValueError('Source file escapes verified acquisition')
    if not original.is_file() or original.stat().st_size != row['bytes'] or sha256(original) != row['sha256']:
        raise ValueError('Source bytes changed after acquisition')
    return original


def media_kind(suffix):
    if suffix in IMAGE_EXTENSIONS:
        return 'image'
    if suffix in VIDEO_EXTENSIONS:
        return 'video'
    return 'annotation'


def admit_media(canonical, original, row, kind, connection):
    # Real codec metadata controls image extension; source suffix only hints video container.
    extension = {'JPEG': '.jpeg', 'PNG': '.png', 'HEIF': '.heif', 'HEIC': '.heic', 'WEBP': '.webp', 'BMP': '.bmp', 'TIFF': '.tiff'}.get(row.get('format'), original.suffix.lower())
    existing = connection.execute('SELECT kind,bytes,path FROM media WHERE sha256=?', (row['sha256'],)).fetchone()
    if existing and existing[:2] != (kind, row['bytes']):
        raise ValueError('Conflicting metadata for exact duplicate media')
    relative = Path(existing[2]) if existing else Path('media')/kind/row['sha256'][:2]/(row['sha256']+extension)
    target = canonical/relative
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not target.resolve().is_relative_to(canonical.resolve()):
        raise ValueError('Canonical path escapes corpus')
    if target.exists():
        if target.is_symlink() or sha256(target) != row['sha256']:
            raise ValueError('Existing canonical bytes do not match their content address')
    else:
        os.link(original, target)
    # Protect linked source inode too; future writes must create a new derivative.
    target.chmod(0o400)
    connection.execute('INSERT OR IGNORE INTO media VALUES (?,?,?,?,?,?,?)',
                       (row['sha256'], kind, str(relative), row['bytes'], row.get('format'), row.get('width'), row.get('height')))


def admit_row(source, row, canonical, connection, ref, version, task, attack):
    original = verify_source_row(source, row)
    kind = media_kind(original.suffix.lower())
    if kind == 'annotation':
        if row['bytes'] > 64*1024**2:
            raise ValueError('Oversized annotation requires a specific normalization contract')
        connection.execute('INSERT OR REPLACE INTO annotations VALUES (?,?,?,?,?,?)',
                           (ref, version, row['path'], row['sha256'], row['bytes'], original.read_bytes()))
        return kind
    admit_media(canonical, original, row, kind, connection)
    observation = hashlib.sha256((ref+'@'+str(version)+'/'+row['path']).encode()).hexdigest()
    connection.execute('INSERT OR REPLACE INTO observations VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
                       (observation, row['sha256'], ref, version, row['path'], task, attack,
                        'provider_dataset_title_unverified', 'unreviewed', None, None, None))
    return kind


def reconcile_rows(connection, ref, version, expected):
    stored = connection.execute('SELECT COUNT(*) FROM observations WHERE dataset_ref=? AND dataset_version=?', (ref, version)).fetchone()[0]
    stored += connection.execute('SELECT COUNT(*) FROM annotations WHERE dataset_ref=? AND dataset_version=?', (ref, version)).fetchone()[0]
    if stored != expected:
        raise ValueError('Canonical record count does not reconcile with acquisition')
    connection.execute('UPDATE datasets SET state=? WHERE ref=? AND version=?', ('canonical_verified', ref, version))


def canonicalize(root, source, connection, retire=False):
    quarantine = (root/'data/quarantine').resolve()
    source = source.resolve()
    if source.parent != quarantine or source.is_symlink():
        raise ValueError('Unexpected source directory; cleanup cannot target other paths')
    receipt = json.loads((source/'acquisition-summary.json').read_text())
    if receipt['status'] != 'downloaded-extracted-inventory-and-crc-verified':
        raise ValueError('Dataset acquisition is not verified')
    ref = receipt['ref']
    version = receipt['version']
    key = dataset_key(ref, version)
    manifest_path = source/'file-manifest.jsonl'
    rows = [json.loads(line) for line in manifest_path.read_text().splitlines()]
    if len(rows) != receipt['files'] or len({row['path'] for row in rows}) != len(rows):
        raise ValueError('Acquisition file inventory differs')
    if sha256(source/'dataset.zip') != receipt['archiveSHA256']:
        raise ValueError('Archive digest changed before migration')
    canonical = root/CANONICAL_DIRECTORY
    counts = Counter()
    task, attack = hints(ref)
    with connection:
        connection.execute('INSERT OR REPLACE INTO datasets VALUES (?,?,?,?,?,?,?,?)',
                           (ref, version, receipt['title'], receipt.get('license'), receipt['archiveSHA256'], sha256(manifest_path), len(rows), 'migrating'))
        for row in rows:
            counts[admit_row(source, row, canonical, connection, ref, version, task, attack)] += 1
        reconcile_rows(connection, ref, version, len(rows))
    migrations = canonical/'provenance'
    migrations.mkdir(exist_ok=True, mode=0o700)
    result = {'schemaVersion': 1, 'ref': ref, 'version': version, 'archiveSHA256': receipt['archiveSHA256'],
              'sourceFiles': len(rows), 'canonicalObservations': dict(counts), 'sourceBytesVerified': True,
              'canonicalMediaBytesPreserved': True, 'identityAndSessionLabels': 'unreviewed',
              'splits': 'unassigned', 'sourceCleanup': 'pending' if retire else 'not_requested'}
    record = migrations/(key+'.json')
    record.write_text(json.dumps(result, indent=2)+'\n')
    if retire:
        # Owner-authorized removal only after committed byte/count reconciliation.
        shutil.rmtree(source)
        connection.execute('UPDATE datasets SET state=? WHERE ref=? AND version=?', ('canonical_source_retired', ref, version))
        connection.commit()
        result['sourceCleanup'] = 'complete'
        record.write_text(json.dumps(result, indent=2)+'\n')
    return result


def summarize(root, connection):
    result = {'schemaVersion': 1, 'canonicalRoot': str(root/CANONICAL_DIRECTORY), 'index': 'index.sqlite',
              'datasets': connection.execute("SELECT COUNT(*) FROM datasets WHERE state IN ('canonical_verified','canonical_source_retired')").fetchone()[0],
              'uniqueMedia': dict(connection.execute('SELECT kind,COUNT(*) FROM media GROUP BY kind')),
              'sourceObservations': connection.execute('SELECT COUNT(*) FROM observations').fetchone()[0],
              'annotationRecords': connection.execute('SELECT COUNT(*) FROM annotations').fetchone()[0],
              'verifiedSubjects': connection.execute('SELECT COUNT(DISTINCT verified_subject_id) FROM observations WHERE verified_subject_id IS NOT NULL').fetchone()[0],
              'splitStatus': 'unassigned', 'labelStatus': 'provider hints only; requires review',
              'schema': 'Kenshiki canonical corpus v1; provider title hints do not establish attack ground truth or ID-document PAD coverage'}
    (root/'data/canonical/summary.json').write_text(json.dumps(result, indent=2)+'\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workdir', type=Path, required=True)
    parser.add_argument('--retire-sources', action='store_true')
    parser.add_argument('--watch', action='store_true')
    parser.add_argument('--expected', type=int, default=29)
    args = parser.parse_args(); root = external_directory(args.workdir); connection = connect(root)
    while True:
        for source in sorted((root/'data/quarantine').glob('*')):
            if not source.is_dir() or not (source/'acquisition-summary.json').is_file():
                continue
            try:
                result = canonicalize(root, source, connection, args.retire_sources)
                print('CANONICAL '+result['ref']+' files='+str(result['sourceFiles'])+' cleanup='+result['sourceCleanup'], flush=True)
            except (OSError, ValueError, sqlite3.Error) as error:
                print('FAILED '+source.name+' '+type(error).__name__+': '+str(error)[:200], flush=True)
        result = summarize(root, connection)
        if not args.watch or result['datasets'] >= args.expected:
            print(json.dumps(result, indent=2), flush=True); break
        time.sleep(5)
    connection.close()


if __name__ == '__main__':
    main()
