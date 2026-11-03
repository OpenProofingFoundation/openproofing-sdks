#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 1 ]]; then echo 'Usage: tools/face_lab/setup.sh /absolute/external/workdir' >&2; exit 2; fi
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
face_workdir="$(python3.11 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$1")"
checkout_dir="$repo_dir"
if [[ -f "$repo_dir/../sdks.json" ]]; then checkout_dir="$(cd "$repo_dir/.." && pwd)"; fi
case "$face_workdir/" in "$checkout_dir/"*) echo 'Work directory must be outside the SDK checkout' >&2; exit 2;; *) ;; esac
python3.11 -m venv "$face_workdir/venv"
chmod 700 "$face_workdir"
"$face_workdir/venv/bin/python" -m pip install pip==25.1.1
"$face_workdir/venv/bin/python" -m pip install --require-hashes --only-binary=:all: -r "$repo_dir/tools/face_lab/requirements-macos.lock.txt"
"$face_workdir/venv/bin/python" -m pip check
"$face_workdir/venv/bin/python" "$repo_dir/tools/face_lab/smoke.py" --workdir "$face_workdir"
