#!/usr/bin/env python3
"""Build the pinned optional OFIQ Apple stack externally; never acquire model weights."""
import argparse
import hashlib
import json
import os
import plistlib
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import venv
import zipfile
import subprocess
import tarfile
import urllib.request

REPOSITORY = Path(__file__).resolve().parents[3]
CAPABILITY = REPOSITORY / 'biometric'
OFIQ_REVISION = 'df8fbb5e4bd8de09ae998ff69bc252f6be4367f8'
SOURCES = {
    'ofiq': ('BSI-OFIQ/OFIQ-Project', OFIQ_REVISION, '8568c32521bff82854502ff1f5caac3eb0562c9acf6db2e69701e484f9105128'),
    'opencv': ('opencv/opencv', 'dad26339a975b49cfb6c7dbe4bd5276c9dcb36e2', '41883710df7af812637bf40b9f20aaa472457eb0b6bacbccb46f5b7820cb3dbc'),
    'json': ('taocpp/json', '5a5fcdd47d70cf14cf940dc52948dad71abdfcd5', '0953ef6e35513861cc68b9de37c976d64b011f6ae6987787bbe7bb469dca2988'),
    'pegtl': ('taocpp/PEGTL', 'cf639f7f4ee125f68e1ccfba8d99ebc0de57b9fe', '411af4cb7c4d04e6ac3c7c2da7f6469ef146bf9aae7873f23167870aa8a5cfba'),
    'magic_enum': ('Neargye/magic_enum', '43a9272f450fd07e85868ed277ebd793e40806df', '37542817f4684359765b4e95655eccf7ec57c27d15294e060c8a0c8287d48642'),
}
RUNTIME_URL = 'https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.22.0.zip'
RUNTIME_SHA256 = '90d9de5a139087a6b05a18125d01d01d198820e1731e6f0f11b38749b2ab181f'
PLATFORMS = {'ios-device': ('iphoneos', 'arm64', '18.0'),
             'ios-simulator': ('iphonesimulator', 'arm64', '18.0'),
             'macos': ('macosx', 'arm64', '13.3')}
ARCHITECTURES = {'ios-device': ('arm64',),
                 'ios-simulator': ('arm64', 'x86_64'),
                 'macos': ('arm64', 'x86_64')}


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024*1024), b''):
            value.update(chunk)
    return value.hexdigest()


def run(command, log=None):
    if log:
        log.parent.mkdir(parents=True, exist_ok=True)
        with log.open('w') as output:
            subprocess.run([str(value) for value in command], check=True, stdout=output, stderr=subprocess.STDOUT)
    else:
        subprocess.run([str(value) for value in command], check=True)


def file_inventory(directory):
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError('Missing or symlinked input directory')
    files = {}
    for path in sorted(directory.rglob('*')):
        if path.is_symlink():
            raise ValueError('Symlinked source/artifact input')
        if path.is_file():
            files[str(path.relative_to(directory))] = digest(path)
    return files


def archive_members(archive):
    """Reject traversal/links/duplicate entries before extracting any source file."""
    with tarfile.open(archive) as source:
        members = source.getmembers()
        roots = {PurePosixPath(member.name).parts[0] for member in members if member.name}
        if len(roots) != 1:
            raise ValueError('Source archive must have one root')
        files = {}
        for member in members:
            path = PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or member.issym() or member.islnk():
                raise ValueError('Unsafe supplier archive entry')
            if member.isfile():
                name = str(PurePosixPath(*path.parts[1:]))
                if not name or name in files:
                    raise ValueError('Duplicate supplier archive entry')
                handle = source.extractfile(member)
                if handle is None:
                    raise ValueError('Unreadable supplier archive entry')
                files[name] = hashlib.sha256(handle.read()).hexdigest()
        return files


def verify_archive_tree(archive, destination):
    if archive_members(archive) != file_inventory(destination):
        raise ValueError('Extracted supplier source differs from verified archive')


