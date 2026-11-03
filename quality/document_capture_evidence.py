"""Source-declared XCTest and Swift Testing inventory with fail-closed iOS execution evidence."""
import json
from pathlib import Path
import re
from urllib.parse import urlparse, unquote
from .capture_evidence import test_cases, validate_summary

TARGETS=('DocumentCoreTests','DocumentAppleTests','DocumentJournalTests','DocumentCaptureTests')
TARGET_FOLDERS=dict(zip(TARGETS,('CoreTests','AppleTests','JournalTests','CaptureTests')))

def declared(root):
 from .boundary_entry import engine
 gate=engine(root);found=set()
 for target in TARGETS:
  for path in sorted((root/'ios/Tests'/TARGET_FOLDERS[target]).glob('*.swift')):
   source=path.read_text();code=gate.mask(source)
   spans=[]
   for match in re.finditer(r'\b(?:class|struct|extension)\s+(\w+Tests)\b[^\{]*\{',code):
    start=match.end();depth=1;end=start
    while end<len(code) and depth:
     depth+=(code[end]=='{')-(code[end]=='}');end+=1
    spans.append((start,end,match[1]))
   previous=0
   for match in re.finditer(r'\bfunc\s+(\w+)\s*\(',code):
    annotation=code[previous:match.start()];previous=match.end()
    scoped=[span for span in spans if span[0]<=match.start()<span[1]]
    suite=min(scoped,key=lambda span:span[1]-span[0])[2] if scoped else None
    swift_test=bool(re.search(r'@Test\b',annotation))
    xctest=bool(suite and match[1].startswith('test'))
    if not swift_test and not xctest:continue
    key='.'.join([target]+([suite] if suite else [])+[match[1]])
    if key in found:raise ValueError('Duplicate document declared test: '+key)
    found.add(key)
 if not found:raise ValueError('Document has no required tests')
 return found


def required(root):
 manifest=json.loads((root/'Gates/capture-tests.json').read_text())
 if set(manifest)!={'schemaVersion','requiredIDs'} or manifest['schemaVersion']!=1:
  raise ValueError('Document required-test manifest shape differs')
 rows=manifest['requiredIDs']
 if not isinstance(rows,list) or len(set(rows))!=len(rows) or set(rows)!=declared(root):
  raise ValueError('Document required IDs differ from source declarations')
 return set(rows)


def validate(summary,tests,expected,started_ns):
 total=validate_summary(summary,expected,started_ns)
 cases=list(test_cases(tests.get('testNodes',[])))
 if len(cases)!=total:raise ValueError('Document executed case count differs from summary')
 executed=set();raw_ids=set()
 for node in cases:
  raw=node.get('nodeIdentifier')
  if node.get('result')!='Passed' or not isinstance(raw,str) or not raw or raw in raw_ids:
   raise ValueError('Document native result is incomplete, failed, skipped or duplicate')
  raw_ids.add(raw)
  url=node.get('nodeIdentifierURL')
  if url:
   parsed=urlparse(url)
   if parsed.scheme!='test' or parsed.netloc!='com.apple.xcode':raise ValueError('Invalid test identity URL')
   components=[unquote(p) for p in parsed.path.split('/') if p]
   identity=components[1:]
  else:
   identity=raw.split('/')
  if not identity:raise ValueError('Missing exact native case identity')
  identity[-1]=re.sub(r'\(.*\)$','',identity[-1])
  name='.'.join(identity)
  if name in expected:executed.add(name)
 if expected-executed:raise ValueError('Document required native cases absent: '+str(sorted(expected-executed)))
 return sorted(executed)



ABNORMAL_NATIVE_EXIT = re.compile(
 r'EXC_(?:BAD_ACCESS|CRASH|RESOURCE|GUARD)|SIG(?:ABRT|SEGV|BUS|ILL)'
 r'|test runner[^\n]*(?:crash|unexpectedly exit)'
 r'|process[^\n]*(?:crashed|terminated unexpectedly)'
 r'|Termination Reason:|[.](?:ips|crash)\b'
 r'|(?:received|found|collected) (?:a )?crash report'
 r'|libc\+\+abi:\s*terminating due to uncaught exception'
 r'|terminate called (?:without an active exception|after throwing)'
 r'|\bprocess\b[^\n]*\bexited due to signal\s+[1-9]\d*\b', re.I)

def audit_diagnostics(root):
 """Reject crash reports, crash attachments, and abnormal test process termination."""
 failures=[]
 for path in ([root] if root.is_file() else root.rglob('*')):
  if path.is_symlink():raise ValueError('Diagnostic symlink is not allowed')
  if not path.is_file():continue
  if path.suffix.lower() in {'.ips','.crash','.hang','.spin'} or re.search(r'(?:crash|hang|abort)',path.name,re.I):
   failures.append(path.name)
  if path.suffix.lower()=='.zip':
   import zipfile
   with zipfile.ZipFile(path) as archive:
    for member in archive.infolist():
     if re.search(r'[.](?:ips|crash|hang|spin)$|(?:crash|abort)',member.filename,re.I):failures.append(member.filename)
     if member.file_size>20*1024*1024:raise ValueError('Diagnostic archive member exceeds audit bound')
     if member.filename.lower().endswith(('.txt','.log','.json')) and ABNORMAL_NATIVE_EXIT.search(archive.read(member).decode('utf-8',errors='replace')):failures.append(member.filename)
  if path.suffix.lower() in {'.txt','.log','.json'}:
   text=path.read_text(errors='replace')
   if ABNORMAL_NATIVE_EXIT.search(text):failures.append(path.name)
 if failures:raise ValueError('Document native diagnostics contain crashes or abnormal exits: '+str(sorted(set(failures))))
 return {p.relative_to(root.parent if root.is_file() else root).as_posix():__import__('hashlib').sha256(p.read_bytes()).hexdigest() for p in ([root] if root.is_file() else sorted(root.rglob('*'))) if p.is_file()}
