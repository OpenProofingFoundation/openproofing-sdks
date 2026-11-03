#!/usr/bin/env python3
"""Capability entry point for shared source and contract guards."""
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT.parent/'quality'))
from entrypoints import load
_shared=load('capability_guards',ROOT)
def scan(root=ROOT):return _shared.scan(root)
def __getattr__(name):return getattr(_shared,name)
if __name__=='__main__':raise SystemExit(_shared.main(ROOT))