def extract_archive(archive, destination):
    expected = archive_members(archive)
    destination.mkdir(parents=True, exist_ok=False)
    with tarfile.open(archive) as source:
        for member in source.getmembers():
            if not member.isfile():
                continue
            name = str(PurePosixPath(*PurePosixPath(member.name).parts[1:]))
            if name not in expected:
                raise ValueError('Unreviewed archive member')
            target = destination/name
            target.parent.mkdir(parents=True, exist_ok=True)
            handle = source.extractfile(member)
            if handle is None:
                raise ValueError('Unreadable source member')
            with target.open('xb') as output:
                shutil.copyfileobj(handle, output)
            target.chmod(member.mode & 0o777)
    verify_archive_tree(archive, destination)


def download(url, destination, expected):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.is_file():
        pending = destination.with_suffix(destination.suffix+'.pending')
        urllib.request.urlretrieve(url, pending)
        if digest(pending) != expected:
            raise ValueError('Downloaded archive integrity')
        pending.rename(destination)
    if destination.is_symlink() or digest(destination) != expected:
        raise ValueError('Cached archive integrity')


def acquire(root):
    for name, (repository, revision, expected) in SOURCES.items():
        archive = root/'downloads'/f'{name}-{revision}.tar.gz'
        download(f'https://codeload.github.com/{repository}/tar.gz/{revision}', archive, expected)
        destination = root/'sources'/name
        if not destination.exists():
            extract_archive(archive, destination)
        verify_archive_tree(archive, destination)


def runtime_inventory(directory):
    """Keep the official versioned-framework links, never external link targets."""
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError('Missing or symlinked runtime root')
    base = directory.resolve()
    result = {}
    for path in sorted(directory.rglob('*')):
        name = str(path.relative_to(directory))
        if path.is_symlink():
            target = os.readlink(path)
            relative = PurePosixPath(target)
            if relative.is_absolute() or '..' in relative.parts:
                raise ValueError('Unsafe runtime framework link')
            resolved = path.resolve(strict=True)
            if base not in resolved.parents:
                raise ValueError('Runtime framework link escapes root')
            result[name] = {'symlink': target}
        elif path.is_file():
            result[name] = digest(path)
    return result


def acquire_runtime(root, supplied=None):
    archive = root/'downloads/onnxruntime-1.22.0.zip'
    download(RUNTIME_URL, archive, RUNTIME_SHA256)
    expected = {}
    with zipfile.ZipFile(archive) as source:
        for member in source.infolist():
            path = PurePosixPath(member.filename)
            if path.is_absolute() or '..' in path.parts or not path.parts:
                raise ValueError('Unsafe runtime archive entry')
            if member.is_dir():
                continue
            if member.filename in expected:
                raise ValueError('Duplicate runtime archive member')
            payload = source.read(member)
            mode = stat.S_IFMT(member.external_attr >> 16)
            if mode == stat.S_IFLNK:
                target = payload.decode('utf-8')
                relative = PurePosixPath(target)
                if relative.is_absolute() or '..' in relative.parts or not relative.parts:
                    raise ValueError('Unsafe runtime archive link')
                expected[member.filename] = {'symlink': target}
            elif mode in (0, stat.S_IFREG):
                expected[member.filename] = hashlib.sha256(payload).hexdigest()
            else:
                raise ValueError('Unsupported runtime archive member')
        links = {name for name, value in expected.items() if isinstance(value, dict)}
        if any(str(parent) in links for name in expected for parent in PurePosixPath(name).parents):
            raise ValueError('Runtime archive writes through a link')
        destination = root/'runtime-verified'
        if not destination.exists():
            destination.mkdir()
            for name, value in expected.items():
                target = destination/name
                target.parent.mkdir(parents=True, exist_ok=True)
                if isinstance(value, dict):
                    target.symlink_to(value['symlink'])
                else:
                    with target.open('xb') as output:
                        output.write(source.read(name))
    if runtime_inventory(destination) != expected:
        raise ValueError('Runtime extracted tree differs from pinned archive')
    frameworks = [path for path in destination.rglob('onnxruntime.xcframework') if path.is_dir() and not path.is_symlink()]
    if len(frameworks) != 1:
        raise ValueError('Runtime archive framework ambiguity')
    verified = frameworks[0]
    if supplied is not None and runtime_inventory(supplied) != runtime_inventory(verified):
        raise ValueError('Supplied runtime/header tree differs from pinned archive')
    return supplied or verified


