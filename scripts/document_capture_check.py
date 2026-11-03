#!/usr/bin/env python3
"""Execute document capture tests with fresh source- and artifact-bound iOS evidence."""
from datetime import datetime,timezone
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT));sys.path.insert(0,str(ROOT/'scripts'))
from check import require_python
from presentation_check import safe_path,simulator_destination
from quality.document_capture_evidence import TARGETS,required,validate,audit_diagnostics


def sources():
 paths=[Path(__file__),ROOT/'quality/document_capture_evidence.py',ROOT/'quality/capture_evidence.py',ROOT/'document/Package.swift', ROOT/'document/Package.resolved', ROOT/'Package.swift', ROOT/'Package.resolved', ROOT/'foundation/Package.swift', ROOT/'foundation/Package.resolved', ROOT/'foundation/dependencies.json', ROOT/'foundation/sources.json', ROOT/'foundation/capture-custody-extraction.json']
 for directory in ['document/ios','document/native','document/Gates','foundation/Sources']:
  paths.extend(p for p in (ROOT/directory).rglob('*') if p.is_file() and '__pycache__' not in p.parts)
 paths.extend((ROOT/'document/scripts').glob('*'))
 return {p.relative_to(ROOT).as_posix():hashlib.sha256(safe_path(p).read_bytes()).hexdigest() for p in sorted(set(paths)) if p.is_file()}


def native_artifacts():
 base=ROOT/'document/.build/native'
 return {p.relative_to(base).as_posix():hashlib.sha256(('symlink:'+str(p.readlink())).encode() if p.is_symlink() else safe_path(p).read_bytes()).hexdigest() for p in sorted(base.rglob('*')) if p.is_file() or p.is_symlink()}


def run(simulator_id=None):
 subprocess.run([sys.executable,'document/scripts/provision_native.py'],cwd=ROOT,check=True)
 subprocess.run([sys.executable,'document/scripts/provision_test_assets.py'],cwd=ROOT,check=True)
 subprocess.run([sys.executable,'-m','unittest','discover','-s','document/scripts','-p','test_verify_capture_bridge.py'],cwd=ROOT,check=True)
 output=safe_path(ROOT/'.build/document-capture');output.mkdir(parents=True,exist_ok=True)
 attempt=Path(tempfile.mkdtemp(prefix='ios-',dir=output));result=attempt/'tests.xcresult';log=attempt/'execution.log'
 expected=required(ROOT/'document');start_ns=time.time_ns()
 native_before=native_artifacts()
 receipt={'startedUTC':datetime.now(timezone.utc).isoformat(),'sourceSHA256':sources(),'startNativeArtifactSHA256':native_before,'requiredIDs':sorted(expected),'revision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'gitStatus':subprocess.check_output(['git','status','--porcelain'],cwd=ROOT,text=True),'host':platform.platform(),'passed':False,'scope':'Synthetic document capture, parser, geometry, source/clock/custody and public-domain Vision control; no physical camera or identity-authenticity qualification'}
 try:
  destination=simulator_destination() if simulator_id is None else 'platform=iOS Simulator,id='+simulator_id
  command=['xcodebuild','-scheme','KenshikiDocumentSDK-Package','-destination',destination,'-derivedDataPath',str(attempt/'build'),'-resultBundlePath',str(result),*[arg for target in TARGETS for arg in ['-only-testing:'+target]],'-parallel-testing-enabled','NO','-collect-test-diagnostics','on-failure','CODE_SIGNING_ALLOWED=NO','test']
  receipt.update(command=command,destination=destination)
  with log.open('w') as stream:completed=subprocess.run(command,cwd=ROOT/'document',stdout=stream,stderr=subprocess.STDOUT,timeout=1800,check=False)
  if completed.returncode:raise ValueError('Document native execution failed: '+str(completed.returncode))
  payloads={}
  for kind in ['summary','tests']:
   payloads[kind]=json.loads(subprocess.check_output(['xcrun','xcresulttool','get','test-results',kind,'--path',str(result)],text=True));(attempt/(kind+'.json')).write_text(json.dumps(payloads[kind],indent=2)+'\n')
  for kind in ['attachments','diagnostics']:
   with (attempt/(kind+'-export.log')).open('w') as export_log:
    subprocess.run(['xcrun','xcresulttool','export',kind,'--path',str(result),'--output-path',str(attempt/kind)],stdout=export_log,stderr=subprocess.STDOUT,check=True)
  receipt['diagnosticSHA256']={kind:audit_diagnostics(attempt/kind) for kind in ['attachments','diagnostics']}
  receipt['executionLogAuditSHA256']=audit_diagnostics(log)
  receipt['executedIDs']=validate(payloads['summary'],payloads['tests'],expected,start_ns)
  receipt['toolchain']=subprocess.check_output(['xcodebuild','-version'],text=True)
  receipt['sdkVersion']=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-version'],text=True).strip()
  receipt['devicesAndConfigurations']=payloads['summary'].get('devicesAndConfigurations',[])
  products=attempt/'build/Build/Products'
  binaries=[p for p in products.glob('Debug-iphonesimulator/*.xctest/*') if p.is_file() and p.name in TARGETS]
  if {p.name for p in binaries}!=set(TARGETS):raise ValueError('Document native test binary absent')
  receipt['artifactSHA256']={p.relative_to(attempt).as_posix():hashlib.sha256(safe_path(p).read_bytes()).hexdigest() for p in binaries}
  subprocess.run([sys.executable,'document/scripts/verify_capture_bridge.py'],cwd=ROOT,check=True)
  subprocess.run([sys.executable,'document/scripts/verify_capture_opencv.py'],cwd=ROOT,check=True)
  receipt['nativeArtifactSHA256']=native_artifacts()
  if receipt['startNativeArtifactSHA256']!=receipt['nativeArtifactSHA256']:raise ValueError('Native artifacts changed during execution')
  receipt['bridgeReceiptSHA256']=hashlib.sha256((ROOT/'document/.build/native/build-receipt.json').read_bytes()).hexdigest()
  receipt['endSourceSHA256']=sources()
  if receipt['sourceSHA256']!=receipt['endSourceSHA256']:raise ValueError('Document source changed during execution')
  receipt['resultSHA256']={p.relative_to(attempt).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(result.rglob('*')) if p.is_file()}
  receipt['passed']=True
 except (OSError,ValueError,subprocess.SubprocessError) as error:receipt['error']=type(error).__name__+': '+str(error)
 receipt['finishedUTC']=datetime.now(timezone.utc).isoformat()
 if log.exists():receipt['logSHA256']=hashlib.sha256(log.read_bytes()).hexdigest()
 (attempt/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(('PASS' if receipt['passed'] else 'FAIL')+' document iOS: '+str(attempt/'receipt.json'),flush=True)
 return int(not receipt['passed'])

if __name__=='__main__':
 require_python();parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--simulator-id');args=parser.parse_args();raise SystemExit(run(args.simulator_id))
