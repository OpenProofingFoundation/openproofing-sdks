#!/usr/bin/env python3
"""Provision only the pinned external AuraFace weights into the reference build."""
import argparse
import hashlib
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]

REVISION = 'af6d057c9b0ec4071d4c49c80e3539258798b609'
DIGEST = 'a7933ea5330113b01c9b60351d8f4c33003f145d8470ac5f0e52ee2effe25c60'
MODEL_BYTES = 260694151
DEFAULT_SOURCE = Path.home()/'Developer/kenshiki-face-workbench/models/auraface-v1'/REVISION/'glintr100.onnx'


def file_digest(handle):
    digest = hashlib.sha256()
    for chunk in iter(lambda: handle.read(1024 * 1024), b''):
        digest.update(chunk)
    return digest.hexdigest()


def provision(source, output):
    output.mkdir(parents=True, exist_ok=True)
    destination = output/'AuraFace.onnx'
    destination.unlink(missing_ok=True)
    if output.resolve().is_relative_to(ROOT.resolve()):
        return False
    if not source.is_file():
        return False
    if source.stat().st_size != MODEL_BYTES:
        raise ValueError('AuraFace model size mismatch')
    with source.open('rb') as handle:
        if file_digest(handle) != DIGEST:
            raise ValueError('AuraFace model digest mismatch')
    shutil.copyfile(source, destination)
    with destination.open('rb') as handle:
        if file_digest(handle) != DIGEST:
            destination.unlink(missing_ok=True)
            raise ValueError('AuraFace packaged model changed')
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=DEFAULT_SOURCE)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        copied = provision(args.source, args.output)
    except (OSError, ValueError) as error:
        parser.exit(1, str(error)+'\n')
    print('Packaged pinned AuraFace weights' if copied else 'Compile-only artifact: AuraFace weights absent')


if __name__ == '__main__':
    main()
