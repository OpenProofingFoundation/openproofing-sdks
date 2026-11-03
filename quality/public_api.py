#!/usr/bin/env python3
"""Compare compiler-derived public surfaces with reviewable snapshots."""
import argparse
import json
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile
import zipfile

def swift_surface(root,config,lane, module=None, module_folder=None, import_arguments=()):
    module = module or config['swiftModule']
    build_root = root/'quality-apple' if module == 'BiometricQuality' else root
    if lane=='macos':
        folder = module_folder
        if folder is None:
            folder = Path(subprocess.check_output(['swift','build','--show-bin-path'],cwd=build_root,text=True).strip())/'Modules'
        sdk='macosx'; minimum = '13.3' if config['swiftModule'] == 'BiometricSDK' else '13.0'
        target=platform.machine()+'-apple-macosx'+minimum
    else:
        device=lane=='ios-device';sdk='iphoneos' if device else 'iphonesimulator'
        folder=build_root/'.build'/lane/'Build/Products'/('Debug-'+sdk)
        target='arm64-apple-ios18.0'+('' if device else '-simulator')
    if module_folder is not None:
        folder = module_folder
    sdkpath=subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'],text=True).strip()
    native_headers = native_import_arguments(root, module, lane)

    if config['swiftModule']=='DocumentSDK':
        identifier = 'macos-arm64_x86_64' if lane=='macos' else 'ios-arm64' if lane=='ios-device' else 'ios-arm64_x86_64-simulator'
        native_headers += ['-F',str(root/'.build/native/DocumentOpenCVBridge.xcframework'/identifier)]
        if lane=='macos':
            native_headers += ['-I',str(folder.parent/'KenshikiSQLCipherBridge.build'),'-F',str(root/'.build/artifacts/sqlcipher.swift/SQLCipher/SQLCipher.xcframework'/identifier)]
        else:
            map_path=root/'.build'/lane/'Build/Intermediates.noindex'/('GeneratedModuleMaps-'+sdk)/'KenshikiSQLCipherBridge.modulemap'
            native_headers += ['-F',str(folder),'-Xcc','-fmodule-map-file='+str(map_path)]
    with tempfile.TemporaryDirectory(prefix='capability-public-api-') as temp:
        subprocess.run(['xcrun','swift-symbolgraph-extract','-module-name',module,'-I',str(folder),*native_headers,*import_arguments,'-target',target,'-sdk',sdkpath,'-minimum-access-level','public','-skip-synthesized-members','-output-dir',temp],check=True,cwd=root)
        graph=json.loads((Path(temp)/(module+'.symbols.json')).read_text())
    symbols=sorted([{'id':s['identifier']['precise'],'kind':s['kind']['identifier'],'declaration':''.join(f['spelling'] for f in s['declarationFragments'])} for s in graph['symbols']],key=lambda x:x['id'])
    relationships=sorted([{'kind':r['kind'],'source':r['source'],'target':r['target']} for r in graph['relationships'] if r['kind'] in {'conformsTo','inheritsFrom'}],key=lambda x:(x['source'],x['kind'],x['target']))
    if not symbols:raise ValueError('Empty public API is not a successful snapshot')
    return {'symbols':symbols,'relationships':relationships}

def native_import_arguments(root, module, lane):
    if module == 'BiometricInference':
        return ['-I', str(root/'cpp/include')]
    if module != 'BiometricQuality':
        return []
    artifact = root/'quality-apple/.build/native-quality/OFIQNative.xcframework'
    with (artifact/'Info.plist').open('rb') as stream:
        libraries = plistlib.load(stream)['AvailableLibraries']
    expected_platform = 'macos' if lane == 'macos' else 'ios'
    variant = 'simulator' if lane == 'ios-simulator' else None
    architecture = platform.machine() if lane == 'macos' else 'arm64'
    matches = [item for item in libraries if item.get('SupportedPlatform') == expected_platform
               and item.get('SupportedPlatformVariant') == variant
               and architecture in item.get('SupportedArchitectures', [])]
    if len(matches) != 1:
        raise ValueError('Exactly one matching OFIQ native header slice is required')
    library = matches[0]
    identifier = safe_artifact_path(library['LibraryIdentifier'])
    headers = safe_artifact_path(library['HeadersPath'])
    directory = artifact/identifier/headers
    if (not directory.is_dir() or not directory.resolve().is_relative_to(artifact.resolve())
            or not (directory/'module.modulemap').is_file()):
        raise ValueError('OFIQ native header module is missing')
    return ['-I', str(directory)]


