"""Verify the recorded reader runtime and, explicitly, its actual Pulse dependency."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
READER = 'passport/third-party/NFCPassportReader'
PEER = 'ThirdParty/NFCPassportReader'
MANIFEST = 'passport/Gates/reader-parity.json'


def runtime(folder):
    if folder.is_symlink() or not folder.is_dir():
        raise ValueError('Reader runtime root unavailable')
    if (folder/'Sources').is_symlink() or not (folder/'Sources').is_dir():
        raise ValueError('Reader source root unavailable')
    paths = [folder/'Package.swift']
    for path in (folder/'Sources').rglob('*'):
        if path.is_symlink():
            raise ValueError('Reader runtime symlink')
        if path.is_file():
            paths.append(path)
    if len(paths) < 2 or any(path.is_symlink() or not path.is_file() for path in paths):
        raise ValueError('Reader runtime missing')
    return {path.relative_to(folder).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(paths)}


def validate(root=ROOT, identity_sdk=None):
    manifest = json.loads((root/MANIFEST).read_text())
    if (set(manifest) != {'schemaVersion', 'scope', 'runtimeSHA256'}
            or type(manifest['schemaVersion']) is not int or manifest['schemaVersion'] != 1
            or manifest['scope'] != 'NFCPassportReader runtime and package; historical import hashes remain unchanged'
            or not isinstance(manifest['runtimeSHA256'], dict) or not manifest['runtimeSHA256']):
        raise ValueError('Invalid reader parity policy')
    recorded = manifest['runtimeSHA256']
    if runtime(root/READER) != recorded:
        raise ValueError('Reader runtime differs from reviewed parity record')
    if identity_sdk is not None and runtime(identity_sdk/PEER) != recorded:
        raise ValueError('Actual Pulse dependency differs from reviewed reader runtime')
    return recorded


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--identity-sdk', type=Path,
                        help='Require byte parity with this actual Pulse dependency checkout')
    args = parser.parse_args()
    recorded = validate(identity_sdk=args.identity_sdk)
    print('PASS reader runtime: '+str(len(recorded))+' reviewed files'
          + ('; actual Pulse dependency byte-identical' if args.identity_sdk is not None else '; peer not examined'))


if __name__ == '__main__':
    main()
