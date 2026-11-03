"""Exact portable C++ inventory and dependency boundaries; runtime tests remain separate."""
import hashlib
import json
from pathlib import Path
import re

ALIGNED_HEADER = 'cpp/include/kenshiki/auraface_input.hpp'
ALIGNED_SOURCE = 'cpp/src/auraface_input.cpp'

FILES = {
    'cpp/include/kenshiki/portrait.hpp',
    'cpp/src/portrait.cpp',
    ALIGNED_HEADER,
    'cpp/include/kenshiki/auraface.hpp',
    ALIGNED_SOURCE,
    'cpp/src/auraface.cpp',
    'cpp/src/auraface_runtime.hpp',
    'cpp/tests/contract_tests.cpp',
    'cpp/tests/auraface_input_tests.cpp',
    'cpp/tests/auraface_runtime_tests.cpp',
    'cpp/tests/generate_auraface_fixtures.py',
    'cpp/generate_vectors.py',
    'cpp/check_inference.py',
    'cpp/CMakeLists.txt',
    'cpp/README.md',
    'cpp/include/kenshiki/face_alignment.hpp',
    'cpp/include/kenshiki/auraface_bridge.h',
    'cpp/include/module.modulemap',
    'cpp/src/face_alignment.cpp',
    'cpp/src/auraface_bridge.cpp',
    'cpp/tests/face_alignment_tests.cpp',
    'cpp/include/kenshiki/frame_selection.h',
    'cpp/src/frame_selection.cpp',
    'cpp/tests/frame_selection_tests.cpp',
    'cpp/quality/ofiq_bridge.cpp',
    'cpp/quality/include/ofiq_native.h',
}
PRUNE = {'.build', 'build', '__pycache__'}
PROFILE_PINS = {
    'auraface-aligned-input-v1.json': '70da7b12bc90fda352222d941cc51e97288305de9522320fde8633b22a38e1d9',
    'auraface-artifact-v1.json': '9db36f239a89adfa6794f616f7face61f5ba1b0ca0c7f26b93a6204001856347',
}


def source_inventory(root, failures):
    folder = root/'cpp'
    actual = set()
    for path in folder.rglob('*'):
        if any(part in PRUNE for part in path.relative_to(folder).parts):
            continue
        if path.is_symlink():
            failures.append('Portable source symlink: '+path.relative_to(root).as_posix())
        elif path.is_file():
            actual.add(path.relative_to(root).as_posix())
    if actual != FILES:
        failures.append('Portable C++ inventory differs: '+str(sorted(actual ^ FILES)))
    return actual


def check_source_lock(root, failures):
    lock_path = root/'Gates/cpp-sources.json'
    try:
        lock = json.loads(lock_path.read_text())
        if set(lock) != FILES:
            failures.append('Portable C++ lock inventory differs')
        for name in FILES:
            path = root/name
            if not path.is_file() or path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != lock.get(name):
                failures.append('Portable C++ source requires reviewed digest: '+name)
    except (OSError, ValueError):
        failures.append('Portable C++ source lock missing or invalid')
    # This portable library must stay separate from capture, mobile storage,
    # platform proofs, UI, transport and the upstream null reference.
    for name in ('cpp/include/kenshiki/portrait.hpp', 'cpp/src/portrait.cpp',
                 ALIGNED_HEADER, ALIGNED_SOURCE,
                 'cpp/include/kenshiki/auraface.hpp', 'cpp/src/auraface.cpp', 'cpp/src/auraface_runtime.hpp',
                 'cpp/include/kenshiki/face_alignment.hpp', 'cpp/src/face_alignment.cpp',
                 'cpp/include/kenshiki/auraface_bridge.h', 'cpp/src/auraface_bridge.cpp',
                 'cpp/include/kenshiki/frame_selection.h', 'cpp/src/frame_selection.cpp'):
        path = root/name
        if not path.is_file():
            continue
        source = path.read_text()
        if re.search(r'\b(?:printf|fprintf|cout|cerr|clog|syslog|socket|connect|system|popen|fopen|fstream|sqlite3|JNIEnv)\b|AVFoundation|UIKit|android/|upstream/', source):
            failures.append('Portable library has nonportable side effects/dependency: '+name)
        if name in {ALIGNED_HEADER, ALIGNED_SOURCE, 'cpp/include/kenshiki/frame_selection.h', 'cpp/src/frame_selection.cpp'} and 'onnxruntime' in source:
            failures.append('Aligned input must not require the optional inference runtime')


def check_profiles(root, failures):
    source = root/ALIGNED_SOURCE
    if not source.is_file():
        return
    text = source.read_text()
    for name, expected in PROFILE_PINS.items():
        path = root.parent/'contracts'/name
        if not path.is_file() or path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            failures.append('AuraFace exact profile identity changed: '+name)
        if text.count('"'+expected+'"') != 1:
            failures.append('AuraFace compiled identity differs: '+name)


def check(root):
    failures = []
    source_inventory(root, failures)
    check_source_lock(root, failures)
    check_profiles(root, failures)
    return FILES, failures
