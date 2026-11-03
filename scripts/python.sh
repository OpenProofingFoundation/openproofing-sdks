#!/usr/bin/env bash
# Use the project pin without changing another repository's Python installation.
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
expected="$(cat "$root/.python-version")"
for interpreter in "$root/.build/python/bin/python3" python3.15 /opt/homebrew/opt/python@3.15/bin/python3.15 /usr/local/opt/python@3.15/bin/python3.15 python3; do
    candidate="$(command -v "$interpreter")" || continue
    actual="$("$candidate" -c 'import platform; print(platform.python_version())')" || continue
    if [[ "$actual" == "$expected" ]]; then
        export PATH="$(dirname -- "$candidate"):$PATH"
        exec "$candidate" "$@"
    fi
done
printf 'Python %s is required. Install that version, then create .build/python with python3.15 -m venv .build/python.\n' "$expected" >&2
exit 1