def safe_artifact_path(value):
    if not isinstance(value, str) or not value or Path(value).is_absolute():
        raise ValueError('Invalid native artifact path')
    if any(part in {'', '.', '..'} for part in value.split('/')):
        raise ValueError('Invalid native artifact path')
    return Path(value)


def jvm_surface(classpath,names):
    if not names:raise ValueError('Empty Android API is not a successful snapshot')
    text=subprocess.check_output(['javap','-public','-s','-classpath',str(classpath),*names],text=True)
    return [line.rstrip() for line in text.splitlines() if not line.startswith('Compiled from') and line.strip()]

def android_surface(root,config):
    module=config['androidModule'];aar=root/'android'/module/'build/outputs/aar'/(module+'-debug.aar')
    with tempfile.TemporaryDirectory(prefix='capability-public-api-') as temp:
        jar=Path(temp)/'classes.jar'
        with zipfile.ZipFile(aar) as archive:jar.write_bytes(archive.read('classes.jar'))
        with zipfile.ZipFile(jar) as archive:names=sorted(n[:-6].replace('/','.') for n in archive.namelist() if n.endswith('.class'))
        return jvm_surface(jar,names)

def swift_modules(config, lane):
    modules = [config['swiftModule']]
    if config['swiftModule'] == 'DocumentSDK':
        modules += ['DocumentCaptureJournal', 'DocumentCapture']
        if lane in {'ios-device', 'ios-simulator'}:
            modules += ['DocumentCaptureApple', 'DocumentCapturePreview']
    if config['swiftModule'] == 'BiometricSDK':
        modules += ['BiometricCapture', 'BiometricInference', 'BiometricQuality', 'KenshikiMotion']
        if lane in {'ios-device', 'ios-simulator'}:
            modules.append('BiometricCapturePreview')
    if config['swiftModule'] == 'PassportSDK' and lane in {'ios-device', 'ios-simulator'}:
        modules += ['PassportNFC', 'PassportMRZCapture', 'PassportMRZPreview']
    return modules


def snapshot_path(root, lane, module, primary):
    return root/'api'/(lane+'.json') if module == primary else root/'api'/module/(lane+'.json')


def main(root):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('lane',choices=['macos','ios-device','ios-simulator','android'])
    parser.add_argument('--write',action='store_true',help='Explicitly regenerate snapshot; review API compatibility and versioning before release')
    args=parser.parse_args();config=json.loads((root/'Gates/config.json').read_text())
    modules = [config['swiftModule']] if args.lane == 'android' else swift_modules(config, args.lane)
    for module in modules:
        actual = android_surface(root, config) if args.lane == 'android' else swift_surface(root, config, args.lane, module)
        snapshot = snapshot_path(root, args.lane, module, config['swiftModule'])
        if args.write:
            snapshot.parent.mkdir(parents=True, exist_ok=True)
            snapshot.write_text(json.dumps(actual, indent=2, sort_keys=True)+'\n')
            print('WROTE '+str(snapshot))
        elif not snapshot.is_file() or json.loads(snapshot.read_text()) != actual:
            print('FAIL public API drift: '+module+' '+args.lane+'; review compatibility/versioning and explicitly regenerate the snapshot')
            return 1
        else:
            print('PASS compiler-derived public API: '+module+' '+args.lane)
    return 0