def prepare_ofiq(root, donor=None):
    pristine = root/'sources/ofiq'
    repository, revision, expected = SOURCES['ofiq']
    archive = root/'downloads'/f'ofiq-{revision}.tar.gz'
    if digest(archive) != expected:
        raise ValueError('OFIQ source archive integrity')
    verify_archive_tree(archive, pristine)
    if donor is not None:
        actual = subprocess.check_output(['git', '-C', str(donor), 'rev-parse', 'HEAD'], text=True).strip()
        if actual != OFIQ_REVISION or file_inventory(donor/'OFIQlib') != file_inventory(pristine/'OFIQlib'):
            raise ValueError('OFIQ donor differs from pinned archived runtime')
    # Recreate and verify patches independently, retaining exact cached source mtimes
    # so a packaging-only architecture addition can reuse qualified ARM objects.
    retained = root/'sources/ofiq-patched'
    destination = root/'sources/ofiq-patched-next'
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(pristine, destination)
    records = []
    for name in ['landmarks/src/adnet_landmarks.cpp', 'segmentations/src/ONNXRTSegmentation.cpp',
                 'poseEstimators/src/HeadPose3DDFAV2.cpp']:
        path = destination/'OFIQlib/modules'/name
        before = digest(path)
        source = path.read_text()
        sites = source.count('Ort::SessionOptions{nullptr}') + source.count('Ort::SessionOptions{ nullptr }')
        if sites != 1:
            raise ValueError('ORT options patch-site count: '+name)
        source = '#include "kenshiki_ofiq_options.h"\n' + source
        source = source.replace('Ort::SessionOptions{nullptr}', 'kenshiki_ofiq_options()')
        source = source.replace('Ort::SessionOptions{ nullptr }', 'kenshiki_ofiq_options()')
        if name != 'poseEstimators/src/HeadPose3DDFAV2.cpp' and (source.count('outputName.release();') != 1 or source.count('inputName.release();') != 1):
            raise ValueError('ORT allocation patch-site count: '+name)
        if 'outputName.release();' in source:
            source = source.replace('std::vector<const char*> outputNames;',
                'std::vector<const char*> outputNames;\n            std::vector<Ort::AllocatedStringPtr> outputNameOwners;')
            source = source.replace('outputName.release();', 'outputNameOwners.push_back(std::move(outputName));')
            source = source.replace('inputName.release();', '// inputName retains its allocation through Run.')
        path.write_text(source)
        records.append({'path': str(path.relative_to(destination)), 'originalSHA256': before,
                        'patchedSHA256': digest(path), 'reason': 'Sequential single-thread ORT; retain allocated input/output names through Run and free them afterward.'})
    path = destination/'OFIQlib/src/OFIQInitialization.cpp'
    before = digest(path)
    if path.read_text().count('networks.release();') != 1:
        raise ValueError('Network ownership patch-site count')
    path.write_text(path.read_text().replace('networks.release();', '// unique_ptr assignment releases a prior network owner.'))
    records.append({'path': str(path.relative_to(destination)), 'originalSHA256': before,
                    'patchedSHA256': digest(path), 'reason': 'Preserve unique_ptr ownership on any reinitialization; no leaked prior networks.'})
    (destination/'kenshiki_ofiq_options.h').write_text('''#pragma once
#include <onnxruntime_cxx_api.h>
static inline Ort::SessionOptions kenshiki_ofiq_options() {
    Ort::SessionOptions options;
    options.SetIntraOpNumThreads(1);
    options.SetInterOpNumThreads(1);
    options.SetExecutionMode(ORT_SEQUENTIAL);
    return options;
}
''')
    (root/'ofiq-patches.json').write_text(json.dumps(records, indent=2)+'\n')
    if retained.exists() and file_inventory(retained) == file_inventory(destination):
        shutil.rmtree(destination)
    else:
        if retained.exists(): shutil.rmtree(retained)
        destination.rename(retained)
    return retained


