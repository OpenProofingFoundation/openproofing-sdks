"""Closed document capture graph, native source provenance and artifact boundary."""
import hashlib
import json
from pathlib import Path
import re

MODULES = ('DocumentSDK','DocumentCaptureApple','DocumentCapturePreview','DocumentCaptureJournal','DocumentCapture')
ROOTS = tuple('ios/Sources/'+name for name in MODULES)
EDGES = {
 ('DocumentOpenCVBridge',False):set(), ('DocumentSDK',False):set(),
 ('DocumentCaptureApple',False):{'DocumentSDK','DocumentOpenCVBridge'},
 ('DocumentCapturePreview',False):{'DocumentCaptureApple','DocumentSDK'},
 ('DocumentCaptureJournal',False):{'DocumentSDK','DocumentCaptureApple','CaptureEvidenceCustody','KenshikiFoundation'},
 ('DocumentCapture',False):{'DocumentSDK','DocumentCaptureApple','DocumentCaptureJournal','CaptureEvidenceCustody','KenshikiEvidenceManifest','KenshikiFoundation'},
 ('DocumentCoreTests',True):{'DocumentSDK'},
 ('DocumentAppleTests',True):{'DocumentSDK','DocumentCaptureApple','DocumentCapturePreview'},
 ('DocumentJournalTests',True):{'DocumentCaptureJournal','DocumentCaptureApple','CaptureEvidenceCustody','KenshikiFoundation'},
 ('DocumentCaptureTests',True):{'DocumentCapture','DocumentCaptureApple','DocumentCaptureJournal','CaptureEvidenceCustody','KenshikiFoundation'},
 ('DocumentQualityGuardsTests',True):{'DocumentSDK'},
}
FOUNDATION_MODULES={'CaptureEvidenceCustody','KenshikiEvidenceManifest'}
ARCHIVE_SHA256='980a041077a8fcb44ef98e0f3a9710fe029e4458ebdbedb0d3d3b598129a651f'
IMPORTS = {
 'DocumentSDK':{'Foundation'},
 'DocumentCaptureApple':{'AVFoundation','CoreGraphics','CoreImage','CoreML','CoreMedia','CoreMotion','CoreVideo','CryptoKit','DocumentSDK','DocumentOpenCVBridge','Foundation','ImageIO','UniformTypeIdentifiers','Vision','os'},
 'DocumentCapturePreview':{'DocumentCaptureApple','DocumentSDK','AVFoundation','UIKit','Foundation','CoreGraphics','os'},
 'DocumentCaptureJournal':{'CoreMedia','Foundation','CryptoKit','DocumentSDK','DocumentCaptureApple','CaptureEvidenceCustody'},
 'DocumentCapture':{'Foundation','AVFoundation','CoreGraphics','CoreLocation','CoreMedia','CoreVideo','CryptoKit','DocumentSDK','DocumentCaptureApple','DocumentCaptureJournal','CaptureEvidenceCustody','KenshikiEvidenceManifest'},
}


def graph(root,gate,failures):
 text=(root/'Package.swift').read_text()
 if dict(gate._target_declarations(text))!={name:'ios/Sources/'+name for name in MODULES}:
  failures.append('Document exact target/source graph differs')
 declarations=list(gate._dependency_edges(text))
 if len(declarations)!=len(EDGES) or {(name,test):deps for name,test,deps in declarations}!=EDGES:
  failures.append('Document exact dependency graph differs')
 products=re.findall(r'\.library\(name: "([^"]+)", targets: \["([^"]+)"\]\)',text)
 if len(products)!=len(MODULES) or set(products)!={(name,name) for name in MODULES}:
  failures.append('Document capture products must be independent public libraries')
 if re.findall(r'\.package\(name: "([^"]+)", path: "([^"]+)"\)',text)!=[('KenshikiFoundation','..')] or text.count('.package(')!=1:
  failures.append('Only the canonical same-checkout root foundation package is reviewed')
 if (re.findall(r'\.binaryTarget\(name: "([^"]+)", path: "([^"]+)"\)',text)
     !=[('DocumentOpenCVBridge','.build/native/DocumentOpenCVBridge.xcframework')] or text.count('.binaryTarget(')!=1):
  failures.append('Only the source-built document bridge is reviewed')
 if re.search(r'unsafeFlags|\.plugin\s*\(|ProcessInfo|FileManager|import Foundation|https?://',text):
  failures.append('Document package cannot select ambient, unsafe or remote runtime dependencies')
 if set(gate.neutral_targets())!=set(MODULES):failures.append('All document Swift modules must receive intact neutral rules')


