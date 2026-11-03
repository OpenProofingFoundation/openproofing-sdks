#!/usr/bin/env python3
"""Build and exercise the optional CPU inference target with generated ONNX graphs."""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]


def load_tool(path, name):
    original_path = list(sys.path)
    try:
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        sys.path[:] = original_path


validated_options = load_tool(ROOT/'biometric/nist/check.py', 'kenshiki_nist_options').validated_options

PIN_PATH = ROOT/'biometric/Gates/onnxruntime-linux-x64.json'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def bounded_read(stream, limit):
    if type(limit) is not int or limit < 0:
        raise ValueError('Read ceiling must be a nonnegative integer')
    data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError('Runtime archive exceeds reviewed size ceiling')
    return data


def validate_member_paths(pin):
    for name in pin['files']:
        if '\\' in name or any(part in {'', '.', '..'} for part in name.split('/')):
            raise ValueError('Runtime member requires a safe relative path')


def read_runtime_member(archive, member, entry, duplicate):
    if duplicate or not member.isfile() or member.size != entry['bytes']:
        raise ValueError('Runtime member type, size or duplicate mismatch')
    stream = archive.extractfile(member)
    if stream is None:
        raise ValueError('Runtime member unavailable')
    with stream:
        body = bounded_read(stream, entry['bytes'])
    if len(body) != entry['bytes'] or digest(body) != entry['sha256']:
        raise ValueError('Runtime member integrity mismatch')
    return body


def runtime_members(data, pin):
    """Verify selected regular members before any write; never extract archive paths."""
    if digest(data) != pin['archiveSHA256']:
        raise ValueError('Runtime archive integrity mismatch')
    validate_member_paths(pin)
    selected = {}
    prefix = pin['archiveRoot']+'/'
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
        for member in archive:
            if member.name == pin['archiveRoot'] and member.isdir():
                continue
            if not member.name.startswith(prefix):
                raise ValueError('Runtime archive root mismatch')
            name = member.name[len(prefix):]
            if name in pin['files']:
                selected[name] = read_runtime_member(archive, member, pin['files'][name], name in selected)
    if set(selected) != set(pin['files']):
        raise ValueError('Runtime member inventory incomplete')
    return selected


def acquire_runtime(pin, archive_path):
    if archive_path is not None:
        with archive_path.open('rb') as stream:
            data = bounded_read(stream, pin['maximumArchiveBytes'])
    else:
        with urllib.request.urlopen(pin['url'], timeout=30) as stream:
            data = bounded_read(stream, pin['maximumArchiveBytes'])
    return runtime_members(data, pin)


def bind_mount(source, destination, readonly=False):
    value = 'type=bind,src='+str(source)+',dst='+str(destination)
    return ['--mount', value+',readonly' if readonly else value]


def container_prefix(container_image, output, work, model, receipt):
    if not container_image:
        return []
    prefix = ['docker', 'run', '--rm', '--user', f'{os.getuid()}:{os.getgid()}',
              '--platform', 'linux/amd64', '--network', 'none', '--read-only',
              '--tmpfs', '/tmp:rw,exec,nosuid,size=128m',
              *bind_mount(ROOT, ROOT, readonly=True), *bind_mount(output, output),
              '--workdir', str(work)]
    if model is not None:
        prefix += bind_mount(model, '/external-model.onnx', readonly=True)
    prefix += ['--', container_image]
    receipt['containerImageID'] = subprocess.check_output(
        ['docker', 'image', 'inspect', '--format', '{{.Id}}', '--', container_image], text=True).strip()
    receipt['executionScope'] = 'Linux amd64 emulation, development compatibility only'
    return prefix


def write_runtime(selected, work):
    runtime = work/'runtime'
    for name, body in selected.items():
        path = runtime/name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(body)
    # Avoid untrusted archive symlinks. Identical reviewed bytes satisfy the
    # SONAME and the linker's unversioned name in this private build tree.
    library = selected['lib/libonnxruntime.so.1.22.0']
    for name in ['libonnxruntime.so', 'libonnxruntime.so.1']:
        (runtime/'lib'/name).write_bytes(library)
    return runtime


def source_hashes():
    sources = {
        path.relative_to(ROOT).as_posix(): digest(path.read_bytes())
        for path in (ROOT/'biometric/cpp').rglob('*')
        if path.is_file() and not any(part in {'__pycache__', '.build', 'build'} for part in path.parts)}
    for path in (ROOT/'contracts').glob('auraface*.json'):
        sources[path.relative_to(ROOT).as_posix()] = digest(path.read_bytes())
    return sources


def verify_sources(sources):
    for name, expected in sources.items():
        if digest((ROOT/name).read_bytes()) != expected:
            raise RuntimeError('Inference source changed during qualification')