def opencv(root, platform, cmake, ninja, jobs, architecture=None):
    sdk, default_architecture, deployment = PLATFORMS[platform]
    architecture = architecture or default_architecture
    variant = platform if architecture == default_architecture else platform+'-'+architecture
    sdk_path = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
    build = root/'builds'/('opencv-'+variant)
    options = {'CMAKE_BUILD_TYPE': 'Release', 'CMAKE_MAKE_PROGRAM': ninja,
        'CMAKE_OSX_SYSROOT': sdk, 'CMAKE_OSX_ARCHITECTURES': architecture, 'CMAKE_OSX_DEPLOYMENT_TARGET': deployment,
        'CMAKE_TRY_COMPILE_TARGET_TYPE': 'STATIC_LIBRARY',
        'CMAKE_INSTALL_PREFIX': root/'install'/('opencv-'+variant),
        'BUILD_SHARED_LIBS': 'OFF', 'BUILD_LIST': 'core,calib3d,imgproc,dnn,ml,features2d,flann',
        'BUILD_opencv_world': 'OFF', 'BUILD_opencv_gapi': 'OFF', 'OPENCV_DOWNLOAD_PATH': root/'downloads/opencv-cache', 'BUILD_opencv_apps': 'OFF', 'BUILD_TESTS': 'OFF', 'BUILD_PERF_TESTS': 'OFF',
        'BUILD_EXAMPLES': 'OFF', 'BUILD_JAVA': 'OFF', 'BUILD_opencv_python2': 'OFF', 'BUILD_opencv_python3': 'OFF',
        'WITH_EIGEN': 'OFF', 'WITH_VTK': 'OFF', 'WITH_ITT': 'OFF', 'WITH_CAROTENE': 'OFF', 'WITH_IPP': 'OFF', 'WITH_OPENCL': 'OFF', 'WITH_LAPACK': 'OFF', 'WITH_AVFOUNDATION': 'OFF',
        'WITH_FFMPEG': 'OFF', 'WITH_GSTREAMER': 'OFF', 'WITH_QT': 'OFF', 'WITH_OPENEXR': 'OFF',
        'WITH_TIFF': 'OFF', 'WITH_WEBP': 'OFF', 'WITH_JASPER': 'OFF', 'WITH_OPENJPEG': 'OFF',
        'BUILD_ZLIB': 'OFF', 'ZLIB_INCLUDE_DIR': Path(sdk_path)/'usr/include',
        'ZLIB_LIBRARY': Path(sdk_path)/'usr/lib/libz.tbd', 'BUILD_PNG': 'OFF', 'BUILD_JPEG': 'OFF', 'WITH_PNG': 'OFF', 'WITH_JPEG': 'OFF',
        'OPENCV_ENABLE_NONFREE': 'OFF'}
    if platform != 'macos':
        options['CMAKE_SYSTEM_NAME'] = 'iOS'
    run([cmake, '-S', root/'sources/opencv', '-B', build, '-G', 'Ninja',
         *['-D'+key+'='+str(value) for key,value in options.items()]], root/'logs'/('opencv-'+variant+'-configure.log'))
    run([cmake, '--build', build, '--parallel', jobs], root/'logs'/('opencv-'+variant+'-build.log'))
    return build, sdk_path


