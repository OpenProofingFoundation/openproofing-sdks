import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'quality'))
import document_capture_guards as guards
from boundary_entry import configure,engine

class DocumentCaptureGuardTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)/'document'
  shutil.copytree(ROOT/'document',self.root,ignore=shutil.ignore_patterns('.build','node_modules','__pycache__'))
 def tearDown(self):self.temp.cleanup()
 def test_native_inventory_rejects_unregistered_translation_unit(self):
  (self.root/'native/DocumentOpenCVBridge/Hidden.cpp').write_text('int hidden(){return 1;}')
  failures=[];guards.locked_native(self.root,failures)
  self.assertIn('Document native source inventory differs',failures)
 def test_native_inventory_rejects_source_tampering(self):
  p=self.root/'native/DocumentOpenCVBridge/DocumentOpenCVBridge.mm';p.write_text(p.read_text()+'\n// changed\n')
  failures=[];guards.locked_native(self.root,failures)
  self.assertTrue(any('reviewed digest' in e for e in failures))
 def test_opencv_archive_pin_is_required(self):
  p=self.root/'native/opencv-normalized-manifest.json';j=json.loads(p.read_text());j['archiveSHA256']='0'*64;p.write_text(json.dumps(j))
  failures=[];guards.locked_native(self.root,failures)
  self.assertIn('OpenCV resource pin/inventory changed',failures)
 def test_no_remote_or_ambient_package_fallback(self):
  p=self.root/'Package.swift';p.write_text(p.read_text()+'\nlet environment=ProcessInfo.processInfo.environment\n')
  gate=configure(engine(ROOT/'document'),ROOT/'document');failures=[];guards.graph(self.root,gate,failures)
  self.assertTrue(any('ambient' in e for e in failures))
 def test_unsafe_flags_are_rejected(self):
  p=self.root/'Package.swift';p.write_text(p.read_text()+'\nlet flags=unsafeFlags(["-Ounchecked"])\n')
  gate=configure(engine(ROOT/'document'),ROOT/'document');failures=[];guards.graph(self.root,gate,failures)
  self.assertTrue(any('unsafe' in e for e in failures))
 def test_nested_foundation_package_cannot_duplicate_the_root_distribution(self):
  p=self.root/'Package.swift';p.write_text(p.read_text().replace('.package(name: "KenshikiFoundation", path: "..")','.package(name: "KenshikiFoundation", path: "../foundation")'))
  gate=configure(engine(ROOT/'document'),ROOT/'document');failures=[];guards.graph(self.root,gate,failures)
  self.assertIn('Only the canonical same-checkout root foundation package is reviewed',failures)
 def test_optional_preview_cannot_depend_on_capture_workflow_or_product_services(self):
  p=self.root/'Package.swift';original=p.read_text()
  reviewed='dependencies: ["DocumentCaptureApple", "DocumentSDK"], path: "ios/Sources/DocumentCapturePreview"'
  self.assertIn(reviewed,original)
  for dependency in ('DocumentCapture','IdentityGateway'):
   with self.subTest(dependency=dependency):
    p.write_text(original.replace(reviewed,reviewed.replace('"DocumentSDK"','"DocumentSDK", "'+dependency+'"')))
    gate=configure(engine(ROOT/'document'),ROOT/'document');failures=[];guards.graph(self.root,gate,failures)
    self.assertIn('Document exact dependency graph differs',failures)
 def test_adapted_source_references_require_exact_hashes_and_relative_paths(self):
  path=self.root/'Gates/capture-sources.json'
  original=json.loads(path.read_text())
  reference={'repository':'source-app','revision':'a'*40,'path':'Sources/Front.swift',
             'sha256':'b'*64,'basis':'Exact donor bytes captured before adaptation.'}
  for changed in ({'sha256':'unknown'},{'path':'/tmp/Front.swift'},{'path':'../Front.swift'},
                  {'revision':'main'},{'basis':''}):
   with self.subTest(changed=changed):
    manifest=json.loads(json.dumps(original))
    manifest['files'][0]['sourceReferences']=[dict(reference,**changed)]
    path.write_text(json.dumps(manifest))
    failures=[];guards.swift_inventory(self.root,failures)
    self.assertTrue(any('adaptation reference identity' in value for value in failures))
 def test_adapted_source_reference_cannot_drop_shape_or_repeat_origin(self):
  path=self.root/'Gates/capture-sources.json';original=json.loads(path.read_text())
  reference={'repository':'source-app','revision':'a'*40,'path':'Sources/Front.swift',
             'sha256':'b'*64,'basis':'Exact donor bytes captured before adaptation.'}
  for references,expected in (([{}],'shape'),([reference,reference],'Duplicate')):
   with self.subTest(references=references):
    manifest=json.loads(json.dumps(original));manifest['files'][0]['sourceReferences']=references
    path.write_text(json.dumps(manifest));failures=[];guards.swift_inventory(self.root,failures)
    self.assertTrue(any(expected in value for value in failures))
 def test_permission_callback_rule_is_signature_scoped(self):
  class Gate:
   def swift_files(self,target):return [self.path]
   def mask(self,text):return text
   def rel(self,path):return path.name
  gate=Gate();gate.path=self.root/'callback.swift'
  gate.path.write_text('public class Manager: CLLocationManagerDelegate {\npublic func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {}\npublic func isIdentityVerified() {}\n}')
  original=lambda _:['callback.swift:2 verdict-named: locationManagerDidChangeAuthorization','callback.swift:3 verdict-named: isIdentityVerified']
  self.assertEqual(guards.native_permission_callback_rule(gate,original)('X'),['callback.swift:3 verdict-named: isIdentityVerified'])
  gate.path.write_text('public func locationManagerDidChangeAuthorization(_ manager: Any) {}')
  self.assertEqual(guards.native_permission_callback_rule(gate,original)('X'),original('X'))

 def test_sample_private_product_is_rejected(self):
  (Path(self.temp.name)/'node_modules').symlink_to(ROOT/'node_modules',target_is_directory=True)
  p=self.root/'examples/ios/project.yml';p.write_text(p.read_text().replace('product: DocumentSDK','product: CaptureEvidenceCustody'))
  failures=[];guards.example_inventory(self.root,failures)
  self.assertIn('Document example public product graph differs',failures)
 def test_sample_cannot_become_neutral_library(self):
  (Path(self.temp.name)/'node_modules').symlink_to(ROOT/'node_modules',target_is_directory=True)
  p=self.root/'examples/ios/project.yml';p.write_text(p.read_text().replace('type: application','type: framework'))
  failures=[];guards.example_inventory(self.root,failures)
  self.assertIn('Document example must remain an application host',failures)

