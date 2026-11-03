#!/usr/bin/env python3
"""Capability entry point for the shared boundary engine."""
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT.parent/'quality'))
from entrypoints import load
_shared=load('boundary_entry',ROOT)
def engine(root=ROOT):return _shared.engine(root)
def findings(root=ROOT):return _shared.findings(root)
def __getattr__(name):return getattr(_shared,name)
if __name__=='__main__':raise SystemExit(_shared.main())
