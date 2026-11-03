#!/usr/bin/env python3
"""Install pinned guard tooling for all capability packages without lifecycle scripts."""
from pathlib import Path
import subprocess
import sys
from check import require_python

ROOT = Path(__file__).resolve().parents[1]

if __name__ == '__main__':
    require_python()
    for name in ('document', 'passport', 'biometric'):
        subprocess.run(['npm', 'ci', '--ignore-scripts'], cwd=ROOT/name, check=True)
    validator = ROOT/'.build/contracts-validator'
    subprocess.run([sys.executable, '-m', 'venv', str(validator)], cwd=ROOT, check=True)
    subprocess.run([str(validator/'bin/python'), '-m', 'pip', 'install',
                    '--disable-pip-version-check', '--no-deps',
                    '-r', str(ROOT/'contracts/tools/requirements.txt')], cwd=ROOT, check=True)