class DocumentCaptureEvidenceTests(unittest.TestCase):
 def setUp(self):
  from quality.document_capture_evidence import validate
  self.validate=validate
  self.summary={'totalTestCount':1,'result':'Passed','passedTests':1,'failedTests':0,'skippedTests':0,'expectedFailures':0,'startTime':2}
  self.tests={'testNodes':[{'nodeType':'Test Case','nodeIdentifier':'AppleTests/SourceTests/testBinding()','result':'Passed'}]}
  self.expected={'AppleTests.SourceTests.testBinding'}
 def test_current_case_passes(self):self.assertEqual(self.validate(self.summary,self.tests,self.expected,1),sorted(self.expected))
 def test_missing_case_fails(self):
  self.tests['testNodes']=[]
  with self.assertRaises(ValueError):self.validate(self.summary,self.tests,self.expected,1)
 def test_skipped_case_fails(self):
  self.summary['skippedTests']=1
  with self.assertRaises(ValueError):self.validate(self.summary,self.tests,self.expected,1)
 def test_stale_result_fails(self):
  with self.assertRaises(ValueError):self.validate(self.summary,self.tests,self.expected,3_000_000_000)
 def test_different_suite_cannot_stand_in(self):
  self.tests['testNodes'][0]['nodeIdentifier']='AppleTests/SubstituteTests/testBinding()'
  with self.assertRaises(ValueError):self.validate(self.summary,self.tests,self.expected,1)
 def test_different_target_cannot_stand_in(self):
  self.tests['testNodes'][0]['nodeIdentifier']='WrongTests/SourceTests/testBinding()'
  with self.assertRaises(ValueError):self.validate(self.summary,self.tests,self.expected,1)
 def test_prefix_target_cannot_stand_in(self):
  self.tests['testNodes'][0]['nodeIdentifier']='FakeAppleTests/SourceTests/testBinding()'
  with self.assertRaises(ValueError):self.validate(self.summary,self.tests,self.expected,1)
 def test_suffix_suite_cannot_stand_in(self):
  self.tests['testNodes'][0]['nodeIdentifier']='AppleTests/SourceTestsExtra/testBinding()'
  with self.assertRaises(ValueError):self.validate(self.summary,self.tests,self.expected,1)
 def test_real_xcresult_url_supplies_exact_target(self):
  self.tests['testNodes'][0].update(nodeIdentifier='SourceTests/testBinding()',nodeIdentifierURL='test://com.apple.xcode/KenshikiDocumentSDK/AppleTests/SourceTests/testBinding')
  self.assertEqual(self.validate(self.summary,self.tests,self.expected,1),sorted(self.expected))
 def test_crash_report_fails_even_with_passing_tests(self):
  from quality.document_capture_evidence import audit_diagnostics
  with tempfile.TemporaryDirectory() as temp:
   p=Path(temp)/'runner.ips';p.write_text('{}')
   with self.assertRaises(ValueError):audit_diagnostics(Path(temp))
 def test_crash_attachment_payload_fails(self):
  from quality.document_capture_evidence import audit_diagnostics
  with tempfile.TemporaryDirectory() as temp:
   p=Path(temp)/'log.txt';p.write_text('Termination Reason: Namespace SIGNAL, Code 11')
   with self.assertRaises(ValueError):audit_diagnostics(Path(temp))

 def test_archived_crash_report_fails(self):
  from quality.document_capture_evidence import audit_diagnostics
  import zipfile
  with tempfile.TemporaryDirectory() as temp:
   with zipfile.ZipFile(Path(temp)/'diagnostics.zip','w') as archive:archive.writestr('runner.ips','{}')
   with self.assertRaises(ValueError):audit_diagnostics(Path(temp))

 def test_uncaught_native_exception_and_signal_exits_fail_in_plain_and_archived_logs(self):
  from quality.document_capture_evidence import audit_diagnostics
  import zipfile
  signatures=[
   'libc++abi: terminating due to uncaught exception of type std::runtime_error: failure',
   'terminate called without an active exception',
   'Process xctest exited due to signal 6',
  ]
  for signature in signatures:
   for archived in [False,True]:
    with self.subTest(signature=signature,archived=archived), tempfile.TemporaryDirectory() as temp:
     root=Path(temp)
     if archived:
      with zipfile.ZipFile(root/'diagnostics.zip','w') as archive:archive.writestr('runtime.log',signature)
     else:(root/'runtime.log').write_text(signature)
     with self.assertRaisesRegex(ValueError,'crashes or abnormal exits'):audit_diagnostics(root)
 def test_clean_process_completion_and_diagnostic_observer_are_accepted(self):
  from quality.document_capture_evidence import audit_diagnostics
  with tempfile.TemporaryDirectory() as temp:
   root=Path(temp)
   (root/'runtime.log').write_text('Registering crash report observer\nProcess xctest exited with status 0\nNo uncaught exception was reported')
   self.assertEqual(set(audit_diagnostics(root)),{'runtime.log'})

