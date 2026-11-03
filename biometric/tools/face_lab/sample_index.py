#!/usr/bin/env python3
"""Create private provisional subject/role indexes from an inspected sample archive."""
import argparse
from collections import Counter
import hashlib
import json
import re
from pathlib import Path, PurePosixPath
from data import external_directory

REFERENCE_NAMES={'passport','national_id','national id','id','idcard','id_card','driver_license','drivers_license','residence_permit'}

def provisional_records(rows):
    result=[]
    for row in rows:
        path=PurePosixPath(row['path'])
        if path.suffix.lower() not in {'.jpg','.jpeg','.png'}:continue
        # The folder is a provisional source label, not a validated person identity.
        group_path = str(PurePosixPath(*path.parts[:2])) if path.parts[0]=='Selfie & id data - public sample' else str(path.parent)
        group=hashlib.sha256(group_path.encode()).hexdigest()
        stem=re.sub(r'_\d+$','',path.stem.lower())
        category=path.parent.name.lower()
        role='unclassified'
        if stem in REFERENCE_NAMES or category=='docs':
            role='reference_candidate'
        elif any(x in stem+' '+category for x in ['selfie','phone','webcam','archive']):
            role='selfie_candidate'
        result.append({'archivePath':str(path),'imageSHA256':row['sha256'],'subjectGroup':group,'subjectLabelBasis':'source-folder-unverified','role':role,'width':row['width'],'height':row['height'],'use':'sample-experiment','productionEligible':False})
    return result

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--workdir',type=Path,required=True);args=parser.parse_args()
    root=external_directory(args.workdir);folder=root/'data/quarantine/axon-selfie-id-v6'
    rows=[json.loads(line) for line in (folder/'file-manifest.jsonl').read_text().splitlines()]
    records=provisional_records(rows)
    (folder/'sample-index.jsonl').write_text(''.join(json.dumps(row)+'\n' for row in records))
    grouped={}
    for row in records:grouped.setdefault(row['subjectGroup'],Counter())[row['role']]+=1
    duplicate_groups={}
    for row in records:duplicate_groups.setdefault(row['imageSHA256'],set()).add(row['subjectGroup'])
    summary={'crossGroupExactDuplicateClusters':sum(len(groups)>1 for groups in duplicate_groups.values()),'images':len(records),'provisionalFolderGroups':len(grouped),'roles':dict(Counter(r['role'] for r in records)),'groupsWithReferenceAndSelfieCandidates':sum(bool(g['reference_candidate'] and g['selfie_candidate']) for g in grouped.values()),'labelsVerified':False,'splitsAssigned':False}
    (folder/'sample-index-summary.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary,indent=2))
if __name__=='__main__':main()
