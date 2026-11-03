#!/usr/bin/env python3
"""Compile the independent optical document sample against its current public products."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('lane', choices=['ios-device', 'ios-simulator'])
    args = parser.parse_args()
    example = ROOT/'examples/ios'
    inventory = json.loads((ROOT/'Gates/example-sources.json').read_text())
    before = {}
    for name, digest in inventory['files'].items():
        path = ROOT/name
        if path.is_symlink() or not path.is_file():
            raise ValueError('Example input is unavailable')
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != digest:
            raise ValueError('Example input differs from its reviewed source inventory')
        before[name] = actual
    subprocess.run(['python3',str(ROOT/'scripts/provision_native.py')],check=True)
    subprocess.run(['xcodegen','generate','--spec',str(example/'project.yml')],cwd=ROOT.parent,check=True)
    base = ROOT/'.build/example';base.mkdir(parents=True,exist_ok=True)
    build = Path(tempfile.mkdtemp(prefix=args.lane+'-',dir=base))
    destination = 'generic/platform=iOS Simulator' if args.lane == 'ios-simulator' else 'generic/platform=iOS'
    command = ['xcodebuild','-project',str(example/'DocumentCaptureExample.xcodeproj'),'-scheme','DocumentCaptureExample',
               '-destination',destination,'-derivedDataPath',str(build/'DerivedData'),'CODE_SIGNING_ALLOWED=NO','build']
    with (build/'build.log').open('w') as log:
        completed = subprocess.run(command,cwd=ROOT.parent,stdout=log,stderr=subprocess.STDOUT)
    after = {name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in before}
    configuration = 'Debug-iphonesimulator' if args.lane == 'ios-simulator' else 'Debug-iphoneos'
    binary = build/'DerivedData/Build/Products'/configuration/'DocumentCaptureExample.app/DocumentCaptureExample'
    receipt = {'command':command,'exitCode':completed.returncode,'sourceSHA256':before,'endSourceSHA256':after,
               'installed':False,'physicalAccepted':False,'scope':'Public optical sample compilation only',
               'passed':completed.returncode == 0 and before == after and binary.is_file()}
    if binary.is_file():receipt['binarySHA256']=hashlib.sha256(binary.read_bytes()).hexdigest()
    (build/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    if not receipt['passed']:
        print((build/'build.log').read_text()[-10000:])
        raise SystemExit(completed.returncode or 1)
    print('Built public document example '+args.lane+': '+str(build/'receipt.json'))


if __name__ == '__main__':
    main()
