#!/usr/bin/env python3
"""Compile/link and exercise pinned official tooling with its own null reference only."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'Gates'))
from nist_integrity import verify, REVISION
sys.path.insert(0, str(ROOT/'cpp'))
from generate_vectors import generate, generate_math
sys.path.insert(0, str(ROOT/'cpp/tests'))
from generate_auraface_fixtures import generate_vectors as generate_aligned_vectors

CLANG_COMPILER = 'clang++'
CPP_STANDARD = '-std=c++20'
PORTRAIT_SOURCE = ROOT/'cpp/src/portrait.cpp'
CPP_INCLUDE = ROOT/'cpp/include'
COMPILERS = {CLANG_COMPILER: CLANG_COMPILER, 'g++-13': 'g++-13'}
CONTAINER_IMAGES = {'kenshiki-face-frte-dev:20261016': 'kenshiki-face-frte-dev:20261016'}


def validated_options(compiler, output, container_image):
    try:
        compiler = COMPILERS[compiler]
        image = CONTAINER_IMAGES[container_image] if container_image is not None else None
    except (KeyError, TypeError) as error:
        raise ValueError('Unsupported NIST compiler or container image') from error
    output = Path(output).absolute()
    allowed = ROOT.parent/'.build'
    if not output.is_relative_to(allowed) or output == allowed:
        raise ValueError('NIST build root must be below the repository .build directory')
    if any(not re.fullmatch(r'[A-Za-z0-9_.-]+', part) for part in output.relative_to(allowed).parts):
        raise ValueError('NIST build root requires plain directory names without mount separators')
    for path in (output, *output.parents):
        if path.is_symlink():
            raise ValueError('NIST build root cannot traverse symlinks')
    if not output.resolve().is_relative_to(allowed):
        raise ValueError('NIST build root escapes repository .build directory')
    return compiler, output.resolve(), image



def create_synthetic_templates(run, driver, work, role, rgb, gray):
    listing = work/(role+'.txt')
    listing.write_text(f'{role}-rgb {rgb} facemugshot\n{role}-multi {gray} facemugshot {rgb} facemugshot\n')
    run([str(driver), 'createTemplate', '-x', role, '-c', str(work/'config'),
         '-o', str(work/'output'), '-h', role, '-i', str(listing), '-t', '2', '-j', str(work/'templates')])
    rows = []
    logs = list((work/'output').glob(role+'.log.*'))
    if len(logs) != 2:
        raise ValueError('Expected output from both forked driver children')
    for log in logs:
        rows.extend(line.split() for line in log.read_text().splitlines()[1:])
    if len(rows) != 3 or any(row[2:4] != ['16', '0'] for row in rows):
        raise ValueError('Unexpected null-reference template I/O')
    for item in ['rgb', 'multi']:
        if (work/'templates'/(role+'-'+item+'.template')).stat().st_size != 16:
            raise ValueError('Missing upstream null template')

def exercise_synthetic_io(run, driver, work):
    for name in ['config', 'templates', 'output']:
        (work/name).mkdir()
    rgb = work/'synthetic.ppm'; gray = work/'synthetic.pgm'
    rgb.write_bytes(b'P6\n4 4\n255\n'+bytes(range(48)))
    gray.write_bytes(b'P5\n4 4\n255\n'+bytes(range(16)))
    for role in ['enroll', 'verif']:
        create_synthetic_templates(run, driver, work, role, rgb, gray)
    pairs = work/'pairs.txt'
    pairs.write_text('enroll-rgb.template verif-rgb.template\nenroll-multi.template verif-multi.template\n')
    run([str(driver), 'match', '-c', str(work/'config'), '-o', str(work/'output'), '-h', 'match',
         '-i', str(pairs), '-t', '2', '-j', str(work/'templates')])
    rows = []
    for log in (work/'output').glob('match.log.*'):
        rows.extend(line.split() for line in log.read_text().splitlines()[1:])
    if len(rows) != 2 or any(row[3] != '0' or not math.isfinite(float(row[2])) for row in rows):
        raise ValueError('Unexpected upstream null match I/O')


def check(compiler, output, container_image=None):
    compiler, output, container_image = validated_options(compiler, output, container_image)
    output.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='mechanics-', dir=output)).resolve()
    receipt = {'scope': 'Official tooling build/link/forked synthetic I/O mechanics using UPSTREAM NULL reference only; no recognition or official validation claim',
               'upstreamRevision': REVISION, 'host': {'system': platform.system(), 'machine': platform.machine()},
               'startedUTC': datetime.now(timezone.utc).isoformat(), 'commands': [], 'passed': False,
               'algorithmAdapterImplemented': False, 'officialValidationExecuted': False}

    prefix = []
    if container_image:
        prefix = ['docker', 'run', '--rm', '--user', f'{os.getuid()}:{os.getgid()}', '--platform', 'linux/amd64', '--network', 'none',
                  '--read-only', '--tmpfs', '/tmp:rw,exec,nosuid,size=64m',
                  '--mount', 'type=bind,src='+str(ROOT)+',dst='+str(ROOT)+',readonly',
                  '--mount', 'type=bind,src='+str(output)+',dst='+str(output),
                  '--workdir', str(work), '--', container_image]
        receipt['containerImageID'] = subprocess.check_output(
            ['docker', 'image', 'inspect', '--format', '{{.Id}}', '--', container_image], text=True).strip()
        receipt['executionScope'] = 'Linux amd64 compatibility under emulation; not NIST qualification OS or timing'

    # Test includes are derived from the checked-in shared inventory on every
    # invocation, never a hand-maintained C++ copy or a frozen fixture count.
    receipt['portablePortraitVectorCount'] = generate(ROOT.parent, work/'portrait_vectors.inc')
    receipt['portableMathVectorCount'] = generate_math(ROOT.parent, work/'math_vectors.inc')
    receipt['alignedInputVectorCount'] = generate_aligned_vectors(ROOT.parent, work/'auraface_vectors.inc')
    receipt['portableSourceSHA256'] = {
        str(path.relative_to(ROOT.parent)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in [ROOT/'cpp/include/kenshiki/portrait.hpp', PORTRAIT_SOURCE,
                     ROOT/'cpp/tests/contract_tests.cpp', ROOT/'cpp/generate_vectors.py',
                     ROOT/'cpp/include/kenshiki/auraface_input.hpp', ROOT/'cpp/src/auraface_input.cpp',
                     ROOT/'cpp/tests/auraface_input_tests.cpp', ROOT/'cpp/tests/generate_auraface_fixtures.py',
                     ROOT/'cpp/include/kenshiki/face_alignment.hpp', ROOT/'cpp/src/face_alignment.cpp',
                     ROOT/'cpp/tests/face_alignment_tests.cpp',
                     ROOT/'cpp/include/kenshiki/frame_selection.h', ROOT/'cpp/src/frame_selection.cpp',
                     ROOT/'cpp/tests/frame_selection_tests.cpp',
                     ROOT.parent/'contracts/portrait-selfie-v1.vectors.json',
                     ROOT.parent/'contracts/embedding-math-v1.vectors.json',
                     ROOT.parent/'contracts/auraface-aligned-input-v1.json',
                     ROOT.parent/'contracts/auraface-aligned-input-v1.vectors.json',
                     ROOT.parent/'contracts/auraface-baseline-output-v1.json']}

    def run(command, expected=0):
        command = prefix+command
        result = subprocess.run(command, cwd=work, capture_output=True, text=True, timeout=180)
        label = str(len(receipt['commands'])+1)
        log = output/(label+'.log')
        log.write_text(result.stdout+result.stderr)
        receipt['commands'].append({'argv': command, 'exitCode': result.returncode,
                                    'log': log.name, 'logSHA256': hashlib.sha256(log.read_bytes()).hexdigest()})
        if result.returncode != expected:
            raise RuntimeError('Command failed: '+str(command)+'\n'+result.stdout+result.stderr)
        return result.stdout

    try:
        inventory, failures = verify(ROOT)
        if failures:
            raise ValueError('; '.join(failures))
        receipt['verifiedSourceFiles'] = len(inventory)
        receipt['compiler'] = run([compiler, '--version']).splitlines()[0]
        receipt['runtimeArchitecture'] = run(['uname', '-m']).strip()
        portable = work/'portable_contract_tests'
        portable_flags = [CPP_STANDARD, '-Wall', '-Wextra', '-Werror', '-Wpedantic',
                          '-fno-fast-math', '-ffp-contract=off',
                          '-fsanitize=address,undefined', '-fno-sanitize-recover=all', '-fno-omit-frame-pointer', '-g', '-pthread']
        crypto_flags = [] if platform.system() == 'Darwin' and not container_image else ['-lcrypto']
        run([compiler, *portable_flags, '-I'+str(CPP_INCLUDE), '-I'+str(work),
             str(PORTRAIT_SOURCE), str(ROOT/'cpp/tests/contract_tests.cpp'),
             *crypto_flags, '-o', str(portable)])
        run([str(portable)])
        aligned = work/'aligned_input_tests'
        run([compiler, *portable_flags, '-I'+str(CPP_INCLUDE), '-I'+str(work),
             str(PORTRAIT_SOURCE), str(ROOT/'cpp/src/auraface_input.cpp'),
             str(ROOT/'cpp/tests/auraface_input_tests.cpp'), *crypto_flags, '-o', str(aligned)])
        receipt['alignedInputTests'] = {'passed': True, 'output': run([str(aligned)]),
                                        'binarySHA256': hashlib.sha256(aligned.read_bytes()).hexdigest()}
        alignment = work/'face_alignment_tests'
        run([compiler, *portable_flags, '-I'+str(CPP_INCLUDE),
             str(PORTRAIT_SOURCE), str(ROOT/'cpp/src/face_alignment.cpp'),
             str(ROOT/'cpp/tests/face_alignment_tests.cpp'), *crypto_flags, '-o', str(alignment)])
        receipt['faceAlignmentTests'] = {'passed': True, 'output': run([str(alignment)]),
                                         'binarySHA256': hashlib.sha256(alignment.read_bytes()).hexdigest()}
        selection = work/'frame_selection_tests'
        run([compiler, *portable_flags, '-I'+str(CPP_INCLUDE),
             str(ROOT/'cpp/src/frame_selection.cpp'), str(ROOT/'cpp/tests/frame_selection_tests.cpp'),
             '-o', str(selection)])
        receipt['frameSelectionTests'] = {'passed': True, 'output': run([str(selection)]),
                                         'sanitizers': ['address', 'undefined'],
                                         'binarySHA256': hashlib.sha256(selection.read_bytes()).hexdigest(),
                                         'scope': 'Deterministic source-bound quality and matcher-preparation selection; no recognition calibration'}
        receipt['portableContracts'] = {'passed': True, 'sanitizers': ['address', 'undefined'],
                                        'scope': 'Owned decoded pixels, binding fence and embedding math; no inference or template encoding',
                                        'binarySHA256': hashlib.sha256(portable.read_bytes()).hexdigest()}
        if container_image or platform.system() == 'Linux':
            receipt['runtimeOS'] = run(['cat', '/etc/os-release'])
        source = ROOT/'nist/upstream'
        includes = ['-I'+str(source/'11/src/include'), '-I'+str(source/'common/src/include')]
        library = work/'libfrvt_11_null_001.so'
        run([compiler, CPP_STANDARD, '-shared', '-fPIC', *includes,
             str(source/'11/src/nullImpl/nullimplfrvt11.cpp'), '-o', str(library)])
        driver = work/'validate11'
        run([compiler, CPP_STANDARD, '-DNIST_EXTERN_FRVT_STRUCTS_VERSION', '-DNIST_EXTERN_API_VERSION',
             *includes, str(source/'11/src/testdriver/validate11.cpp'), str(source/'common/src/util/util.cpp'),
             str(library), '-Wl,-rpath,'+str(work), '-o', str(driver)])
        receipt['binarySHA256'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in [library, driver]}
        exercise_synthetic_io(run, driver, work)
        receipt.update(passed=True, syntheticRGBAndGrayscale=True, multiImageInput=True,
                       initializationBeforeFork='Executed by unmodified official driver', forksPerInvocation=2,
                       nullTemplateCount=4, nullMatchCount=2)
    finally:
        receipt['finishedUTC'] = datetime.now(timezone.utc).isoformat()
        (output/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', choices=tuple(COMPILERS), default=CLANG_COMPILER)
    parser.add_argument('--build-root', type=Path, default=ROOT.parent/'.build/nist')
    parser.add_argument('--container-image', choices=tuple(CONTAINER_IMAGES), help='Run compiler and driver in an existing Linux amd64 Docker image')
    args = parser.parse_args()
    check(args.compiler, args.build_root, args.container_image)
