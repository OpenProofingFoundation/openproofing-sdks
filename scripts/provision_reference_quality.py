#!/usr/bin/env python3
"""Provision the exact external development OFIQ profile into a reference build."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
PROFILE = ROOT/'biometric/tools/native_quality/profile.json'
PROFILE_SHA256 = '154433c5e66cfb80f8bd1fdf91b92c4aa212c6eea3c9ea1624bbca3b4a8e4557'
LICENSES_SHA256 = '2e90df88b2c6619a8800b6143707ddc3fc8fc80a191624594fe7bf9d02f20624'
DEFAULT_SOURCE = Path.home()/'Developer/kenshiki-face-workbench/quality-ui/engine/profile'

def digest(path):
    value=hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):value.update(chunk)
    return value.hexdigest()

def validated_profile():
    if PROFILE.is_symlink() or digest(PROFILE)!=PROFILE_SHA256:
        raise ValueError('quality_profile_integrity')
    profile=json.loads(PROFILE.read_text())
    if profile.get('schemaVersion')!=1 or not isinstance(profile.get('files'),list):
        raise ValueError('quality_profile_schema')
    seen=set()
    for item in profile['files']:
        path=Path(item['path'])
        if path.is_absolute() or '..' in path.parts or str(path) in seen or not path.parts:
            raise ValueError('quality_profile_path')
        seen.add(str(path))
    return profile

def provision(source,output,require_assets=False):
    profile=validated_profile()
    destination=output/'FaceQuality'
    if output.resolve().is_relative_to(ROOT.resolve()):
        if destination.exists():shutil.rmtree(destination)
        if require_assets:raise ValueError('quality_assets_require_external_build_directory')
        return False
    if not source.is_dir():
        if destination.exists():shutil.rmtree(destination)
        if require_assets:raise ValueError('quality_assets_missing')
        return False
    # Verify the complete source before replacing this generated build resource.
    for item in profile['files']:
        path=source/item['path']
        if (not path.is_file() or path.is_symlink() or path.stat().st_size!=item['bytes']
                or digest(path)!=item['sha256']):raise ValueError('quality_asset_integrity: '+item['path'])
    if destination.exists():shutil.rmtree(destination)
    try:
        destination.mkdir(parents=True)
        for item in profile['files']:
            path=destination/item['path'];path.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(source/item['path'],path)
            if path.stat().st_size!=item['bytes'] or digest(path)!=item['sha256']:
                raise ValueError('quality_packaged_asset_changed: '+item['path'])
        shutil.copyfile(PROFILE,destination/'quality-profile.json')
        if digest(destination/'quality-profile.json')!=PROFILE_SHA256:
            raise ValueError('quality_packaged_profile_changed')
    except BaseException:
        shutil.rmtree(destination,ignore_errors=True)
        raise
    return True

def provision_notices(output):
    source=ROOT/'biometric/third-party/ofiq'
    manifest=source/'licenses.json'
    if manifest.is_symlink() or digest(manifest)!=LICENSES_SHA256:
        raise ValueError('quality_license_manifest_integrity')
    files=json.loads(manifest.read_text())['files']
    for name,expected in files.items():
        path=source/name
        if Path(name).name!=name or not path.is_file() or path.is_symlink() or digest(path)!=expected:
            raise ValueError('quality_license_integrity')
    destination=output/'NativeQualityNotices'
    if destination.exists():shutil.rmtree(destination)
    destination.mkdir(parents=True)
    for name,expected in files.items():
        path=destination/name;shutil.copyfile(source/name,path)
        if digest(path)!=expected:raise ValueError('quality_packaged_license_integrity')
    shutil.copyfile(manifest,destination/'licenses.json')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,default=DEFAULT_SOURCE)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--require-assets',action='store_true')
    args=parser.parse_args()
    try:
        copied=provision(args.source,args.output,args.require_assets)
        provision_notices(args.output)
    except (OSError,ValueError,KeyError) as error:parser.exit(1,str(error)+'\n')
    print('Packaged pinned OFIQ development assets' if copied else 'Compile-only artifact: OFIQ assets absent')

if __name__=='__main__':main()
