#!/usr/bin/env python3
"""Run every shared quality gate for this capability's explicit root."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from quality.runner import main

if __name__ == '__main__':
    raise SystemExit(main(Path(__file__).resolve().parents[1]))