def locked_native(root,failures):
 manifest=json.loads((root/'Gates/native-sources.json').read_text())
 records=manifest['files'];actual={p.relative_to(root).as_posix() for p in (root/'native/DocumentOpenCVBridge').rglob('*') if p.is_file() or p.is_symlink()}
 if set(records)!=actual:failures.append('Document native source inventory differs')
 for name,record in records.items():
  p=root/name
  if not name.startswith('native/DocumentOpenCVBridge/') or '..' in Path(name).parts or p.is_symlink() or not p.is_file():
   failures.append('Invalid document native source path: '+name);continue
  if hashlib.sha256(p.read_bytes()).hexdigest()!=record.get('destinationSHA256'):
   failures.append('Document native source requires reviewed digest: '+name)
  if not re.fullmatch(r'[0-9a-f]{64}',record.get('sourceSHA256','')) or not isinstance(record.get('patches'),list):
   failures.append('Document native donor provenance missing: '+name)
  if 'Upstream/' not in name and 'Spatial/Vendor/' not in name and p.suffix in {'.cpp','.mm','.hpp','.h'}:
   code=p.read_text()
   if re.search(r'\b(?:printf|fprintf|cout|cerr|clog|syslog|socket|connect|system|popen|fopen|fstream|sqlite3)\b|Regula|DocumentReader',code):
    failures.append('Document native authored adapter has unreviewed effect/vendor dependency: '+name)
 resource=json.loads((root/'native/opencv-normalized-manifest.json').read_text())
 if resource.get('version')!='4.12.0' or resource.get('archiveSHA256')!=ARCHIVE_SHA256 or len(resource.get('files',{}))!=1091:
  failures.append('OpenCV resource pin/inventory changed')
 return actual


def example_inventory(root,failures):
 import subprocess
 manifest=json.loads((root/'Gates/example-sources.json').read_text());records=manifest['files']
 expected={'examples/ios/Sources/DocumentCaptureExampleApp.swift','examples/ios/Sources/DocumentCaptureExampleController.swift','examples/ios/project.yml'}
 actual={p.relative_to(root).as_posix() for p in (root/'examples/ios/Sources').rglob('*') if p.is_file() or p.is_symlink()} | {'examples/ios/project.yml'}
 if actual!=expected or set(records)!=expected or manifest.get('role')!='host':failures.append('Independent document example inventory/host role differs')
 for name,digest in records.items():
  p=root/name
  if name not in expected or p.is_symlink() or not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=digest:failures.append('Example source requires reviewed digest: '+name)
  if p.suffix=='.swift':
   text=p.read_text()
   if '@testable' in text or 'IdentityEvidence' in text or re.search(r'^import (?:CaptureEvidenceCustody|KenshikiProtectedStorage)',text,re.M):failures.append('Example must consume the public optical document surface: '+name)
 script="import fs from 'node:fs';import YAML from 'yaml';process.stdout.write(JSON.stringify(YAML.parse(fs.readFileSync(process.argv[1],'utf8'))));"
 project=json.loads(subprocess.check_output(['node','--input-type=module','-e',script,str(root/'examples/ios/project.yml')],cwd=root.parent,text=True))
 if project.get('packages')!={'KenshikiDocument':{'path':'../..'},'KenshikiDesign':{'path':'../../../design-system'}}:failures.append('Example must resolve only same-checkout public packages')
 targets=project.get('targets',{})
 if set(targets)!={'DocumentCaptureExample'} or targets['DocumentCaptureExample'].get('type')!='application':failures.append('Document example must remain an application host')
 else:
  deps=targets['DocumentCaptureExample'].get('dependencies',[])
  wanted={('KenshikiDocument','DocumentSDK'),('KenshikiDocument','DocumentCaptureApple'),('KenshikiDocument','DocumentCapturePreview'),('KenshikiDesign','KenshikiDesign')}
  if len(deps)!=4 or {(d.get('package'),d.get('product')) for d in deps}!=wanted:failures.append('Document example public product graph differs')
 return expected