def build_and_test(run, runtime, work, receipt, model, container_image):
    fixtures = work/'fixtures'
    generator = load_tool(ROOT/'biometric/cpp/tests/generate_auraface_fixtures.py', 'kenshiki_inference_fixtures')
    receipt['syntheticFixtureCount'] = generator.generate(fixtures)
    receipt['alignedVectorCount'] = generator.generate_vectors(ROOT, work/'auraface_vectors.inc')
    receipt['sourceSHA256'] = source_hashes()
    flags = ['-std=c++20', '-Wall', '-Wextra', '-Werror', '-Wpedantic', '-pthread',
             '-ffp-contract=off', '-fno-fast-math', '-fsanitize=address,undefined',
             '-fno-sanitize-recover=all', '-fno-omit-frame-pointer', '-g',
             '-I'+str(ROOT/'biometric/cpp/include'), '-I'+str(ROOT/'biometric/cpp/src'), '-I'+str(work),
             '-isystem', str(runtime/'include')]
    common = [str(ROOT/'biometric/cpp/src'/name) for name in ['portrait.cpp', 'auraface_input.cpp', 'auraface.cpp']]
    binary = work/'inference_tests'
    run(['g++-13', *flags, *common, str(ROOT/'biometric/cpp/tests/auraface_runtime_tests.cpp'),
         '-L'+str(runtime/'lib'), '-Wl,-rpath,'+str(runtime/'lib'), '-lonnxruntime', '-lcrypto', '-o', str(binary)])
    command = [str(binary), str(fixtures)]
    if model is not None:
        command.append('/external-model.onnx' if container_image else str(model))
    receipt['testOutput'] = run(command)
    cmake = work/'cmake'
    run(['cmake', '-G', 'Ninja', '-DCMAKE_CXX_COMPILER=g++-13', '-S', str(ROOT/'biometric/cpp'), '-B', str(cmake),
         '-DKENSHIKI_AURAFACE=ON', '-DONNXRUNTIME_ROOT='+str(runtime)])
    run(['cmake', '--build', str(cmake), '--target', 'kenshiki_auraface', '--parallel', '2'])
    receipt['sanitizers'] = ['address', 'undefined']
    receipt['cmakeOptionalTargetBuilt'] = True


def check(output, container_image=None, archive_path=None, model=None):
    _, output, container_image = validated_options('g++-13', output, container_image)
    if model is not None:
        model = model.resolve(strict=True)
        if not model.is_file() or model.is_relative_to(ROOT):
            raise ValueError('Model must be an external workbench file')
    if not container_image and (platform.system() != 'Linux' or platform.machine() != 'x86_64'):
        raise ValueError('Use the reviewed Linux amd64 container on this host')
    output.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='inference-', dir=output)).resolve()
    pin = json.loads(PIN_PATH.read_text())
    receipt = {'scope': 'Optional C++ CPU inference, synthetic ONNX adversarial tests; no FRTE recognition evaluation',
               'startedUTC': datetime.now(timezone.utc).isoformat(), 'commands': [], 'passed': False,
               'runtimePinSHA256': digest(PIN_PATH.read_bytes()), 'modelSupplied': model is not None,
               'officialFRTERecognitionEvaluation': False}
    prefix = []
    try:
        selected = acquire_runtime(pin, archive_path)
        runtime = write_runtime(selected, work)
        receipt['runtimeArchiveSHA256'] = pin['archiveSHA256']
        receipt['runtimeVersion'] = pin['version']
        prefix = container_prefix(container_image, output, work, model, receipt)

        def run(command):
            argv = prefix+command
            result = subprocess.run(argv, cwd=work, capture_output=True, text=True, timeout=300)
            log = output/(str(len(receipt['commands'])+1)+'.log')
            log.write_text(result.stdout+result.stderr)
            receipt['commands'].append({'argv': argv, 'exitCode': result.returncode,
                                        'log': log.name, 'logSHA256': digest(log.read_bytes())})
            if result.returncode != 0:
                raise RuntimeError('Inference command failed; see '+str(log))
            return result.stdout

        build_and_test(run, runtime, work, receipt, model, container_image)
        verify_sources(receipt['sourceSHA256'])
        receipt['passed'] = True
    finally:
        receipt['finishedUTC'] = datetime.now(timezone.utc).isoformat()
        (output/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-root', type=Path, default=ROOT/'.build/inference')
    parser.add_argument('--container-image', choices=['kenshiki-face-frte-dev:20261016'])
    parser.add_argument('--runtime-archive', type=Path, help='Optional local archive; exact reviewed digest still required')
    parser.add_argument('--model', type=Path, help='Optional external pinned AuraFace weights; never downloaded by this runner')
    args = parser.parse_args()
    check(args.build_root, args.container_image, args.runtime_archive, args.model)
