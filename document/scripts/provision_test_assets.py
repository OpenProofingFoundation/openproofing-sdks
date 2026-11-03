#!/usr/bin/env python3
"""Provision a digest-pinned public-domain face-detection control outside source control."""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
NAME = 'vision-public-astronaut.png'
SHA256 = '88431cd9653ccd539741b555fb0a46b61558b301d4110412b5bc28b5e3ea6cb5'
URL = 'https://raw.githubusercontent.com/scikit-image/scikit-image/v0.25.2/skimage/data/astronaut.png'


def validate(data):
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise ValueError('Public Vision control digest mismatch')
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, help='Verify and use an existing pinned control image')
    args = parser.parse_args()
    manifest = json.loads((ROOT / 'Gates/test-assets.json').read_text())
    if manifest.get('schemaVersion') != 1 or manifest.get('assets', {}).get(NAME, {}).get('sha256') != SHA256:
        raise ValueError('Unreviewed Vision positive-control manifest')
    folder = ROOT / '.build/test-assets'
    if any(p.is_symlink() for p in [ROOT / '.build', folder]):
        raise ValueError('Test-asset directory must not be a symlink')
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / NAME
    if target.is_symlink():
        raise ValueError('Test-asset file must not be a symlink')
    if target.exists():
        validate(target.read_bytes())
    else:
        if args.source:
            if args.source.is_symlink():
                raise ValueError('Supplied test asset must not be a symlink')
            data = validate(args.source.read_bytes())
        else:
            with urllib.request.urlopen(URL, timeout=30) as response:
                data = validate(response.read(2 * 1024 * 1024))
        with tempfile.NamedTemporaryFile(dir=folder, prefix='.asset-', delete=False) as temporary:
            temporary.write(data)
            temporary.flush()
            staged = Path(temporary.name)
        try:
            staged.replace(target)
        finally:
            staged.unlink(missing_ok=True)
    print('Verified public Vision control: ' + SHA256)


if __name__ == '__main__':
    main()
