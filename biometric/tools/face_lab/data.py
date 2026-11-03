#!/usr/bin/env python3
"""Acquire a versioned public AXON sample into a private external inspection area."""
from __future__ import annotations
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat
import urllib.parse
import urllib.request
import zipfile

CAPABILITY=Path(__file__).resolve().parents[2]
REPO=CAPABILITY.parent if (CAPABILITY.parent/"sdks.json").is_file() else CAPABILITY
REF='axondata/selfie-and-official-id-photo-dataset-18k-images'
VERSION=6
MAX_ARCHIVE=512*1024*1024
MAX_EXPANDED=1024*1024*1024

def external_directory(path):
    path=Path(path).expanduser().resolve()
    if path==REPO or path.is_relative_to(REPO):raise ValueError('Biometric data and work products must stay outside the SDK repository')
    path.mkdir(parents=True,exist_ok=True,mode=0o700)
    path.chmod(0o700)
    return path

def fetch_json(url):
    with urllib.request.urlopen(url,timeout=45) as response:
        body=response.read(8*1024*1024+1)
        if len(body)>8*1024*1024:raise ValueError('Metadata response exceeds bound')
    return json.loads(body)

def inventory():
    view=fetch_json('https://www.kaggle.com/api/v1/datasets/view/'+REF)
    if view['currentVersionNumber']!=VERSION:raise ValueError('Dataset version changed; review the new inventory before acquisition')
    files=[];token=None;seen=set()
    for _ in range(100):
        query={'pageSize':200}
        if token:query['pageToken']=token
        page=fetch_json('https://www.kaggle.com/api/v1/datasets/list/'+REF+'?'+urllib.parse.urlencode(query))
        files.extend({'name':f['name'],'bytes':f['totalBytes']} for f in page['datasetFiles'])
        token=page.get('nextPageToken') or page.get('nextPageTokenNullable')
        if not token:break
        if token in seen:raise ValueError('Repeated metadata page token')
        seen.add(token)
    else:raise ValueError('Metadata pagination exceeded bound')
    if not files or len({f['name'] for f in files})!=len(files):raise ValueError('Empty or duplicate file inventory')
    return {'ref':REF,'version':VERSION,'license':view['licenseName'],'description':view['description'],'files':files}

def archive_entries(archive):
    entries=archive.infolist()
    if len(entries)>10000 or sum(i.file_size for i in entries)>MAX_EXPANDED:raise ValueError('Archive exceeds inspection bounds')
    names=set()
    for item in entries:
        path=PurePosixPath(item.filename)
        if path.is_absolute() or '..' in path.parts or '\\' in item.filename or '\x00' in item.filename:raise ValueError('Unsafe archive path')
        if stat.S_ISLNK(item.external_attr>>16):raise ValueError('Archive symlink rejected')
        if item.filename in names:raise ValueError('Duplicate archive entry')
        names.add(item.filename)
        if not item.is_dir():yield item

def inspect_archive(path,metadata,output):
    expected={f['name']:f['bytes'] for f in metadata['files']}
    rows=[];digests=[];folders=set();extensions=Counter()
    from PIL import Image
    import pillow_heif
    pillow_heif.register_heif_opener()
    with zipfile.ZipFile(path) as archive:
        entries=list(archive_entries(archive))
        if {i.filename:i.file_size for i in entries}!=expected:raise ValueError('Archive differs from versioned public file inventory')
        for item in entries:
            blob=archive.read(item);digest=hashlib.sha256(blob).hexdigest()
            row={'path':item.filename,'bytes':len(blob),'sha256':digest}
            extension=PurePosixPath(item.filename).suffix.lower();extensions[extension]+=1
            if extension in {'.jpg','.jpeg','.png'}:
                import io
                with Image.open(io.BytesIO(blob)) as image:
                    row.update({'width':image.width,'height':image.height,'format':image.format});image.verify()
                digests.append(digest);folders.add(str(PurePosixPath(item.filename).parent))
            rows.append(row)
    (output/'file-manifest.jsonl').write_text(''.join(json.dumps(row)+'\n' for row in rows))
    result={'ref':REF,'version':VERSION,'archiveSHA256':hashlib.sha256(path.read_bytes()).hexdigest(),'archiveBytes':path.stat().st_size,'fileCount':len(rows),'imageCount':len(digests),'distinctImageSHA256':len(set(digests)),'duplicateImageFiles':len(digests)-len(set(digests)),'imageFolderCount':len(folders),'extensions':dict(extensions),'status':'sample-development-staging','productionTrainingEligible':False,'commercialTrainingPermission':'not recorded','modelRedistributionPermission':'not recorded','subjectIdentityCount':'not established; folders are not verified identities','splitStatus':'not assigned; sample sets and duplicate identities must be reconciled first'}
    (output/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
    return result

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['inventory','acquire'])
    parser.add_argument('--workdir',required=True,type=Path)
    args=parser.parse_args();root=external_directory(args.workdir)
    destination=root/'data/quarantine/axon-selfie-id-v6';destination.mkdir(parents=True,exist_ok=True,mode=0o700)
    metadata=inventory()
    (destination/'source-metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
    if args.action=='inventory':
        print(json.dumps({'ref':REF,'version':VERSION,'fileCount':len(metadata['files']),'bytes':sum(f['bytes'] for f in metadata['files']),'license':metadata['license']},indent=2));return
    final=destination/'dataset.zip'
    if not final.exists():
        partial=destination/'dataset.zip.partial';total=0
        try:
            url='https://www.kaggle.com/api/v1/datasets/download/'+REF+'?datasetVersionNumber='+str(VERSION)
            with urllib.request.urlopen(url,timeout=60) as response,partial.open('xb') as output:
                while chunk:=response.read(1024*1024):
                    total+=len(chunk)
                    if total>MAX_ARCHIVE:raise ValueError('Download exceeded bound')
                    output.write(chunk)
            partial.rename(final)
        finally:
            if partial.exists():partial.unlink()
    print(json.dumps(inspect_archive(final,metadata,destination),indent=2))
if __name__=='__main__':main()
