"""Mutations exercise new-source discovery and real renderer/controller boundaries."""
import contextlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('presentation_boundaries', ROOT/'quality/presentation_guards.py')
guards = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guards)


class PresentationBoundaryTests(unittest.TestCase):
    @contextlib.contextmanager
    def checkout(self):
        with tempfile.TemporaryDirectory(prefix='kenshiki-presentation-') as folder:
            root = Path(folder)
            for name in guards.ROOTS:
                shutil.copytree(ROOT/name, root/name, ignore=shutil.ignore_patterns(*guards.PRUNE))
            (root/'governance').mkdir()
            shutil.copy2(ROOT/'governance/presentation-sources.json', root/'governance/presentation-sources.json')
            yield root

    def source(self, root, role):
        inventory = json.loads((root/'governance/presentation-sources.json').read_text())['sources']
        return root/next(name for name, value in inventory.items() if value == role)

    def test_current_checkout_has_complete_registered_boundaries(self):
        self.assertEqual(guards.check(), [])

    def test_journey_controller_and_host_keep_existing_boundaries(self):
        with self.checkout() as root:
            controller = root/'reference-apps/ios/Sources/PassportFaceJourneyController.swift'
            original = controller.read_text()
            controller.write_text(original+'\nimport UIKit\n')
            self.assertTrue(any('Controller depends on native renderer' in error for error in guards.check(root)))
            controller.write_text(original)
            host = root/'reference-apps/ios/Sources/PassportFaceJourneyHost.swift'
            host.write_text(host.read_text()+'\nlet unreviewedCopy = "A raw sentence outside the catalog"\n')
            self.assertTrue(any('Unreviewed authored string tokens' in error for error in guards.check(root)))

    def test_new_source_cannot_bypass_inventory(self):
        with self.checkout() as root:
            (root/'reference-apps/Hidden.swift').write_text('import Foundation\n')
            self.assertTrue(any('inventory mismatch' in error for error in guards.check(root)))

    def test_document_preview_new_source_is_discovered_even_outside_reference_app(self):
        with self.checkout() as root:
            path = root/guards.DOCUMENT_PREVIEW_ROOT/'Hidden.swift'
            path.write_text('import UIKit\nfinal class Hidden: UIView {}\n')
            self.assertIn(path.relative_to(root).as_posix(), guards.discover(root))
            self.assertTrue(any('inventory mismatch' in error for error in guards.check(root)))

    def test_document_preview_cannot_inherit_platform_adapter_exemption(self):
        with self.checkout() as root:
            path = root/guards.DOCUMENT_PREVIEW_ROOT/'Hidden.swift'
            path.write_text('import UIKit\nfunc hidden() { Task { } }\n')
            manifest_path = root/'governance/presentation-sources.json'
            manifest = json.loads(manifest_path.read_text())
            manifest['sources'][path.relative_to(root).as_posix()] = 'document-preview-platform-adapter'
            manifest_path.write_text(json.dumps(manifest))
            self.assertTrue(any('Unregistered document preview' in error for error in guards.check(root)))

    def test_document_preview_renderer_role_cannot_be_reclassified(self):
        with self.checkout() as root:
            path = root/'governance/presentation-sources.json'
            manifest = json.loads(path.read_text())
            name = guards.DOCUMENT_PREVIEW_ROOT+'/DocumentFrontCaptureView.swift'
            manifest['sources'][name] = 'wiring'
            path.write_text(json.dumps(manifest))
            self.assertTrue(any('Document preview presentation roles changed' in error
                                for error in guards.check(root)))

    def test_document_preview_scans_helpers_closures_and_authority(self):
        name = guards.DOCUMENT_PREVIEW_ROOT+'/DocumentFrontCaptureView.swift'
        mutations = {
            'hidden asynchronous helper': 'func hidden() { Task { save() } }',
            'action closure capture authority': 'button.action = { camera.capture() }',
            'hidden helper decision': 'func hidden() { if ready { emit(.capture) } }',
            'action closure decision': 'button.action = { if ready { emit(.capture) } }',
            'dispatch hidden in permitted visual branch': 'if state.busy { emit(.capture) }',
            'dispatch hidden in permitted tone switch': 'switch state.tone { case .neutral: emit(.cancel) }',
            'capture ownership': 'let session: CaptureSession',
            'canonical capture controller ownership': 'let controller: DocumentFrontCaptureController',
            'sensor ownership': 'let motion: DocumentLevelMotionSource',
            'level calculation in renderer': 'let level = hypot(gravity.x, gravity.y)',
            'clock-dependent renderer': 'let now = Date()',
            'hidden network': 'func hidden() { URLSession.shared.resume() }',
            'reflection escape': 'import ObjectiveC\nlet selector = Selector(action)',
        }
        for label, mutation in mutations.items():
            with self.subTest(label=label):
                errors = []
                guards.check_document_preview(name, mutation, 'document-preview-renderer', errors)
                self.assertTrue(errors, label)

    def test_document_preview_allows_only_unconditional_typed_action_forwarding(self):
        name = guards.DOCUMENT_PREVIEW_ROOT+'/DocumentFrontCaptureView.swift'
        source = ('import UIKit\nimport DocumentCaptureApple\n'
                  'button.isEnabled = state.captureEnabled\n'
                  'label.text = state.status\n'
                  '@objc private func captureTapped() { emit(.capture) }\n'
                  '@objc private func cancelTapped() { emit(.cancel) }')
        errors = []
        guards.check_document_preview(name, source, 'document-preview-renderer', errors)
        self.assertEqual(errors, [])

    def test_document_level_mapper_can_calculate_supplied_sample_but_cannot_subscribe(self):
        name = guards.DOCUMENT_PREVIEW_ROOT+'/DocumentLevelPresentation.swift'
        source = 'let magnitude = hypot(sample.gravity.x, sample.gravity.y)\n'
        errors = []
        guards.check_document_preview(name, source, 'document-preview-mapper', errors)
        self.assertEqual(errors, [])
        for mutation in ('let motion = DocumentLevelMotionSource()', 'motion.start()',
                         'let time = ProcessInfo.processInfo.systemUptime',
                         'let subscription = updates.sink { value in consume(value) }'):
            with self.subTest(mutation=mutation):
                errors = []
                guards.check_document_preview(name, source+mutation, 'document-preview-mapper', errors)
                self.assertTrue(errors)

    def test_document_preview_contracts_cannot_own_mutable_or_derived_availability(self):
        name = guards.DOCUMENT_PREVIEW_ROOT+'/DocumentFrontCaptureState.swift'
        for mutation in ('public var canCapture = false',
                         'var canCapture: Bool { if ready { return true }; return false }'):
            with self.subTest(mutation=mutation):
                errors = []
                guards.check_document_preview(name, mutation, 'document-preview-state', errors)
                self.assertTrue(any('Mutable or derived' in error for error in errors))

    def test_document_preview_style_cannot_create_an_independent_design_system(self):
        name = guards.DOCUMENT_PREVIEW_ROOT+'/DocumentFrontCaptureStyle.swift'
        for mutation in ('let color = UIColor(red: 0.4, green: 0.2, blue: 0.1, alpha: 1)',
                         'let font = UIFont.systemFont(ofSize: 12)'):
            with self.subTest(mutation=mutation):
                errors = []
                guards.check_document_preview(name, mutation, 'document-preview-style', errors)
                self.assertTrue(any('host design tokens' in error for error in errors))

    def test_document_renderer_allows_only_native_surface_identity_reconciliation(self):
        name = 'reference-apps/ios/Sources/DocumentFlowRenderer.swift'
        source = ('if mountedCaptureSurface !== screen.captureSurface {\n}\n'
                  'if let surface = screen.captureSurface {\n install(surface)\n}\n'
                  'captureRegion.isHidden = screen.captureSurface == nil\n'
                  'content.superview?.isHidden = screen.captureSurface != nil\n'
                  'primaryRegion.isHidden = screen.captureSurface != nil')
        errors = []
        guards.check_native_document_renderer(name, source, errors)
        self.assertEqual(errors, [])
        for mutation in ('if ready { emit(.capture) }',
                         'if mountedPreview !== controller.preview {',
                         'captureRegion.isHidden = controller.captureAllowed != nil'):
            with self.subTest(mutation=mutation):
                errors = []
                guards.check_native_document_renderer(name, source+'\n'+mutation, errors)
                self.assertTrue(errors)

    def test_native_document_adapter_can_only_read_platform_permission_status(self):
        name = 'reference-apps/ios/Sources/NativeDocumentFlowCamera.swift'
        source = 'import AVFoundation\nlet value = AVCaptureDevice.authorizationStatus(for: .video)'
        errors = []
        guards.check_authored_source(name, source, {}, errors)
        self.assertEqual(errors, [])
        for mutation in ('AVCaptureDevice.requestAccess(for: .video)',
                         'let engine = AVCaptureSession()', 'let camera = AVCaptureDevice.default(for: .video)'):
            with self.subTest(mutation=mutation):
                errors = []
                guards.check_authored_source(name, source+'\n'+mutation, {}, errors)
                self.assertTrue(any('SDK owns acquisition' in error for error in errors))

    def test_encrypted_storage_dependencies_cannot_enter_renderers(self):
        for module in ('SQLCipher', 'KenshikiProtectedStorage'):
            with self.subTest(module=module), self.checkout() as root:
                path = self.source(root, 'renderer')
                path.write_text(path.read_text()+'\nimport '+module+'\n')
                self.assertTrue(any('Forbidden presentation dependency' in error for error in guards.check(root)))

    def test_production_checkpoint_cannot_use_synthetic_key_custody(self):
        with self.checkout() as root:
            path = root/'reference-apps/ios/Sources/PassportCaptureStore.swift'
            path.write_text(path.read_text()+'\nlet bad = ProtectedSQLiteStore.testing(databaseURL: url, identity: identity, key: key)\n')
            self.assertTrue(any('Synthetic key custody' in error for error in guards.check(root)))

    def test_document_store_is_the_only_new_sql_adapter_and_cannot_use_test_custody(self):
        name = 'reference-apps/ios/Sources/DocumentFlowSQLiteStore.swift'
        errors = []
        guards.check_authored_source(name, 'import SQLCipher\n@_spi(StorageAdapter) import KenshikiProtectedStorage', {}, errors)
        self.assertEqual(errors, [])
        for mutation in ('let bad = ProtectedSQLiteStore.testing(databaseURL: url, identity: identity, key: key)',
                         'import CryptoKit', 'import SQLite3'):
            with self.subTest(mutation=mutation):
                errors = []
                guards.check_authored_source(name, mutation, {}, errors)
                self.assertTrue(errors)
        errors = []
        guards.check_authored_source('reference-apps/ios/Sources/DocumentFlowController.swift', 'import SQLCipher', {}, errors)
        self.assertTrue(any('Forbidden presentation dependency' in error for error in errors))

    def test_document_store_cannot_be_reclassified_to_bypass_production_scan(self):
        with self.checkout() as root:
            path = root/'governance/presentation-sources.json'
            manifest = json.loads(path.read_text())
            manifest['sources']['reference-apps/ios/Sources/DocumentFlowSQLiteStore.swift'] = 'test'
            path.write_text(json.dumps(manifest))
            self.assertTrue(any('Document presentation roles changed' in error for error in guards.check(root)))

    def test_ignoring_compiler_metadata_does_not_hide_native_source_from_guards(self):
        with self.checkout() as root:
            folder = root/'reference-apps/android/.kotlin'
            folder.mkdir(parents=True, exist_ok=True)
            (folder/'Hidden.kt').write_text('class Hidden')
            self.assertTrue(any('inventory mismatch' in error for error in guards.check(root)))
            path = root/'governance/presentation-sources.json'
            inventory = json.loads(path.read_text())
            inventory['sources']['reference-apps/android/.kotlin/Hidden.kt'] = 'controller'
            path.write_text(json.dumps(inventory))
            self.assertTrue(any('Native source in compiler cache' in error for error in guards.check(root)))

    def test_source_symlink_and_ancestor_symlink_are_rejected(self):
        for ancestor in (False, True):
            with self.subTest(ancestor=ancestor), self.checkout() as root, tempfile.TemporaryDirectory() as outside:
                path = self.source(root, 'renderer')
                if ancestor:
                    source = path.parent
                    destination = Path(outside)/'redirected'
                    shutil.move(str(source), destination)
                    source.symlink_to(destination, target_is_directory=True)
                else:
                    destination = Path(outside)/path.name
                    shutil.move(str(path), destination)
                    path.symlink_to(destination)
                self.assertTrue(any('source symlink' in error for error in guards.check(root)))

    def test_renderer_mutations_are_rejected_including_helpers(self):
        mutations = {
            'clipboard export': ('\nlet clipboard = UIPasteboard.general\n', 'Behavior inside native renderer'),
            'network import': ('\nimport Network\n', 'Forbidden presentation dependency'),
            'hidden async helper': ('\nfunc hidden() { Task { } }\n', 'Behavior inside native renderer'),
            'hidden controller': ('\nlet controller = WorkflowController()\n', 'Behavior inside native renderer'),
            'liquid inference': ('\nlet assessor = LiquidFaceAssessment()\n', 'Inference inside native renderer'),
            'visual assessment import': ('\nimport BiometricVisualAssessment\n', 'Inference inside native renderer'),
            'mlx runtime import': ('\nimport MLXVLM\n', 'Inference inside native renderer'),
            'guided generation import': ('\nimport MLXGuidedGeneration\n', 'Inference inside native renderer'),
            'motion sensor import': ('\nimport CoreMotion\n', 'Forbidden presentation dependency'),
            'motion witness': ('\nlet witness = PulseCeremonyMotionWitness()\n', 'Inference inside native renderer'),
            'compose effect': ('\nLaunchedEffect(key) { work() }\n', 'Workflow state or effect'),
            'compose state': ('\nval ready = mutableStateOf(false)\n', 'Workflow state or effect'),
            'visible string': ('\nlet injected = Text("raw copy")\n', 'Raw authored text'),
            'compose named copy': ('\nText(text = "raw copy")\n', 'Raw authored text'),
            'compose semantics copy': ('\nModifier.semantics { stateDescription = "raw status" }\n', 'Raw authored text'),
            'accessibility string': ('\nlabel.accessibilityHint = "raw hint"\n', 'Raw authored text'),
            'literal style': ('\nlet injected = Color(red: 0.4)\n', 'Inline design literal'),
            'lifecycle effect': ('\nview.onAppear { injected() }\n', 'Workflow lifecycle hook'),
            'hidden decision': ('\nfunc hidden() { if valid { accept() } }\n', 'Decision or workflow dispatch'),
            'derived ternary': ('\nlet title = valid ? state.ok : state.error\n', 'Derived decision'),
            'aliased authored copy': ('\nlet caption = "raw authored copy"; label.text = caption\n', 'Unreviewed authored string'),
            'multiline authored copy': ('\nlet caption = """raw copy"""\n', 'Unreviewed multiline/raw string'),
        }
        for label, (mutation, expected) in mutations.items():
            with self.subTest(label=label), self.checkout() as root:
                path = self.source(root, 'renderer')
                path.write_text(path.read_text()+mutation)
                self.assertTrue(any(expected in error for error in guards.check(root)), label)

    def test_reference_portrait_renderer_allows_only_host_prepared_optional_image(self):
        name = 'reference-apps/ios/Sources/ReferenceRenderer.swift'
        source = 'if let image = screen.image {\n imageView.image = image\n}'
        errors = []
        guards.check_renderer(name, source, errors)
        self.assertEqual(errors, [])
        for mutation in ('if accepted { accept() }', 'Task { decodePortrait() }',
                         'let portrait = ready ? reference : selfie', 'if let image = controller.image {'):
            with self.subTest(mutation=mutation):
                errors = []
                guards.check_renderer(name, source+'\n'+mutation, errors)
                self.assertTrue(errors)
        errors = []
        guards.check_renderer('unregistered.swift', source, errors)
        self.assertTrue(errors)

    def test_document_renderer_rejects_sdk_imports_authority_effects_and_decisions(self):
        mutations = ('import DocumentCaptureApple', 'let controller: DocumentFlowController',
                     'let observation: DocumentFlowObservation', 'let side: DocumentSide',
                     'func helper() { Task { capture() } }', 'controller.capture()',
                     'let digest = SHA256.hash(data: bytes)', 'if state.phase == .ready { accept() }',
                     'for item in controller.items {', 'let title = ready ? yes : no',
                     'let selected = screen.items.filter { allowed($0) }')
        name='reference-apps/ios/Sources/DocumentFlowRenderer.swift'
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                errors=[];guards.check_native_document_renderer(name,mutation,errors)
                self.assertTrue(errors)
        errors=[];guards.check_native_document_renderer('unregistered.swift','',errors)
        self.assertTrue(errors)

    def test_document_renderer_accepts_only_supplied_media_layout(self):
        source='guard isViewLoaded else { return }\nif let preview = screen.preview {\n}\nfor item in screen.items {\nif let image = item.image {\n}\n}'
        errors=[];guards.check_native_document_renderer('reference-apps/ios/Sources/DocumentFlowRenderer.swift',source,errors)
        self.assertEqual(errors,[])

    def test_document_host_hash_import_does_not_exempt_other_wiring(self):
        manifest={'technicalStrings':{}}
        errors=[];guards.check_authored_source('reference-apps/ios/Sources/DocumentFlowHost.swift','import CryptoKit',manifest,errors)
        self.assertEqual(errors,[])
        errors=[];guards.check_authored_source('reference-apps/ios/Sources/UnexpectedHost.swift','import CryptoKit',manifest,errors)
        self.assertTrue(any('Forbidden presentation dependency' in error for error in errors))

    def test_document_host_can_read_video_permission_status_but_cannot_own_camera_or_permission_request(self):
        name='reference-apps/ios/Sources/DocumentFlowHost.swift'
        source='import AVFoundation\nlet pending = AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined'
        errors=[];guards.check_authored_source(name,source,{'technicalStrings':{}},errors)
        self.assertEqual(errors,[])
        mutations=('let session = AVCaptureSession()', 'let photo = AVCapturePhotoOutput()',
                   'AVCaptureDevice.requestAccess(for: .video) { _ in }',
                   'let device = AVCaptureDevice.default(for: .video)',
                   'let discovery = AVCaptureDevice.DiscoverySession()',
                   'typealias RawCamera = AVCaptureDevice',
                   'let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)')
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                errors=[];guards.check_authored_source(name,source+'\n'+mutation,{'technicalStrings':{}},errors)
                self.assertTrue(any('SDK owns acquisition' in error for error in errors))
        errors=[];guards.check_authored_source('reference-apps/ios/Sources/UnexpectedHost.swift',source,{'technicalStrings':{}},errors)
        self.assertTrue(any('Forbidden presentation dependency' in error for error in errors))

    def test_storage_diagnostics_imports_are_debug_only_and_error_classification_only(self):
        name='reference-apps/ios/Sources/StorageHealthDiagnostics.swift'
        source='#if DEBUG\nimport CryptoKit\nimport KenshikiProtectedStorage\nlet error: ProtectedSQLiteError?\n#endif'
        errors=[];guards.check_authored_source(name,source,{'technicalStrings':{}},errors)
        self.assertEqual(errors,[])
        mutations=(source.replace('#if DEBUG','#if !DEBUG'),
                   source+'\nfunc releaseExport() {}',
                   source.replace('let error:', '#else\nlet error:'),
                   source.replace('let error:', '#endif\nlet error:')+'\n#if DEBUG\n#endif',
                   source.replace('ProtectedSQLiteError','ProtectedSQLiteStore'),
                   source.replace('let error:', 'let key = SymmetricKey(size: .bits256)\nlet error:'))
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                errors=[];guards.check_authored_source(name,mutation,{'technicalStrings':{}},errors)
                self.assertTrue(errors)
        errors=[];guards.check_authored_source('reference-apps/ios/Sources/OtherDiagnostics.swift',source,{'technicalStrings':{}},errors)
        self.assertTrue(any('Forbidden presentation dependency' in error for error in errors))

    def test_native_capture_surface_rejects_effects_authority_and_unreviewed_decisions(self):
        mutations = (
            'import BiometricCapture', 'import ARKit', 'func helper() { Task { work() } }',
            'let session = NativeSelfieSession()', 'if state.phase == .captured { accept() }',
            'driver.setConsent(.permitted)', 'let result = ready ? success : failure',
            'label.text = "raw capture copy"', 'let style = Color(red: 0.5)',
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation), self.checkout() as root:
                path = root/'reference-apps/ios/Sources/BiometricCaptureRenderer.swift'
                path.write_text(path.read_text()+'\n'+mutation+'\n')
                self.assertTrue(guards.check(root))
        errors = []
        guards.check_native_capture_renderer('unregistered.swift', '', errors)
        self.assertTrue(errors)

    def test_native_capture_renderer_cannot_own_or_deliver_accepted_evidence(self):
        for mutation in ('let engine = AuraFaceComparison()', 'let visual = LiquidFaceAssessment()', 'let compare = FaceComparisonController()', 'import BiometricInference', 'import BiometricVisualAssessment', 'let payload: AcceptedSelfie?', 'let holder = AcceptedSelfieHandoff()',
                         'controller.useSelfie()', 'controller.onAccepted = consume',
                         'let evidence = controller.capturedEvidence'):
            with self.subTest(mutation=mutation):
                errors = []
                guards.check_native_capture_renderer(
                    'reference-apps/ios/Sources/BiometricCaptureRenderer.swift', mutation, errors)
                self.assertTrue(any('Capture authority' in error for error in errors))

    def test_retired_swift_demo_cannot_restore_runtime_capability_coupling(self):
        mutations = (
            ('presentation/Package.swift', '\nlet dependency = .package(path: "../biometric")',
             'Swift presentation must remain independent'),
            ('presentation/Sources/KenshikiPresentation/Workflow.swift', '\nimport BiometricSDK',
             'Retired synthetic biometric runtime'),
            ('presentation/Sources/KenshikiPresentation/Workflow.swift', '\nimport BiometricVisualAssessment',
             'Retired synthetic biometric runtime'),
            ('presentation/Sources/KenshikiPresentation/Workflow.swift', '\nclass SyntheticBiometricEngine {}',
             'Retired synthetic biometric runtime'),
        )
        for name, mutation, expected in mutations:
            with self.subTest(name=name, mutation=mutation), self.checkout() as root:
                path = root/name
                path.write_text(path.read_text()+mutation)
                errors = []
                guards.check_biometric_composition(root, errors)
                self.assertTrue(any(expected in error for error in errors))

    def test_native_passport_renderer_rejects_protocol_and_workflow_authority(self):
        mutations = (
            'import PassportSDK', 'import PassportNFC', 'import CoreNFC',
            'let controller = PassportFlowController()', 'let key = PassportAccessKey()',
            'func helper() { Task { read() } }', 'if valid { accept() }',
            'let key = PassportMRZOCRParser.parse(candidates: input)',
            'controller.setConsent(.permitted)', 'let result = ready ? success : failure',
            'label.text = "raw passport copy"', 'let style = Color(red: 0.5)',
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                errors = []
                guards.check_native_passport_renderer(
                    'reference-apps/ios/Sources/PassportFlowRenderer.swift', mutation, errors)
                if 'raw passport copy' in mutation:
                    self.assertTrue(any(rule.search(mutation) for rule in guards.RAW_SINKS))
                else:
                    self.assertTrue(errors)
        errors = []
        guards.check_native_passport_renderer('unregistered.swift', '', errors)
        self.assertTrue(errors)

    def test_passport_renderer_cannot_be_reclassified_to_bypass_purity(self):
        with self.checkout() as root:
            path = root/'governance/presentation-sources.json'
            manifest = json.loads(path.read_text())
            manifest['sources']['reference-apps/ios/Sources/PassportFlowRenderer.swift'] = 'wiring'
            path.write_text(json.dumps(manifest))
            self.assertTrue(any('Passport presentation roles changed' in error for error in guards.check(root)))

    def test_native_passport_renderer_allows_only_supplied_optional_media(self):
        errors = []
        source = ('guard isViewLoaded else { return }\n'
                  'if let preview = screen.preview {\n install(preview)\n}\n'
                  'if let image = screen.image {\n imageView.image = image\n}')
        guards.check_native_passport_renderer(
            'reference-apps/ios/Sources/PassportFlowRenderer.swift', source, errors)
        self.assertEqual(errors, [])

    def test_issuer_trust_provisioning_cannot_become_a_holder_file_picker(self):
        name = 'reference-apps/ios/Sources/PassportFlowHost.swift'
        for mutation in ('let picker = UIDocumentPickerViewController()',
                         'class Picker: UIDocumentPickerDelegate {}',
                         'import UniformTypeIdentifiers', 'source.startAccessingSecurityScopedResource()',
                         'let key = "passport.trust.import"'):
            with self.subTest(mutation=mutation):
                errors = []
                manifest = {'technicalStrings': {name: sorted(set(guards.QUOTED.findall(mutation)))}}
                guards.check_authored_source(name, mutation, manifest, errors)
                self.assertTrue(any('Issuer trust provisioning' in error for error in errors))

    def test_native_reference_cannot_redirect_or_expand_passport_dependencies(self):
        for before, after in (('../../passport', '../../../kenshiki-identity-sdk'),
                              ('product: PassportNFC', 'product: HiddenRuntime'),
                              ('product: PassportSDK', 'product: PassportSDK\n      - package: HiddenRuntime')):
            with self.subTest(after=after), self.checkout() as root:
                path = root/'reference-apps/ios/project.yml'
                source = path.read_text()
                self.assertIn(before, source)
                path.write_text(source.replace(before, after))
                errors = []
                guards.check_passport_composition(root, errors)
                self.assertTrue(errors)

    def test_public_issuer_trust_build_step_cannot_be_disabled_or_redirected(self):
        for before, after in (('provision_reference_trust.py', 'unreviewed_trust.py'),
                              ('basedOnDependencyAnalysis: false', 'basedOnDependencyAnalysis: true'),
                              ('--output "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"', '--output /tmp/unreviewed')):
            with self.subTest(after=after), self.checkout() as root:
                path = root/'reference-apps/ios/project.yml'
                source = path.read_text()
                self.assertIn(before, source)
                path.write_text(source.replace(before, after))
                errors = []
                guards.check_passport_composition(root, errors)
                self.assertTrue(any('public trust build provisioning' in error for error in errors))

    def test_native_passport_nfc_entitlements_cannot_expand_or_redirect(self):
        for name, before, after in (
                ('KenshikiReference.entitlements', '<string>TAG</string>', '<string>NDEF</string>'),
                ('project.yml', 'CODE_SIGN_ENTITLEMENTS: KenshikiReference.entitlements', 'CODE_SIGN_ENTITLEMENTS: ../Hidden.entitlements'),
                ('project.yml', 'A0000002471001', 'A0000000000000')):
            with self.subTest(name=name, after=after), self.checkout() as root:
                path = root/'reference-apps/ios'/name
                path.write_text(path.read_text().replace(before, after))
                errors = []
                guards.check_passport_composition(root, errors)
                self.assertTrue(any('NFC' in error for error in errors))

    def test_passport_server_configuration_and_production_attestation_cannot_drift(self):
        for name, before, after in (
                ('project.yml', 'https://id.kenshikilabs.com', 'https://unreviewed.example'),
                ('project.yml', 'PulsePassportApplicationIdentifier: "com.kenshiki.reference"', 'PulsePassportApplicationIdentifier: "com.credit.kenshikidevice"'),
                ('project.yml', 'PulsePassportApplicationIdentifier: "com.kenshiki.reference"', 'PulsePassportApplicationIdentifier: "4D9FAKD487.com.kenshiki.reference"'),
                ('project.yml', 'PulsePassportAppAttestEnvironment: "production"', 'PulsePassportAppAttestEnvironment: "development"'),
                ('KenshikiReference.entitlements', '<string>production</string>', '<string>development</string>'),
                ('project.yml', 'product: KenshikiOperationBinding', 'product: UnreviewedBinding'),
                ('project.yml', 'product: KenshikiPulsePassport', 'product: UnreviewedPulse')):
            with self.subTest(name=name, after=after), self.checkout() as root:
                path = root/'reference-apps/ios'/name
                source = path.read_text()
                self.assertIn(before, source)
                path.write_text(source.replace(before, after))
                errors = []
                guards.check_passport_composition(root, errors)
                self.assertTrue(errors)

    def test_controller_cannot_import_native_view(self):
        for dependency in ('SwiftUI', 'androidx.compose.material3.Text'):
            with self.subTest(dependency=dependency), self.checkout() as root:
                path = self.source(root, 'controller')
                path.write_text(path.read_text()+'\nimport '+dependency+'\n')
                self.assertTrue(any('Controller depends' in error for error in guards.check(root)))

    def test_platform_container_allows_native_layout_but_rejects_workflow_ownership(self):
        errors = []
        guards.check_platform_container('NativePageContainer.swift',
                                        'if #available(iOS 26.0, *) { button.configuration = .glass() }', errors)
        self.assertEqual(errors, [])
        for source in ('let controller = WorkflowController()',
                       'if state.phase == .ready { callback() }',
                       'func helper() { Task { callback() } }',
                       'let event = ReferenceEvent.home',
                       'LaunchedEffect(key) { callback() }',
                       'let injected = Color(red: 0.4)'):
            with self.subTest(source=source):
                errors = []
                guards.check_platform_container('NativePageContainer.swift', source, errors)
                self.assertTrue(errors)

    def test_display_strings_cannot_hide_as_comments_or_in_new_helpers(self):
        source = '// label.text = "comment"\nlabel.text = "https://example.test/raw copy"\n'
        cleaned = guards.without_comments(source)
        self.assertNotIn('comment', cleaned)
        self.assertTrue(any(rule.search(cleaned) for rule in guards.RAW_SINKS))

    def test_unmanaged_resources_and_permissions_fail(self):
        with self.checkout() as root:
            folder = root/'reference-apps/android/app/src/main/res/values'
            folder.mkdir(parents=True, exist_ok=True)
            (folder/'strings.xml').write_text('<resources><string name="raw">raw copy</string></resources>')
            self.assertTrue(any('Unmanaged native resource' in error for error in guards.check(root)))

    def test_missing_dependency_verification_fails(self):
        with self.checkout() as root:
            (root/'reference-apps/android/gradle/verification-metadata.xml').unlink()
            self.assertTrue(any('verification metadata missing' in error for error in guards.check(root)))

    def test_cleartext_traffic_cannot_be_enabled_or_left_implicit(self):
        for replacement in ('', 'android:usesCleartextTraffic="true"'):
            with self.subTest(replacement=replacement), self.checkout() as root:
                path = root/'reference-apps/android/app/src/main/AndroidManifest.xml'
                path.write_text(path.read_text().replace('android:usesCleartextTraffic="false"', replacement))
                self.assertTrue(any('explicitly disable cleartext' in error for error in guards.check(root)))

    def test_cli_rejects_unregistered_lane(self):
        spec = importlib.util.spec_from_file_location('presentation_runner', ROOT/'scripts/presentation_check.py')
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        with self.assertRaises(ValueError):
            runner.commands('../../outside')

    def test_native_accessibility_matrix_covers_all_current_a_aa_criteria(self):
        matrix = (ROOT/'reference-apps/WCAG-MATRIX.md').read_text()
        rows = re.findall(r'^\| \[(\d\.\d\.\d+) [^\n]+?\| (AA|A) \|', matrix, re.MULTILINE)
        self.assertEqual(len(rows), 55)
        self.assertEqual(len({criterion for criterion, _ in rows}), 55)
        self.assertEqual(sum(level == 'A' for _, level in rows), 31)
        self.assertEqual(sum(level == 'AA' for _, level in rows), 24)
        self.assertNotIn('4.1.1', {criterion for criterion, _ in rows})


if __name__ == '__main__':
    unittest.main()
