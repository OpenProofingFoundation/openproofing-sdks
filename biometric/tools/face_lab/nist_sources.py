#!/usr/bin/env python3
"""Stage pinned NIST interface/reference sources and check the local C++20 toolchain."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from data import external_directory
REPO=Path(__file__).resolve().parents[2]

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--workdir',type=Path,required=True);parser.add_argument('--linux-check',action='store_true');args=parser.parse_args()
    root=external_directory(args.workdir);folder=root/'nist';folder.mkdir(exist_ok=True)
    sources=json.loads((REPO/'nist/sources.json').read_text())
    for entry in sources['sources']:
        destination=folder/entry['path'];destination.parent.mkdir(parents=True,exist_ok=True)
        blob=(REPO/'nist/upstream'/entry['path']).read_bytes()
        if destination.exists() and destination.read_bytes()!=blob:raise ValueError('Staged NIST source differs from integrated source: '+entry['path'])
        if hashlib.sha256(blob).hexdigest()!=entry['sha256']:raise ValueError('NIST source digest mismatch: '+entry['path'])
        if not destination.exists():destination.write_bytes(blob)
    # This probe checks headers/compiler, not an inference implementation or validation result.
    probe=folder/'header_probe.cpp';probe.write_text('#include <frvt11.h>\n#include <type_traits>\nstatic_assert(std::is_abstract_v<FRVT_11::Interface>);\nint main() { return 0; }\n')
    subprocess.run(['clang++','-std=c++20','-Wall','-Wextra','-Werror','-fsyntax-only','-I'+str(folder/'11/src/include'),'-I'+str(folder/'common/src/include'),str(probe)],check=True)
    result={'headerPinVerified':True,'localCXX20HeaderCompile':True,'upstreamRevision':sources['upstreamRevision'],'algorithmAdapterImplemented':False,'officialValidationExecuted':False}
    if args.linux_check:
        command='set -eu; g++-13 -std=c++20 -Wall -Wextra -Werror -I/work/11/src/include -I/work/common/src/include /work/header_probe.cpp -o /tmp/probe; /tmp/probe; g++-13 -dumpfullversion; uname -m; cat /etc/os-release'
        log=subprocess.check_output(['docker','run','--rm','--platform','linux/amd64','--network','none','--read-only','--tmpfs','/tmp:rw,exec,nosuid,size=64m','--mount','type=bind,src='+str(folder)+',dst=/work,readonly','kenshiki-face-frte-dev:20261016','sh','-c',command],text=True)
        (folder/'linux-toolchain.log').write_text(log)
        result.update({'linuxCXX20HeaderCompileAndRun':True,'compilerVersion':log.splitlines()[0],'architecture':log.splitlines()[1],'developmentImageID':subprocess.check_output(['docker','image','inspect','kenshiki-face-frte-dev:20261016','--format','{{.Id}}'],text=True).strip(),'hostExecution':'Linux amd64 emulation on Apple Silicon; no NIST timing claim','targetQualificationOS':'NIST Ubuntu 24.04.3; development container OS recorded separately in linux-toolchain.log'})
    (folder/'toolchain-receipt.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
if __name__=='__main__':main()