def native(root, platform, patched, opencv_build, runtime, cmake, ninja, jobs, architecture=None):
    sdk, default_architecture, deployment = PLATFORMS[platform]
    architecture = architecture or default_architecture
    variant = platform if architecture == default_architecture else platform+'-'+architecture
    runtime_slice = {'ios-device':'ios-arm64', 'ios-simulator':'ios-arm64_x86_64-simulator', 'macos':'macos-arm64_x86_64'}[platform]
    headers = runtime/runtime_slice/'onnxruntime.framework/Headers'
    if not (headers/'onnxruntime_cxx_api.h').is_file():
        raise ValueError('Pinned SDK ONNX Runtime headers missing')
    project = root/'projects'/variant
    project.mkdir(parents=True, exist_ok=True)
    modules = patched/'OFIQlib/modules'
    source_files = sorted(str(path) for path in (patched/'OFIQlib').rglob('*.cpp') if path.name not in {'OFIQSampleApp.cpp', 'image_io.cpp'})
    includes = [patched, patched/'OFIQlib/include', headers, CAPABILITY/'cpp/quality/include',
                root/'sources/json/include',root/'sources/pegtl/include',root/'sources/magic_enum/include',root/'sources/opencv/include',opencv_build]
    includes += sorted({path.parent for path in modules.rglob('*.h')})
    includes += sorted((root/'sources/opencv/modules').glob('*/include'))
    quote = lambda path: '"'+str(path).replace('\\','/')+'"'
    (project/'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.26)
project(KenshikiOFIQNative LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
add_library(ofiq_native STATIC\n'''+ '\n'.join(quote(path) for path in source_files+[str(CAPABILITY/'cpp/quality/ofiq_bridge.cpp')])+')\n'+
        'target_include_directories(ofiq_native PRIVATE '+ ' '.join(quote(path) for path in includes)+')\n'+
        'target_compile_definitions(ofiq_native PRIVATE OFIQ_VERSION_MAJOR=1 OFIQ_VERSION_MINOR=0 OFIQ_VERSION_PATCH=3 OFIQ_VERSION_SUFFIX="" OFIQ_EXPORTS)\n'+
        'target_compile_options(ofiq_native PRIVATE -fno-fast-math -ffp-contract=off)\n')
    build = root/'builds'/('ofiq-'+variant)
    command = [cmake,'-S',project,'-B',build,'-G','Ninja','-DCMAKE_MAKE_PROGRAM='+str(ninja),
        '-DCMAKE_BUILD_TYPE=Release','-DCMAKE_OSX_SYSROOT='+sdk,'-DCMAKE_OSX_ARCHITECTURES='+architecture,
        '-DCMAKE_OSX_DEPLOYMENT_TARGET='+deployment,'-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY']
    if platform != 'macos': command += ['-DCMAKE_SYSTEM_NAME=iOS']
    run(command, root/'logs'/('ofiq-'+variant+'-configure.log'))
    run([cmake,'--build',build,'--parallel',jobs], root/'logs'/('ofiq-'+variant+'-build.log'))
    libraries = [opencv_build/'lib'/('libopencv_'+name+'.a') for name in ['core','calib3d','imgproc','dnn','ml','features2d','flann']]
    libraries += [opencv_build/'3rdparty/lib/liblibprotobuf.a']
    if not all(path.is_file() for path in libraries):
        raise ValueError('Missing required static OpenCV dependency')
    if len(libraries)<7:
        raise ValueError('Missing required static OpenCV component libraries')
    output = root/'libraries'/variant/'libOFIQNative.a'
    output.parent.mkdir(parents=True,exist_ok=True)
    run(['xcrun','libtool','-static','-o',output,build/'libofiq_native.a',*libraries], root/'logs'/('archive-'+variant+'.log'))
    return output


def archive_architectures(path):
    return subprocess.check_output(['xcrun', 'lipo', '-archs', str(path)], text=True).split()


def validate_cached_artifact(artifact, receipt, expected_platforms=None):
    try:
        required = list(PLATFORMS) if expected_platforms is None else list(expected_platforms)
        hashes = {'recipeSHA256': digest(Path(__file__)),
                  'bridgeSHA256': digest(CAPABILITY/'cpp/quality/ofiq_bridge.cpp'),
                  'headerSHA256': digest(CAPABILITY/'cpp/quality/include/ofiq_native.h'),
                  'profileSHA256': digest(Path(__file__).with_name('profile.json'))}
        info = plistlib.loads((artifact/'Info.plist').read_bytes())
        libraries = info.get('AvailableLibraries', [])
        expected = {('ios', '') if name == 'ios-device' else ('ios', 'simulator') if name == 'ios-simulator' else ('macos', ''): set(ARCHITECTURES[name]) for name in required}
        found = set()
        module = b'module OFIQNative { header "ofiq_native.h" export * link "c++" link "z" }\n'
        if len(libraries) != len(expected): return False
        for library in libraries:
            key = (library.get('SupportedPlatform'), library.get('SupportedPlatformVariant', ''))
            identifier = library.get('LibraryIdentifier', '')
            if (key not in expected or key in found or not isinstance(library.get('SupportedArchitectures'), list)
                or len(library['SupportedArchitectures']) != len(set(library['SupportedArchitectures']))
                or set(library['SupportedArchitectures']) != expected.get(key)
                or not identifier or '/' in identifier or identifier in {'.', '..'}
                or library.get('LibraryPath') != 'libOFIQNative.a' or library.get('HeadersPath') != 'Headers'):
                return False
            found.add(key)
            slice_root = artifact/identifier
            archive = slice_root/'libOFIQNative.a'
            with archive.open('rb') as handle:
                magic = handle.read(8)
            if len(expected[key]) == 1:
                if magic != b'!<arch>\n': return False
            elif magic[:4] not in (b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'):
                return False
            actual = archive_architectures(archive)
            if len(actual) != len(set(actual)) or set(actual) != expected[key]: return False
            if (digest(slice_root/'Headers/ofiq_native.h') != hashes['headerSHA256']
                or (slice_root/'Headers/module.modulemap').read_bytes() != module): return False
        return (found == set(expected) and set(receipt.get('platforms', [])) == set(required)
                and receipt.get('runtimeArchiveSHA256') == RUNTIME_SHA256
                and all(receipt.get(key) == value for key,value in hashes.items())
                and receipt.get('buildInputsAtStart') == hashes
                and receipt.get('buildInputsAtEnd') == hashes
                and receipt.get('members') == file_inventory(artifact))
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError, plistlib.InvalidFileException):
        return False


def tools(root, cmake=None, ninja=None):
    values = [cmake or shutil.which('cmake'), ninja or shutil.which('ninja')]
    if not all(values):
        environment = root/'tooling'
        if not (environment/'bin/python').exists():
            venv.EnvBuilder(with_pip=True).create(environment)
        run([environment/'bin/python','-m','pip','install','--disable-pip-version-check',
             'cmake==3.31.6','ninja==1.11.1.4'], root/'logs/tooling-install.log')
        values = [cmake or environment/'bin/cmake', ninja or environment/'bin/ninja']
    return values


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--external-root',type=Path,default=Path(os.environ.get('KENSHIKI_NATIVE_QUALITY_ROOT', Path.home()/'Library/Caches/Kenshiki/NativeQuality')))
    parser.add_argument('--ofiq-source',type=Path)
    parser.add_argument('--runtime-xcframework',type=Path)
    parser.add_argument('--cmake',type=Path)
    parser.add_argument('--ninja',type=Path)
    parser.add_argument('--platform',choices=PLATFORMS,action='append')
    parser.add_argument('--jobs',type=int,default=4)
    parser.add_argument('--ensure',action='store_true')
    parser.add_argument('--no-publish',action='store_true')
    args=parser.parse_args()
    if args.runtime_xcframework is not None: args.runtime_xcframework = args.runtime_xcframework.resolve()
    root=args.external_root.resolve()
    input_paths = {'recipeSHA256': Path(__file__),
        'bridgeSHA256': CAPABILITY/'cpp/quality/ofiq_bridge.cpp',
        'headerSHA256': CAPABILITY/'cpp/quality/include/ofiq_native.h',
        'profileSHA256': Path(__file__).with_name('profile.json')}
    start_inputs = {name: digest(path) for name,path in input_paths.items()}
    if root == REPOSITORY or REPOSITORY in root.parents or not 1<=args.jobs<=8:
        parser.error('Build roots must be external; jobs must be bounded')
    destination=CAPABILITY/'quality-apple/.build/native-quality/OFIQNative.xcframework'
    receipt_path=destination.parent/'build-receipt.json'
    if args.ensure and receipt_path.is_file():
        try: existing=json.loads(receipt_path.read_text())
        except (OSError,ValueError): existing={}
        if validate_cached_artifact(destination,existing):
            print('Verified complete OFIQ native artifact',flush=True); return
    root.mkdir(parents=True,exist_ok=True)
    acquire(root)
    args.runtime_xcframework=acquire_runtime(root,args.runtime_xcframework)
    args.cmake,args.ninja=tools(root,args.cmake,args.ninja)
    patched=prepare_ofiq(root,args.ofiq_source)
    start_sources = {name:file_inventory(root/'sources'/name) for name in SOURCES}
    start_patched = file_inventory(patched)
    start_runtime = runtime_inventory(args.runtime_xcframework)
    platforms=args.platform or list(PLATFORMS)
    libraries=[]
    for platform in platforms:
        thin = []
        for architecture in ARCHITECTURES[platform]:
            print('Building '+platform+' '+architecture,flush=True)
            build,_=opencv(root,platform,args.cmake,args.ninja,args.jobs,architecture)
            thin.append(native(root,platform,patched,build,args.runtime_xcframework,args.cmake,args.ninja,args.jobs,architecture))
        if len(thin) == 1:
            libraries.append(thin[0])
        else:
            universal = root/'universal'/platform/'libOFIQNative.a'
            universal.parent.mkdir(parents=True,exist_ok=True)
            run(['xcrun','lipo','-create',*thin,'-output',universal],root/'logs'/('lipo-'+platform+'.log'))
            if set(archive_architectures(universal)) != set(ARCHITECTURES[platform]):
                raise ValueError('Universal library architecture mismatch')
            libraries.append(universal)
    end_inputs = {name: digest(path) for name,path in input_paths.items()}
    if (end_inputs != start_inputs
        or {name:file_inventory(root/'sources'/name) for name in SOURCES} != start_sources
        or file_inventory(patched) != start_patched
        or runtime_inventory(args.runtime_xcframework) != start_runtime):
        raise ValueError('Native build inputs changed during compilation; refusing publication')
    include=root/'public-headers'
    include.mkdir(exist_ok=True)
    shutil.copyfile(CAPABILITY/'cpp/quality/include/ofiq_native.h',include/'ofiq_native.h')
    (include/'module.modulemap').write_text('module OFIQNative { header "ofiq_native.h" export * link "c++" link "z" }\n')
    artifact=root/'artifacts/OFIQNative.xcframework'
    if artifact.exists(): shutil.rmtree(artifact)
    artifact.parent.mkdir(parents=True,exist_ok=True)
    command=['xcodebuild','-create-xcframework']
    for library in libraries: command += ['-library',library,'-headers',include]
    run(command+['-output',artifact],root/'logs/xcframework.log')
    destination=CAPABILITY/'quality-apple/.build/native-quality/OFIQNative.xcframework'
    if not args.no_publish:
        if destination.exists(): shutil.rmtree(destination)
        destination.parent.mkdir(parents=True,exist_ok=True)
        shutil.copytree(artifact,destination)
    else:
        destination=artifact
    if {name: digest(path) for name,path in input_paths.items()} != start_inputs:
        raise ValueError('Native build inputs changed during packaging; refusing receipt')
    receipt={'buildInputsAtStart':start_inputs,'buildInputsAtEnd':end_inputs,
        'scope':'Pinned OFIQ native Apple assessment adapter; no weights/images/ORT binary embedded',
        'platforms':platforms,'architectures':{name:list(ARCHITECTURES[name]) for name in platforms},'ofiqSourceRevision':OFIQ_REVISION,'sources':SOURCES,
        'patches':json.loads((root/'ofiq-patches.json').read_text()),
        'profileSHA256':digest(Path(__file__).with_name('profile.json')),
        'headerSHA256':digest(CAPABILITY/'cpp/quality/include/ofiq_native.h'),
        'runtimeArchiveSHA256':RUNTIME_SHA256,
        'runtimeMembers':runtime_inventory(args.runtime_xcframework),
        'sourceTrees':{name:file_inventory(root/'sources'/name) for name in SOURCES},
        'patchedSourceTree':file_inventory(patched),
        'recipeSHA256':digest(Path(__file__)),'bridgeSHA256':digest(CAPABILITY/'cpp/quality/ofiq_bridge.cpp'),
        'toolchain':subprocess.check_output(['xcodebuild','-version'],text=True).strip(),
        'members':{str(path.relative_to(destination)):digest(path) for path in sorted(destination.rglob('*')) if path.is_file()}}
    (destination.parent/'build-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    (root/'build-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print('Built '+str(destination),flush=True)

if __name__=='__main__': main()
