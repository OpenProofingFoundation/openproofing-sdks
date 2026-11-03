#!/usr/bin/env python3
"""Run all repository guards, retain each result, and fail if any check fails."""
import hashlib
import json
import subprocess
import sys
import time

def main(root):
    if sys.argv[1:]:raise SystemExit('The quality runner accepts no scope/suppression arguments')
    output=root/'.build/quality';output.mkdir(parents=True,exist_ok=True)
    gates=[
        ('upstream-self-tests',[sys.executable,'Gates/boundary_gates.py','--self-test']),
        ('guard-regressions',[sys.executable,'-m','unittest','discover','-s','Gates/tests','-p','test_*.py']),
        ('boundaries',[sys.executable,'Gates/boundary_gates.py']),
        ('lock-integrity',['node','scripts/guards/package-lock-integrity.mjs']),
        ('capability-guards',[sys.executable,'Gates/capability_guards.py']),
    ]
    results=[]
    for name,command in gates:
        start=time.monotonic()
        try:
            result=subprocess.run(command,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
            status=result.returncode;log=result.stdout
        except (OSError,subprocess.TimeoutExpired) as error:
            status=1;log=type(error).__name__+': guard execution failed\n'
        (output/(name+'.log')).write_text(log)
        results.append({'gate':name,'passed':status==0,'exitCode':status,'milliseconds':round((time.monotonic()-start)*1000),'log':name+'.log'})
        print(('PASS ' if status==0 else 'FAIL ')+name,flush=True)
        if status: print(log,flush=True)
        inputs={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((root/'Gates').rglob('*')) if p.is_file() and '__pycache__' not in p.parts}
        try: revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,stderr=subprocess.DEVNULL,text=True).strip()
        except subprocess.CalledProcessError: revision=None
        (output/'results.json').write_text(json.dumps({'revision':revision,'gitStatus':subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True),'guardInputsSHA256':inputs,'results':results},indent=2)+'\n')
    return not all(r['passed'] for r in results)