class NativeArtifactInventoryTests(unittest.TestCase):
 def setUp(self):
  spec=importlib.util.spec_from_file_location('document_native_verifier',ROOT/'document/scripts/verify_capture_bridge.py');self.verifier=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.verifier)
  self.temp=tempfile.TemporaryDirectory();self.base=Path(self.temp.name)
  receipt={'buildScriptSHA256':self.verifier.sha256(self.verifier.BUILD_SCRIPT),'compilerFlags':self.verifier.PREFIX_MAPS,'artifactFiles':{},'sourceInputs':{p.relative_to(ROOT/'document').as_posix():self.verifier.sha256(p) for p in (ROOT/'document/native/DocumentOpenCVBridge').rglob('*') if p.is_file() and p.suffix in {'.h','.hpp','.cpp','.mm'}}}
  (self.base/'build-receipt.json').write_text(json.dumps(receipt))
  self.artifact=self.base/'DocumentOpenCVBridge.xcframework';self.artifact.mkdir()
 def tearDown(self):self.temp.cleanup()
 def test_bridge_extra_unreviewed_file_fails(self):
  (self.artifact/'unreviewed-resource.txt').write_text('extra')
  with self.assertRaisesRegex(self.verifier.VerificationError,'artifact tree'):self.verifier.verify_bridge(self.base)
 def test_bridge_unregistered_symlink_fails(self):
  (self.artifact/'unreviewed').symlink_to('/tmp')
  with self.assertRaisesRegex(self.verifier.VerificationError,'symlink'):self.verifier.verify_bridge(self.base)
 def test_opencv_extra_file_fails(self):
  import subprocess
  root=self.base/'document';(root/'native').mkdir(parents=True);(root/'scripts').mkdir()
  shutil.copy(ROOT/'document/scripts/verify_capture_opencv.py',root/'scripts/verify_capture_opencv.py')
  (root/'native/opencv-normalized-manifest.json').write_text(json.dumps({'version':'4.12.0','files':{'original':{'sha256':__import__('hashlib').sha256(b'original').hexdigest()}}}))
  framework=self.base/'opencv2.xcframework';framework.mkdir();(framework/'original').write_bytes(b'original')
  passed=subprocess.run([sys.executable,str(root/'scripts/verify_capture_opencv.py'),str(framework)],capture_output=True)
  self.assertEqual(passed.returncode,0,passed.stderr)
  (framework/'unreviewed.dylib').write_bytes(b'extra')
  failed=subprocess.run([sys.executable,str(root/'scripts/verify_capture_opencv.py'),str(framework)],capture_output=True)
  self.assertNotEqual(failed.returncode,0);self.assertIn(b'entry inventory',failed.stderr)

