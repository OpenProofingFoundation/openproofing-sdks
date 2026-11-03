#!/usr/bin/env python3
"""Verify the complete pinned, normalized OpenCV resource without invoking a build."""
import hashlib
import json
import sys
from pathlib import Path
root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / "native/opencv-normalized-manifest.json").read_text())
framework = Path(sys.argv[1]) if len(sys.argv) > 1 else root / ".build/native/opencv2.xcframework"
errors = []
actual={p.relative_to(framework).as_posix() for p in framework.rglob('*') if p.is_file() or p.is_symlink()}
if framework.is_symlink() or actual != set(manifest['files']):
    errors.append('framework entry inventory')
for p in framework.rglob('*'):
    if p.is_symlink() and (p.relative_to(framework).as_posix() not in manifest['files'] or 'symlink' not in manifest['files'][p.relative_to(framework).as_posix()]):
        errors.append('unregistered symlink '+p.relative_to(framework).as_posix())
for name, expected in manifest["files"].items():
    target = framework / name
    if "symlink" in expected:
        if not target.is_symlink() or str(target.readlink()) != expected["symlink"]:
            errors.append(name)
    elif target.is_symlink() or not target.is_file() or hashlib.sha256(target.read_bytes()).hexdigest() != expected["sha256"]:
        errors.append(name)
if errors:
    print("OpenCV integrity mismatch: " + ", ".join(errors), file=sys.stderr)
    raise SystemExit(1)
print(f"Verified OpenCV {manifest['version']}: {len(manifest['files'])} pinned entries")
