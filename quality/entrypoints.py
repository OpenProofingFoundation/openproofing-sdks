"""Bind shared QA mechanisms to one explicit capability root."""
import importlib.util
from pathlib import Path


def load(name,root):
    source=Path(__file__).parent/(name+'.py')
    spec=importlib.util.spec_from_file_location('kenshiki_quality_'+name,source)
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.ROOT=root
    return module