class DocumentNativeReceiptTests(unittest.TestCase):
 def check_receipt(self,end_native):
  from unittest.mock import patch
  from types import SimpleNamespace
  from scripts import document_capture_check as runner
  with tempfile.TemporaryDirectory() as temp:
   root=Path(temp);native=root/'document/.build/native';native.mkdir(parents=True);(native/'build-receipt.json').write_text('{}')
   def run(command,**kwargs):
    if command[0]=='xcodebuild':
     build=Path(command[command.index('-derivedDataPath')+1]);binary=build/'Build/Products/Debug-iphonesimulator/AppleTests.xctest/AppleTests';binary.parent.mkdir(parents=True);binary.write_bytes(b'test executable')
    return SimpleNamespace(returncode=0)
   def output(command,**kwargs):
    if command[:2]==['git','rev-parse']:return 'revision\n'
    if command[:2]==['git','status']:return ''
    if 'xcresulttool' in command:return '{}'
    return 'toolchain\n'
   with patch('builtins.print'),patch.object(runner.platform,'platform',return_value='fixture-host'),patch.object(runner,'ROOT',root),patch.object(runner,'TARGETS',('AppleTests',)),patch.object(runner,'safe_path',lambda p:Path(p)),patch.object(runner,'required',return_value={'AppleTests.testCase'}),patch.object(runner,'sources',return_value={'source.swift':'digest'}),patch.object(runner,'native_artifacts',side_effect=[{'bridge':'before'},end_native]),patch.object(runner,'validate',return_value=['AppleTests.testCase']),patch.object(runner,'audit_diagnostics',return_value={}),patch.object(runner.subprocess,'run',side_effect=run),patch.object(runner.subprocess,'check_output',side_effect=output):
    status=runner.run('fixture-simulator')
   receipts=list((root/'.build/document-capture').glob('*/receipt.json'));self.assertEqual(len(receipts),1)
   receipt=json.loads(receipts[0].read_text())
   self.assertEqual(receipt['startNativeArtifactSHA256'],{'bridge':'before'})
   self.assertEqual(receipt['nativeArtifactSHA256'],end_native)
   return status,receipt
 def test_receipt_persists_both_equal_native_fingerprints(self):
  status,receipt=self.check_receipt({'bridge':'before'})
  self.assertEqual(status,0);self.assertTrue(receipt['passed'])
 def test_receipt_retains_both_maps_and_fails_native_drift(self):
  status,receipt=self.check_receipt({'bridge':'changed'})
  self.assertEqual(status,1);self.assertFalse(receipt['passed']);self.assertIn('Native artifacts changed',receipt['error'])