def replay_inventory(root,failures):
 manifest=json.loads((root/'Gates/replay-sources.json').read_text())
 records=manifest['files'];actual=set()
 for p in (root/'assurance').rglob('*'):
  if any(part in {'.build','.swiftpm','__pycache__'} for part in p.relative_to(root/'assurance').parts):continue
  if p.is_file() or p.is_symlink():actual.add(p.relative_to(root).as_posix())
 if actual!=set(records):failures.append('Optional document replay harness inventory differs')
 for name,digest in records.items():
  p=root/name
  if not name.startswith('assurance/') or '..' in Path(name).parts or p.is_symlink() or not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=digest:
   failures.append('Optional replay source requires reviewed provenance: '+name)
 text=(root/'assurance/Package.swift').read_text()
 if ('.package(path: "..")' not in text or '.library(' in text or '.target(' in text
     or re.search(r'unsafeFlags|https?://|ProcessInfo|\.plugin\s*\(',text)):
  failures.append('Optional replay package must only test the public local document product')
 return actual


def swift_inventory(root,failures):
 manifest=json.loads((root/'Gates/capture-sources.json').read_text())
 records=manifest['files']
 if isinstance(records,dict): records=[dict(v,destination=k) for k,v in records.items()]
 seen=set()
 for record in records:
  name=record['destination'];p=root/name
  if name in seen or not name.startswith(('ios/Sources/','ios/Tests/')) or '..' in Path(name).parts:
   failures.append('Invalid/duplicate document Swift provenance path: '+name)
  seen.add(name)
  if p.is_symlink() or not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=record.get('destinationSHA256'):
   failures.append('Document Swift source requires reviewed provenance: '+name)
  if record.get('sourcePath') is not None and not re.fullmatch(r'[0-9a-f]{64}',record.get('sourceSHA256','')):
   failures.append('Document Swift donor hash absent: '+name)
  references=record.get('sourceReferences',[])
  if not isinstance(references,list):
   failures.append('Invalid document adaptation references: '+name)
   continue
  identities=set()
  for reference in references:
   if not isinstance(reference,dict) or set(reference)!={'repository','revision','path','sha256','basis'}:
    failures.append('Invalid document adaptation reference shape: '+name)
    continue
   path=reference['path']
   if (not isinstance(path,str) or not path or Path(path).is_absolute() or '..' in Path(path).parts
       or not isinstance(reference['repository'],str) or not reference['repository']
       or not isinstance(reference['revision'],str) or not isinstance(reference['sha256'],str)
       or not re.fullmatch(r'[0-9a-f]{40}',reference['revision'])
       or not re.fullmatch(r'[0-9a-f]{64}',reference['sha256'])
       or not isinstance(reference['basis'],str) or not reference['basis'].strip()):
    failures.append('Invalid document adaptation reference identity: '+name)
    continue
   identity=(reference['repository'],path)
   if identity in identities:failures.append('Duplicate document adaptation reference: '+name)
   identities.add(identity)
 actual={p.relative_to(root).as_posix() for folder in ['ios/Sources','ios/Tests'] for p in (root/folder).rglob('*.swift')}
 if seen!=actual:failures.append('Document exact Swift source/test inventory differs: '+str(sorted(seen^actual)))


def check(root):
 failures=[];approved=set()
 try:
  from boundary_entry import configure,engine
  gate=configure(engine(root),root);graph(root,gate,failures)
  approved=locked_native(root,failures)
  approved.update(replay_inventory(root,failures))
  approved.update(example_inventory(root,failures))
  swift_inventory(root,failures)
  for module,allowed in IMPORTS.items():
   for p in (root/'ios/Sources'/module).glob('*.swift'):
    imports=set(re.findall(r'^import (\w+)',gate.mask(p.read_text()),re.M))
    if imports-allowed:failures.append('Unreviewed document dependency: '+p.name+' '+str(sorted(imports-allowed)))
 except (OSError,ValueError,KeyError,TypeError) as error:
  failures.append('Document capture inventory/graph is incomplete: '+str(error))
 return approved,failures


def native_permission_callback_rule(gate,original):
 """Recognize only the required Objective-C CoreLocation protocol callback signature."""
 def check(target):
  hits=original(target)
  for path in gate.swift_files(target):
   code=gate.mask(path.read_text())
   if not re.search(r'\bCLLocationManagerDelegate\b',code):continue
   pattern=r'public\s+func\s+locationManagerDidChangeAuthorization\(_\s+manager:\s*CLLocationManager\)\s*\{'
   for match in re.finditer(pattern,code):
    line=code.count('\n',0,match.start())+1
    exact=f'{gate.rel(path)}:{line} verdict-named: locationManagerDidChangeAuthorization'
    hits=[hit for hit in hits if hit!=exact]
  return hits
 return check
