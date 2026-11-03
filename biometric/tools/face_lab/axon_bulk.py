#!/usr/bin/env python3
"""Acquire relevant version-pinned public AXON sample archives outside the monorepo."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from collections import Counter
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import sqlite3
import stat
import subprocess
import time
import urllib.parse
import urllib.request
import zipfile
from data import external_directory, fetch_json

MAX_DATASET = 16 * 1024**3
MAX_FILES = 100000
IMAGE_EXTENSIONS = {'.jpg', '.jpeg', '.png', '.heic', '.heif', '.webp', '.bmp', '.tif', '.tiff'}
VIDEO_EXTENSIONS = {'.mp4', '.mov', '.avi', '.mkv', '.webm', '.m4v'}


def relevant(item):
    text = (item['ref']+' '+item['title']).lower()
    return any(word in text for word in ('face', 'selfie', 'spoof', 'liveness', 'replay', 'mask', 'ibeta'))


def inventory(ref, version):
    view = fetch_json('https://www.kaggle.com/api/v1/datasets/view/'+ref)
    if view['currentVersionNumber'] != version:
        raise ValueError('Dataset version drift; review new catalogue before downloading')
    files = []; token = None; seen = set()
    for _ in range(1000):
        query = {'pageSize': 200}
        if token:
            query['pageToken'] = token
        page = fetch_json('https://www.kaggle.com/api/v1/datasets/list/'+ref+'?'+urllib.parse.urlencode(query))
        files.extend({'name': item['name'], 'bytes': item['totalBytes']} for item in page['datasetFiles'])
        token = page.get('nextPageToken') or page.get('nextPageTokenNullable')
        if not token:
            break
        if token in seen:
            raise ValueError('Repeated file-inventory page')
        seen.add(token)
    else:
        raise ValueError('File inventory exceeds page bound')
    if not files or len(files) > MAX_FILES or len({item['name'] for item in files}) != len(files):
        raise ValueError('Empty, duplicate or oversized file inventory')
    if sum(item['bytes'] for item in files) > MAX_DATASET:
        raise ValueError('Expanded dataset exceeds acquisition bound')
    return {'ref': ref, 'version': version, 'license': view.get('licenseName'), 'files': files}


def safe_entries(archive, metadata):
    entries = []; names = set()
    if len(archive.infolist()) > MAX_FILES:
        raise ValueError('Archive entry count exceeds bound')
    for item in archive.infolist():
        path = PurePosixPath(item.filename)
        canonical = str(path)
        if path.is_absolute() or '..' in path.parts or '\\' in item.filename or '\x00' in item.filename or canonical in names:
            raise ValueError('Unsafe or duplicate archive path')
        if stat.S_ISLNK(item.external_attr >> 16):
            raise ValueError('Archive symlink rejected')
        names.add(canonical)
        if not item.is_dir():
            entries.append(item)
    if {item.filename: item.file_size for item in entries} != {item['name']: item['bytes'] for item in metadata['files']}:
        raise ValueError('Archive differs from pinned published file inventory')
    if sum(item.file_size for item in entries) > MAX_DATASET:
        raise ValueError('Expanded archive exceeds bound')
    return entries


def sha256(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(4*1024*1024), b''):
            result.update(block)
    return result.hexdigest()


def existing_canonical(item, root):
    canonical=root/'data/canonical'; database=canonical/'index.sqlite'
    if not database.is_file():
        return None
    ref=item['ref']; version=item['currentVersionNumber']
    key=hashlib.sha256((ref+'@'+str(version)).encode()).hexdigest()
    receipt_path=canonical/'provenance'/(key+'.json')
    if not receipt_path.is_file():
        return None
    receipt=json.loads(receipt_path.read_text())
    if receipt.get('sourceCleanup')!='complete':
        return None
    connection=sqlite3.connect('file:'+str(database)+'?mode=ro',uri=True)
    try:
        dataset=connection.execute('SELECT expected_files,state FROM datasets WHERE ref=? AND version=?',(ref,version)).fetchone()
        if not dataset or dataset[1]!='canonical_source_retired':
            return None
        rows=connection.execute('SELECT m.path,m.sha256,m.bytes,m.kind FROM observations o JOIN media m ON m.sha256=o.media_sha256 WHERE o.dataset_ref=? AND o.dataset_version=?',(ref,version)).fetchall()
        annotations=connection.execute('SELECT sha256,content FROM annotations WHERE dataset_ref=? AND dataset_version=?',(ref,version)).fetchall()
        if len(rows)+len(annotations)!=dataset[0]:
            raise ValueError('Canonical counts changed; acquisition must not silently replace them')
        for path,digest,size,_ in set(rows):
            target=canonical/path
            if target.is_symlink() or not target.resolve().is_relative_to(canonical.resolve()) or not target.is_file() or target.stat().st_size!=size or sha256(target)!=digest:
                raise ValueError('Canonical bytes changed; explicit repair required')
        if any(hashlib.sha256(blob).hexdigest()!=digest for digest,blob in annotations):
            raise ValueError('Canonical annotation digest changed')
        counts=Counter(row[3] for row in rows)
        return {'ref':ref,'version':version,'title':item['title'],'files':dataset[0],
                'media':{'images':counts['image'],'videos':counts['video'],'other':len(annotations)},
                'path':str(canonical),'archiveSHA256':receipt['archiveSHA256'],'status':'canonical_source_retired'}
    finally:
        connection.close()


def download_aria2(destination, temporary, root, ref, version, metadata, name):
    command = ['aria2c', '--no-conf=true', '--continue=true', '--always-resume=true',
               '--auto-file-renaming=false', '--allow-overwrite=false', '--file-allocation=none',
               '--check-certificate=true', '--max-connection-per-server=8', '--split=8',
               '--min-split-size=8M', '--max-tries=5', '--retry-wait=3', '--connect-timeout=20',
               '--timeout=60', '--summary-interval=0', '--console-log-level=error', '--download-result=hide',
               '--dir='+str(destination), '--out='+temporary.name,
               'https://www.kaggle.com/api/v1/datasets/download/'+ref+'?datasetVersionNumber='+str(version)]
    private_log = root/'data/catalog'/(name+'-transfer.log')
    with private_log.open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=14400)
    if temporary.stat().st_size > MAX_DATASET:
        raise ValueError('Archive download exceeds bound')
    with zipfile.ZipFile(temporary) as archive:
        safe_entries(archive, metadata)


def stream_urllib_download(temporary, ref, version):
    url = 'https://www.kaggle.com/api/v1/datasets/download/'+ref+'?datasetVersionNumber='+str(version)
    total = temporary.stat().st_size if temporary.exists() else 0
    request = urllib.request.Request(url, headers={'Range': 'bytes='+str(total)+'-'} if total else {})
    response = urllib.request.urlopen(request, timeout=90)
    append = total > 0 and response.status == 206 and response.headers.get('Content-Range', '').startswith('bytes '+str(total)+'-')
    if response.status == 206 and not append:
        response.close()
        raise ValueError('Unexpected partial response')
    if not append:
        total = 0
    reported = total // (256*1024**2)
    with response, temporary.open('ab' if append else 'wb') as output:
        for block in iter(lambda: response.read(4*1024*1024), b''):
            total += len(block)
            if total > MAX_DATASET:
                raise ValueError('Archive download exceeds bound')
            output.write(block)
            if total // (256*1024**2) > reported:
                reported = total // (256*1024**2)
                print('DOWNLOADING '+ref+' bytes='+str(total), flush=True)


def download_urllib(temporary, archive_path, ref, version, metadata):
    for attempt in range(3):
        try:
            stream_urllib_download(temporary, ref, version)
            with zipfile.ZipFile(temporary) as archive:
                safe_entries(archive, metadata)
            temporary.rename(archive_path)
            return
        except Exception as error:
            if isinstance(error, (ValueError, zipfile.BadZipFile)):
                temporary.unlink(missing_ok=True)
            if attempt == 2:
                raise
            time.sleep(2)


def extract_entry(archive, entry, files_root, image_module, counts, extensions):
    target = files_root/entry.filename
    if target.is_symlink() or not target.resolve().is_relative_to(files_root.resolve()):
        raise ValueError('Extraction target escapes private dataset directory')
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    digest = hashlib.sha256()
    size = 0
    # Stream every byte again: verify CRC and refresh incomplete extractions on retry.
    with archive.open(entry) as source, target.open('wb') as output:
        for block in iter(lambda: source.read(4*1024*1024), b''):
            size += len(block)
            if size > entry.file_size:
                raise ValueError('Expanded file exceeds declared size')
            output.write(block)
            digest.update(block)
    if size != entry.file_size:
        raise ValueError('Expanded file size mismatch')
    extension = target.suffix.lower()
    extensions[extension] += 1
    row = {'path': entry.filename, 'bytes': size, 'sha256': digest.hexdigest()}
    if extension in IMAGE_EXTENSIONS:
        with image_module.open(target) as image:
            row.update({'format': image.format, 'width': image.width, 'height': image.height})
            image.verify()
        counts['images'] += 1
    elif extension in VIDEO_EXTENSIONS:
        counts['videos'] += 1
    else:
        counts['other'] += 1
    return row


def acquire(item, root, transport='urllib'):
    ref = item['ref']
    version = item['currentVersionNumber']
    previous = existing_canonical(item, root)
    if previous:
        return previous
    name = 'axon-selfie-id-v6' if ref.endswith('/selfie-and-official-id-photo-dataset-18k-images') and version == 6 else ref.split('/')[1]+'-v'+str(version)
    destination = root/'data/quarantine'/name
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    metadata = inventory(ref, version)
    (destination/'source-metadata.json').write_text(json.dumps(metadata, indent=2)+'\n')
    archive_path = destination/'dataset.zip'
    temporary = destination/'dataset.zip.partial'
    if not archive_path.exists():
        if transport == 'urllib' and temporary.with_name(temporary.name+'.aria2').exists():
            raise ValueError('Segmented download must resume with aria2; sparse file size is not a contiguous prefix')
        if transport == 'aria2':
            download_aria2(destination, temporary, root, ref, version, metadata, name)
            temporary.rename(archive_path)
    if not archive_path.exists():
        download_urllib(temporary, archive_path, ref, version, metadata)
    from PIL import Image
    import pillow_heif
    pillow_heif.register_heif_opener()
    files_root = destination/'files'
    files_root.mkdir(exist_ok=True, mode=0o700)
    counts = Counter()
    extensions = Counter()
    manifest = []
    with zipfile.ZipFile(archive_path) as archive:
        for entry in safe_entries(archive, metadata):
            manifest.append(extract_entry(archive, entry, files_root, Image, counts, extensions))
    (destination/'file-manifest.jsonl').write_text(''.join(json.dumps(row)+'\n' for row in manifest))
    summary = {'ref': ref, 'version': version, 'title': item['title'], 'archiveBytes': archive_path.stat().st_size,
               'archiveSHA256': sha256(archive_path), 'files': len(manifest), 'media': dict(counts),
               'extensions': dict(extensions), 'expandedBytes': sum(row['bytes'] for row in manifest),
               'path': str(destination), 'license': metadata['license'], 'status': 'downloaded-extracted-inventory-and-crc-verified',
               'videoDecodeVerified': False, 'subjectIdentityCount': 'not established', 'evaluationSplitsAssigned': False}
    (destination/'acquisition-summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workdir', type=Path, required=True)
    parser.add_argument('--catalog', type=Path, required=True)
    parser.add_argument('--workers', type=int, choices=range(1, 9), default=8)
    parser.add_argument('--transport',choices=['urllib','aria2'],default='urllib')
    args = parser.parse_args(); root = external_directory(args.workdir)
    catalog = json.loads(args.catalog.read_text()); selected = [item for item in catalog['datasets'] if relevant(item)]
    required = sum(item.get('totalBytes', 0) for item in selected)*2 + 8*1024**3
    if shutil.disk_usage(root).free < required:
        raise SystemExit('Insufficient free disk for bounded archive and extracted samples')
    record = {'selected': len(selected), 'selection': 'Public AXON face/identity, ageing, bona fide, synthetic-face and presentation-attack samples; unrelated voice/palm/MRI/phone-damage/POV datasets excluded', 'complete': [], 'failed': []}
    output = root/'data/catalog/axon-acquisition.json'
    print('Selected '+str(len(selected))+' public datasets', flush=True)
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        pending = {pool.submit(acquire, item, root, args.transport): item for item in selected}
        for future in as_completed(pending):
            item = pending[future]
            try:
                summary = future.result(); record['complete'].append(summary)
                print('VERIFIED '+summary['ref']+' files='+str(summary['files'])+' '+json.dumps(summary['media']), flush=True)
            except Exception as error:
                record['failed'].append({'ref': item['ref'], 'error': type(error).__name__, 'detail': str(error)[:300]})
                print('FAILED '+item['ref']+' '+type(error).__name__, flush=True)
            output.write_text(json.dumps(record, indent=2)+'\n')
    return int(bool(record['failed']))


if __name__ == '__main__':
    raise SystemExit(main())
