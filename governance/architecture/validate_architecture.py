#!/usr/bin/env python3
"""Structural checks for APP-ARCH-001; no claim of implemented architecture conformance."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
from urllib.parse import unquote,urlsplit

ROOT=Path(__file__).resolve().parent

# Report output is a reviewed choice, never a user-selected filesystem destination.
REPORT_DESTINATIONS = {
    str(ROOT/'validation-results.json'): ROOT/'validation-results.json',
    str(ROOT.parents[1]/'.build/validation/architecture.json'): ROOT.parents[1]/'.build/validation/architecture.json',
}


def report_destination(value):
    try:
        path = REPORT_DESTINATIONS[str(Path(value).absolute())]
    except KeyError as error:
        raise argparse.ArgumentTypeError('Report must be the architecture validation-results.json or repository .build/validation/architecture.json') from error
    if any(item.is_symlink() for item in (path, *path.parents)):
        raise argparse.ArgumentTypeError('Report path cannot traverse symlinks')
    return path


def write_report(path, report):
    # Rebind the sink to a constant allowlisted path even for direct Python callers.
    try:
        destination = REPORT_DESTINATIONS[str(path)]
    except KeyError as error:
        raise ValueError('Unapproved architecture report destination') from error
    if any(item.is_symlink() for item in destination.parents):
        raise ValueError('Report path cannot traverse symlinks')
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        stream.write(json.dumps(report, indent=2)+'\n')


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--report',type=report_destination);args=parser.parse_args()
    path=ROOT/'APP-ARCH-001.md';source=path.read_text();checks={}
    checks['metadata']=all(x in source for x in ['**Document ID:** APP-ARCH-001','**Revision:** 0.2'])
    sections=re.findall(r'^## (\d+)\.',source,re.M)
    checks['sectionOrder']=sections==[str(i) for i in range(1,13)]
    ids=re.findall(r'^\*\*([A-Z0-9]+-\d+)\b',source,re.M)
    checks['uniqueRequirements']=len(ids)==len(set(ids))
    bands={'GOV':3,'MOD':5,'CON':3,'STORE':2,'KEY':1,'ATTEST':2,'BFF':5,'UI':7,'DS':8,'L10N':8,'A11Y':7,'QA':5,'CI':3,'EVID':3,'FACE':2,'NIST':4,'CHANGE':3}
    checks['requirementInventory']=set(ids)=={f'{prefix}-{i:02}' for prefix,count in bands.items() for i in range(1,count+1)}
    appendix_a=source.index('## Appendix A.');appendix_b=source.index('## Appendix B.')
    checks['appendixOrder']=appendix_a<appendix_b
    rows=re.findall(r'^\| (ARCH-A\d+) ',source,re.M)
    checks['implementationPlanInAppendix']=rows==[f'ARCH-A{i}' for i in range(1,9)] and all(appendix_a<match.start()<appendix_b for match in re.finditer(r'^\| ARCH-A\d+ ',source,re.M))
    missing=[]
    for _,target in re.findall(r'\[([^\]]+)\]\(([^)]+)\)',source):
        parsed=urlsplit(target)
        if not parsed.scheme and parsed.path and not (ROOT/unquote(parsed.path)).resolve().exists():missing.append(target)
    checks['localLinks']=not missing
    checks['relatedAuthorities']=all(x in source for x in ['../references/edge-verification/SPEC-IDBIO-200.md','../references/boundary-contract.md'])
    report={'document':'APP-ARCH-001','revision':'0.2','sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'requirements':len(ids),'checks':checks,'missingLocalLinks':missing,'scope':'Document structure only; domain review and implementation receipts are separate','passed':all(checks.values())}
    if args.report:write_report(args.report, report)
    print(json.dumps(report,indent=2));return not report['passed']
if __name__=='__main__':raise SystemExit(main())
