#!/usr/bin/env python3
"""Package the explicitly pinned public issuer bundle; never ask a passport holder to provision it."""
import argparse
import base64
import binascii
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
LOCAL_SOURCE = Path.home()/'Library/Application Support/Kenshiki/PassportTrust/csca.pem'
NAMES = ('PassportCSCA.pem', 'PassportTrust.json')


def validate(data, policy):
    if len(data) > policy['maxBytes'] or hashlib.sha256(data).hexdigest() != policy['sha256']:
        raise ValueError('Public passport trust bundle differs from reviewed policy')
    text = data.decode('ascii')
    blocks = re.findall(r'-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+?)\s*-----END CERTIFICATE-----', text)
    remainder = re.sub(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', '', text, flags=re.S)
    if remainder.strip() or len(blocks) != policy['certificateCount']:
        raise ValueError('Only the reviewed public certificate blocks may be packaged')
    for block in blocks:
        try:
            der = base64.b64decode(''.join(block.split()), validate=True)
        except (ValueError, binascii.Error) as error:
            raise ValueError('Malformed public certificate encoding') from error
        if not der or der[0] != 0x30:
            raise ValueError('Malformed public certificate envelope')


def provision(source, output, policy):
    output.mkdir(parents=True, exist_ok=True)
    # A clean compile without external trust must never reuse material from an earlier build.
    for name in NAMES:
        (output/name).unlink(missing_ok=True)
    if not source.is_file():
        return False
    with source.open('rb') as handle:
        data = handle.read(policy['maxBytes'] + 1)
    validate(data, policy)
    (output/NAMES[0]).write_bytes(data)
    (output/NAMES[1]).write_text(json.dumps(policy, sort_keys=True)+'\n')
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--source', type=Path, default=LOCAL_SOURCE)
    args = parser.parse_args()
    policy = json.loads((ROOT/'governance/passport-trust.json').read_text())
    try:
        copied = provision(args.source, args.output, policy)
    except (OSError, ValueError) as error:
        parser.exit(1, str(error)+'\n')
    print('Packaged reviewed public passport trust' if copied else 'Compile-only artifact: public passport trust not provisioned on this build host')


if __name__ == '__main__':
    main()
