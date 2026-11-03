#!/usr/bin/env python3
"""Compiler-derived compatibility snapshots for the optional demonstration module."""
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from quality.public_api import jvm_surface, swift_surface


def surface(lane):
    if lane == 'macos':
        return swift_surface(ROOT/'presentation', {'swiftModule': 'KenshikiPresentation'}, 'macos')
    if lane != 'android':
        raise ValueError('Unapproved presentation API lane')
    classes = ROOT/'reference-apps/android/app/build/intermediates/built_in_kotlinc/debug/compileDebugKotlin/classes'
    paths = sorted((classes/'com/kenshiki/presentation').glob('*.class'))
    if not paths:
        raise ValueError('Missing built-in Kotlin presentation compiler output')
    if any(path.is_symlink() for path in paths):
        raise ValueError('Presentation API compiler output cannot be a symlink')
    names = [path.relative_to(classes).with_suffix('').as_posix().replace('/', '.') for path in paths]
    return jvm_surface(classes, names)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=('macos', 'android'), required=True)
    parser.add_argument('--write', action='store_true', help='Create explicitly reviewed initial API baseline; never used in CI')
    args = parser.parse_args()
    actual = surface(args.platform)
    path = ROOT/'presentation/api'/(args.platform+'.json')
    if args.write:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(actual, indent=2, sort_keys=True)+'\n')
        print('WROTE '+path.relative_to(ROOT).as_posix())
        return 0
    if not path.is_file() or json.loads(path.read_text()) != actual:
        print('FAIL presentation public API drift: '+args.platform)
        return 1
    print('PASS compiler-derived presentation public API: '+args.platform)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
