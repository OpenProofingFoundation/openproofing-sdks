"""Source inventory and presentation boundaries; native execution is a separate gate."""
import json
import os
import plistlib
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
DOCUMENT_PREVIEW_ROOT = 'document/ios/Sources/DocumentCapturePreview'
ROOTS = ('presentation', 'design-system', 'reference-apps', DOCUMENT_PREVIEW_ROOT)
PRUNE = {'.build', '.gradle', 'build', '__pycache__', '.swiftpm', 'DerivedData', 'node_modules'}
NATIVE = {'.swift', '.kt', '.java', '.m', '.mm', '.c', '.cpp', '.h'}
DOCUMENT_PREVIEW_ROLES = {
    DOCUMENT_PREVIEW_ROOT+'/DocumentCameraPreviewView.swift': 'document-preview-platform-adapter',
    DOCUMENT_PREVIEW_ROOT+'/DocumentTiltPresentationCopy.swift': 'document-preview-mapper',
    DOCUMENT_PREVIEW_ROOT+'/DocumentFrontCaptureView.swift': 'document-preview-renderer',
    DOCUMENT_PREVIEW_ROOT+'/DocumentFrontCaptureLevelView.swift': 'document-preview-renderer',
    DOCUMENT_PREVIEW_ROOT+'/DocumentFrontCaptureState.swift': 'document-preview-state',
    DOCUMENT_PREVIEW_ROOT+'/DocumentFrontCaptureStyle.swift': 'document-preview-style',
    DOCUMENT_PREVIEW_ROOT+'/DocumentLevelPresentation.swift': 'document-preview-mapper',
}
ROLES = {'manifest', 'controller', 'renderer', 'platform-container', 'native-capture-renderer', 'native-passport-renderer', 'native-document-renderer', 'wiring', 'generated', 'test'} | set(DOCUMENT_PREVIEW_ROLES.values())
FORBIDDEN_IMPORTS = re.compile(r'\b(?:import\s+(?:SQLite3|SQLCipher|KenshikiProtectedStorage|Security|CryptoKit|CoreML|CoreMotion|Vision|AVFoundation|Network)|(?:java|javax)\.(?:net|sql)|android\.(?:database|hardware)|okhttp|retrofit)\b')
RENDERER_BEHAVIOR = re.compile(r'\b(?:URLSession|URLRequest|Task|DispatchQueue|Timer|Thread|FileManager|UserDefaults|UIPasteboard|JSONDecoder|JSONEncoder|WorkflowController|StubEngine|SQLite|evaluate|compareFaces|runInference|CoroutineScope|GlobalScope|launch|async|suspend)\b')
INFERENCE_BEHAVIOR = re.compile(r'\b(?:AuraFaceComparison|OFIQFaceQuality|FaceCaptureSelectionProcessor|FaceCaptureSelection|BiometricQuality|LiquidFaceAssessment|FaceComparisonController|BiometricInference|BiometricVisualAssessment|MLXVLM|MLXLMCommon|MLXGuidedGeneration|PulseCeremonyMotionWitness)\b')
COMPOSE_EFFECTS = re.compile(r'\b(?:LaunchedEffect|DisposableEffect|SideEffect|produceState|rememberCoroutineScope|rememberSaveable|mutableStateOf|derivedStateOf)\b')
WORKFLOW_OWNERSHIP = re.compile(r'\b(?:Workflow\w*|Capability|StubEngine|OperationRequest|CompletionToken|ReferenceEvent|KenshikiPresentation)\b|\.(?:phase|outcome|stepIndex|send|complete|retry|advance)\b')
RAW_SINKS = (
    re.compile(r'\b(?:Text|Button|Label|NSLocalizedString)\s*\(\s*"[^"\n]+"'),
    re.compile(r'\.(?:text|title|hint|contentDescription|accessibilityLabel|accessibilityHint|accessibilityValue)\s*=\s*"[^"\n]+"'),
    re.compile(r'\b(?:setText|setTitle|setContentDescription|accessibilityLabel|accessibilityHint)\s*\(\s*"[^"\n]+"'),
    re.compile(r'\b(?:text|contentDescription|stateDescription|paneTitle)\s*=\s*"[^"\n]+"'),
)
INLINE_STYLE = (
    re.compile(r'\b(?:UIColor|Color)\s*\(\s*(?:red\s*:|0x|#)'),
    re.compile(r'\b(?:setTextSize|setBackgroundColor)\s*\(\s*\d'),
    re.compile(r'\.(?:font|padding|cornerRadius)\s*\(\s*\d'),
)
INLINE_DESIGN_FAILURE = 'Inline design literal: '
CAPTURE_AUTHORITY = (
    re.compile(r'\b(?:AuraFaceComparison|OFIQFaceQuality|FaceCaptureSelectionProcessor|FaceCaptureSelection|BiometricQuality|LiquidFaceAssessment|FaceComparisonController|BiometricCaptureDriver|BiometricCaptureController|NativeSelfieSession|SelfiePixelBridge|PortraitPixels|AcceptedSelfie(?:Handoff)?|Workflow\w*|Capability)\b'),
    re.compile(r'\bimport\s+(?:Biometric\w*|ARKit)\b'),
    re.compile(r'\.(?:phase|snapshot|capture|setConsent|setActive|stop|retry|allow|shutter|useSelfie|onAccepted|capturedEvidence)\b'),
)
QUOTED = re.compile(r'"(?:\\.|[^"\\])*"')


def without_comments(source):
    """Keep quoted strings intact so display sinks cannot hide in an allowlisted file."""
    tokens = re.compile(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/')
    return tokens.sub(lambda match: match[0] if match[0].startswith('"') else '\n' * match[0].count('\n'), source)


def source_files(root, errors):
    for name in ROOTS:
        folder = root/name
        if folder.is_symlink():
            errors.append('Presentation source symlink: '+name)
            continue
        yield from folder_files(folder, root, errors)


def folder_files(folder, root, errors):
    for current, dirs, files in os.walk(folder, followlinks=False):
        for entry in dirs+files:
            path = Path(current)/entry
            if path.is_symlink():
                errors.append('Presentation source symlink: '+path.relative_to(root).as_posix())
        dirs[:] = sorted(name for name in dirs if name not in PRUNE and not (Path(current)/name).is_symlink())
        for entry in sorted(files):
            path = Path(current)/entry
            if not path.is_symlink():
                yield path


def discover(root, errors=None):
    paths = set()
    for path in source_files(root, errors if errors is not None else []):
        if path.suffix in NATIVE:
            paths.add(path.relative_to(root).as_posix())
    return paths


def check(root=ROOT):
    errors = []
    manifest = json.loads((root/'governance/presentation-sources.json').read_text())
    inventory = manifest['sources']
    passport_roles = {
        'reference-apps/ios/Sources/PassportFlowController.swift': 'controller',
        'reference-apps/ios/Sources/PassportFlowHost.swift': 'wiring',
        'reference-apps/ios/Sources/PassportFlowRenderer.swift': 'native-passport-renderer',
        'reference-apps/ios/ControllerTests/PassportFlowControllerTests.swift': 'test',
    }
    if any(inventory.get(name) != role for name, role in passport_roles.items()):
        errors.append('Passport presentation roles changed')
    document_roles = {
        'reference-apps/ios/Sources/DocumentFlowController.swift': 'controller',
        'reference-apps/ios/Sources/DocumentFlowPersistence.swift': 'controller',
        'reference-apps/ios/Sources/DocumentFlowCaptureMetadata.swift': 'wiring',
        'reference-apps/ios/Sources/DocumentFlowSQLiteStore.swift': 'wiring',
        'reference-apps/ios/ControllerTests/DocumentFlowPersistenceTests.swift': 'test',
        'reference-apps/ios/ControllerTests/DocumentFlowSQLiteStoreTests.swift': 'test',
        'reference-apps/ios/Sources/DocumentFlowHost.swift': 'wiring',
        'reference-apps/ios/Sources/DocumentFlowRenderer.swift': 'native-document-renderer',
        'reference-apps/ios/Sources/NativeDocumentFlowCamera.swift': 'wiring',
        'reference-apps/ios/Sources/DocumentFrontCapturePresentation.swift': 'wiring',
        'reference-apps/ios/ControllerTests/DocumentFlowControllerTests.swift': 'test',
        'reference-apps/ios/ControllerTests/DocumentFlowHostLifecycleTests.swift': 'test',
        'reference-apps/ios/ControllerTests/DocumentFlowRendererTests.swift': 'test',
    }
    if any(inventory.get(name) != role for name, role in document_roles.items()):
        errors.append('Document presentation roles changed')
    if (inventory.get('reference-apps/ios/Sources/StorageHealthDiagnostics.swift') != 'wiring'
            or inventory.get('reference-apps/ios/ControllerTests/StorageHealthTests.swift') != 'test'):
        errors.append('Storage diagnostics presentation roles changed')
    if manifest.get('schemaVersion') != 1:
        errors.append('Unsupported presentation inventory schema')
    for name, role in DOCUMENT_PREVIEW_ROLES.items():
        if inventory.get(name) != role:
            errors.append('Document preview presentation roles changed: '+name)
    for name, role in inventory.items():
        if name.startswith(DOCUMENT_PREVIEW_ROOT+'/'):
            if DOCUMENT_PREVIEW_ROLES.get(name) != role:
                errors.append('Unregistered document preview source or changed role: '+name)
    actual = discover(root, errors)
    if actual != set(inventory):
        errors.append('Presentation source inventory mismatch: '+str(sorted(actual ^ set(inventory))))
    for name, role in inventory.items():
        if role not in ROLES or name not in actual:
            errors.append('Invalid presentation classification: '+name)
            continue
        check_source(root, name, role, manifest, errors)
    check_resources(root, errors)
    check_gradle_verification(root, errors)
    check_biometric_composition(root, errors)
    check_passport_composition(root, errors)
    return errors


def check_source(root, name, role, manifest, errors):
    if '.kotlin' in Path(name).parts:
        errors.append('Native source in compiler cache: '+name)
    source = without_comments((root/name).read_text())
    if role in {'controller', 'renderer', 'platform-container', 'native-capture-renderer', 'native-passport-renderer', 'native-document-renderer', 'wiring'}:
        check_authored_source(name, source, manifest, errors)
    if role == 'controller' and re.search(r'\b(?:import\s+(?:UIKit|SwiftUI)|android\.view|android\.widget|androidx\.compose)\b', source):
        errors.append('Controller depends on native renderer: '+name)
    if role == 'renderer':
        check_renderer(name, source, errors)
    if role == 'native-document-renderer':
        check_native_document_renderer(name, source, errors)
    if role == 'native-passport-renderer':
        check_native_passport_renderer(name, source, errors)
    if role == 'native-capture-renderer':
        check_native_capture_renderer(name, source, errors)
    if role == 'platform-container':
        check_platform_container(name, source, errors)
    if role in set(DOCUMENT_PREVIEW_ROLES.values())-{'document-preview-platform-adapter'}:
        check_authored_source(name, source, manifest, errors)
        check_document_preview(name, source, role, errors)


def check_document_preview(name, source, role, errors):
    """Scan the complete optional UI source, including helpers and action closures.

    The existing camera preview is separately classified: its geometry/layer adapter is not
    a pure renderer. New holder UI cannot inherit that platform-adapter classification.
    """
    if DOCUMENT_PREVIEW_ROLES.get(name) != role:
        errors.append('Unregistered document preview source or changed role: '+name)
    imports = set(re.findall(r'\bimport\s+(\w+)', source))
    if imports-{'UIKit', 'Foundation', 'CoreGraphics', 'DocumentCaptureApple', 'DocumentSDK'}:
        errors.append('Forbidden document preview dependency: '+name)
    if renderer_has_behavior(source) or COMPOSE_EFFECTS.search(source):
        errors.append('Behavior inside document preview: '+name)
    authority = re.compile(
        r'\b(?:CaptureSession|DocumentCamera|DocumentFrontCaptureController|DocumentLevelMotionSource|DocumentAutoCaptureCoordinator|'
        r'AVCapture\w*|CMMotion\w*|DocumentTemporalMotionCollector|AppleDocumentImagePreparer|'
        r'ApplePortraitExtractor|ArtifactExtraction|CaptureEvidence\w*|SHA256|Digest)\b|'
        r'\.(?:capture|armAutomaticCapture|disarmAutomaticCapture|setNativeControlState|'
        r'setConsent|setActive|start|stop|retry|extract|parse|verify)\s*\(')
    if authority.search(source):
        errors.append('Capture or sensor authority inside document preview: '+name)
    if re.search(r'\bDate\s*\(|\b(?:ProcessInfo|ContinuousClock|CACurrentMediaTime|SystemClock|'
                 r'systemUptime|addObserver|publisher|sink)\b', source):
        errors.append('Ambient clock or observation inside document preview: '+name)
    if role == 'document-preview-renderer':
        if re.search(r'\.(?:map|compactMap|flatMap|filter|reduce|sorted)\s*[(\{]|'
                     r'\b(?:hypot|atan2|isFinite|gravity|bootTimeSeconds)\b|'
                     r'@(?:State|AppStorage|Binding)\b', source):
            errors.append('Derived capture state inside document preview renderer: '+name)
        # Control actions are direct handlers, never nested inside a visual branch or helper.
        without_handlers = re.sub(
            r'@objc\s+(?:private\s+)?func\s+\w+\s*\(\s*\)\s*\{\s*'
            r'emit\s*\(\s*\.(?:capture|cancel)\s*\)\s*\}', '', source)
        if re.search(r'\bemit\s*\(', without_handlers):
            errors.append('Conditional or indirect action dispatch inside document preview: '+name)
        visual_decisions = re.sub(
            r'\bif\s+state\.busy\s*\{|\bif\s+let\s+offset\s*=\s*state\.offset\s*\{|'
            r'\bswitch\s+state\.tone\s*\{', '', without_handlers)
        visual_decisions = re.sub(r'(?m)^\s*#if os\(iOS\)\s*$', '', visual_decisions)
        if re.search(r'\b(?:if|guard|switch|while)\b|\bfor\s+\w+\s+in\b|\s\?\s|\?:', visual_decisions):
            errors.append('Unreviewed decision inside document preview renderer: '+name)
        if any(pattern.search(source) for pattern in INLINE_STYLE):
            errors.append(INLINE_DESIGN_FAILURE+name)
    if role in {'document-preview-state', 'document-preview-style'}:
        declarations = re.sub(r'(?m)^\s*#if os\(iOS\)\s*$', '', source)
        if re.search(r'\b(?:var|if|guard|switch|while)\b|\bfor\s+\w+\s+in\b', declarations):
            errors.append('Mutable or derived document preview contract: '+name)
        if re.search(r'\bUIColor\s*\(|\bUIFont\.\w+\s*\(', source):
            errors.append('Document preview style must receive host design tokens: '+name)



def debug_only_storage_diagnostics(source):
    """Every executable declaration must stay within one outer DEBUG branch."""
    depth=0;opened=False;closed=False
    for line in source.splitlines():
        value=line.strip()
        if not value:continue
        if value.startswith('#if '):
            if depth==0:
                if opened or value!='#if DEBUG':return False
                opened=True
            depth+=1
        elif value=='#endif':
            depth-=1
            if depth<0:return False
            if depth==0:closed=True
        elif value.startswith(('#else','#elseif')):
            if depth<=1:return False
        elif depth==0:return False
    return opened and closed and depth==0

def check_authored_source(name, source, manifest, errors):
    # All authored tokens are reviewed technical keys/identifiers, including aliases.
    if '"""' in source or '#"' in source or '"#' in source:
        errors.append('Unreviewed multiline/raw string syntax: '+name)
    literals = set(QUOTED.findall(source))
    if literals != set(manifest.get('technicalStrings', {}).get(name, [])):
        errors.append('Unreviewed authored string tokens: '+name)
    reviewed_source = source
    if name in {'reference-apps/ios/Sources/DocumentFlowHost.swift',
                'reference-apps/ios/Sources/PassportFlowHost.swift',
                'reference-apps/ios/Sources/FaceComparisonController.swift',
                'reference-apps/ios/Sources/FaceComparisonHost.swift',
                'reference-apps/ios/Sources/SavedPassportCapture.swift',
                'reference-apps/ios/Sources/LegacyVisualArchive/LegacyEvidenceBindings.swift'}:
        reviewed_source = re.sub(r'(?m)^import CryptoKit\s*$', '', source)
    if name in {'reference-apps/ios/Sources/DocumentFlowHost.swift',
                'reference-apps/ios/Sources/NativeDocumentFlowCamera.swift'}:
        reviewed_source = re.sub(r'(?m)^import AVFoundation\s*$', '', reviewed_source)
        status_only = re.sub(r'(?:AVFoundation\s*\.\s*)?AVCaptureDevice\s*\.\s*authorizationStatus\s*\(\s*for\s*:\s*\.video\s*\)', '', source)
        if re.search(r'\bAVCapture\w*\b|\brequestAccess\b', status_only):
            errors.append('Document host may read camera permission status only; SDK owns acquisition: '+name)
    if name in {'reference-apps/ios/Sources/PulsePassportClient.swift',
                'reference-apps/ios/Sources/PassportPulseWire.swift',
                'reference-apps/ios/Sources/PassportServerCeremony.swift',
                'reference-apps/ios/Sources/PulseRegistrationRecovery.swift',
                'reference-apps/ios/Sources/PulseRegistrationAttestationRetry.swift'}:
        reviewed_source = re.sub(r'(?m)^import CryptoKit\s*$', '', reviewed_source)
    if name == 'reference-apps/ios/Sources/PassportPulseRegistration.swift':
        reviewed_source = re.sub(r'(?m)^import Security\s*$', '', reviewed_source)
    if name in {'reference-apps/ios/Sources/PassportCaptureStore.swift',
                'reference-apps/ios/Sources/PassportCaptureSchema.swift',
                'reference-apps/ios/Sources/DocumentFlowSQLiteStore.swift'}:
        reviewed_source = re.sub(r'(?m)^(?:@_spi\(StorageAdapter\) )?import (?:SQLCipher|KenshikiProtectedStorage)\s*$', '', reviewed_source)
        if re.search(r'\bStorageTestFixture\b|\.testing\s*\(|\beraseTesting\s*\(', source):
            errors.append('Synthetic key custody in production storage adapter: '+name)
    if name == 'reference-apps/ios/Sources/WorkflowSensorHost.swift':
        reviewed_source = re.sub(r'(?m)^import CoreLocation\s*$', '', reviewed_source)
    if name == 'reference-apps/ios/Sources/StorageHealthDiagnostics.swift':
        if not debug_only_storage_diagnostics(source):
            errors.append('Storage diagnostics must remain entirely DEBUG-only: '+name)
        protected_types=set(re.findall(r'\bProtected\w+\b',source))
        if (protected_types-{'ProtectedSQLiteError','ProtectedStoreKeyError','ProtectedStoreLifecycleError'}
                or re.search(r'\b(?:SHA256|SHA512|HMAC|AES|SymmetricKey|SecureEnclave|SecKey\w*|SecItem\w*)\b',source)):
            errors.append('Storage diagnostics can classify errors but cannot implement custody: '+name)
        reviewed_source=re.sub(r'(?m)^import (?:CryptoKit|KenshikiProtectedStorage)\s*$', '', reviewed_source)
    if FORBIDDEN_IMPORTS.search(reviewed_source):
        errors.append('Forbidden presentation dependency: '+name)
    if any(rule.search(source) for rule in RAW_SINKS):
        errors.append('Raw authored text at presentation sink: '+name)
    if re.search(r'\b(?:UIDocumentPickerViewController|UIDocumentPickerDelegate|UniformTypeIdentifiers|startAccessingSecurityScopedResource)\b|passport\.trust\.import', source):
        errors.append('Issuer trust provisioning leaked into holder UI: '+name)


def renderer_has_behavior(source):
    return any(pattern.search(source) for pattern in (RENDERER_BEHAVIOR, INFERENCE_BEHAVIOR))


def check_renderer(name, source, errors):
    if name == 'reference-apps/ios/Sources/ReferenceRenderer.swift':
        # A host-prepared optional portrait is media rendering, not a workflow decision.
        source = re.sub(r'(?m)^\s*if let image = screen.image \{\s*$', '', source)
    patterns = (
        (RENDERER_BEHAVIOR, 'Behavior inside native renderer'),
        (INFERENCE_BEHAVIOR, 'Inference inside native renderer'),
        (COMPOSE_EFFECTS, 'Workflow state or effect inside native renderer'),
        (re.compile(r'\.(?:task|onChange|onAppear)\s*[(\{]'), 'Workflow lifecycle hook inside renderer'),
        (re.compile(r'@(?:State|AppStorage|Binding)\b'), 'Mutable workflow ownership inside renderer'),
        (re.compile(r'\b(?:if|switch|when|guard)\s*[(A-Za-z_]'), 'Decision or workflow dispatch inside renderer'),
        (re.compile(r'\.(?:send|complete|retry|advance)\s*\('), 'Decision or workflow dispatch inside renderer'),
        (re.compile(r'\.(?:map|compactMap|flatMap|filter|reduce|sorted)\s*[(\{]|\s\?\s|\?:|==|!='), 'Derived decision inside native renderer'),
    )
    for pattern, message in patterns:
        if pattern.search(source):
            errors.append(message+': '+name)
    if any(pattern.search(source) for pattern in INLINE_STYLE):
        errors.append(INLINE_DESIGN_FAILURE+name)



def check_native_capture_renderer(name, source, errors):
    """One explicit camera surface may branch only on supplied optional media/layout readiness."""
    if name != 'reference-apps/ios/Sources/BiometricCaptureRenderer.swift':
        errors.append('Unregistered native capture renderer: '+name)
    if renderer_has_behavior(source) or COMPOSE_EFFECTS.search(source):
        errors.append('Behavior inside native capture renderer: '+name)
    if any(pattern.search(source) for pattern in CAPTURE_AUTHORITY):
        errors.append('Capture authority inside native capture renderer: '+name)
    allowed = {'guard isViewLoaded else { return }', 'if let preview = screen.preview {', 'if let image = screen.image {'}
    for line in source.splitlines():
        if re.search(r'\b(?:if|guard|switch|when)\b', line) and line.strip() not in allowed:
            errors.append('Unreviewed decision inside native capture renderer: '+name)
    if re.search(r'\.(?:map|compactMap|flatMap|filter|reduce|sorted)\s*[(\{]|\s\?\s|\?:|==|!=|@(?:State|AppStorage|Binding)\b', source):
        errors.append('Derived workflow state inside native capture renderer: '+name)
    if any(pattern.search(source) for pattern in INLINE_STYLE):
        errors.append(INLINE_DESIGN_FAILURE+name)



def check_native_document_renderer(name, source, errors):
    """Document media comes from prepared host state; only raw visibility intent leaves."""
    if name != 'reference-apps/ios/Sources/DocumentFlowRenderer.swift':
        errors.append('Unregistered native document renderer: '+name)
    if renderer_has_behavior(source) or COMPOSE_EFFECTS.search(source):
        errors.append('Behavior inside native document renderer: '+name)
    own_types = {'DocumentFlowRenderer', 'DocumentFlowScreen', 'DocumentFlowDisplayItem', 'DocumentFlowIntent'}
    document_types = set(re.findall(r'\bDocument[A-Za-z0-9_]*\b', source))
    imports = set(re.findall(r'\bimport\s+(\w+)', source))
    if (document_types-own_types or imports-{'UIKit'}
            or re.search(r'\b(?:NativeDocument\w*|SHA256|Digest|WorkflowController)\b|'
                         r'\.(?:send|snapshot|capture|extract|parse|verify|setConsent|setActive|start|stop|retry)\s*\(', source)):
        errors.append('Document authority inside native document renderer: '+name)
    allowed = {'guard isViewLoaded else { return }', 'if let preview = screen.preview {',
               'if let image = item.image {', 'for item in screen.items {',
               'for label in [headingLabel, messageLabel, scopeLabel] {',
               'if mountedCaptureSurface !== screen.captureSurface {',
               'if let surface = screen.captureSurface {',
               'if mountedPreview !== screen.preview {',
               'if screen.actionSurface.superview !== primaryRegion {'}
    for line in source.splitlines():
        if re.search(r'\b(?:if|guard|switch|when|for)\b', line) and line.strip() not in allowed:
            errors.append('Unreviewed decision inside native document renderer: '+name)
    state_decisions = source
    for rendering_identity in ('mountedCaptureSurface !== screen.captureSurface',
                               'mountedPreview !== screen.preview',
                               'screen.actionSurface.superview !== primaryRegion'):
        state_decisions = state_decisions.replace(rendering_identity, '')
    state_decisions = re.sub(
        r'(?m)^\s*(?:captureRegion|content\.superview\?|primaryRegion)\.isHidden\s*=\s*'
        r'screen\.captureSurface\s*(?:==|!=)\s*nil\s*$', '', state_decisions)
    if re.search(r'\.(?:map|compactMap|flatMap|filter|reduce|sorted)\s*[(\{]|\s\?\s|\?:|==|!=|@(?:State|AppStorage|Binding)\b', state_decisions):
        errors.append('Derived workflow state inside native document renderer: '+name)
    if any(pattern.search(source) for pattern in INLINE_STYLE):
        errors.append(INLINE_DESIGN_FAILURE+name)

def check_native_passport_renderer(name, source, errors):
    """Passport rendering consumes supplied media and forwards raw text; it owns no protocol."""
    if name != 'reference-apps/ios/Sources/PassportFlowRenderer.swift':
        errors.append('Unregistered native passport renderer: '+name)
    if renderer_has_behavior(source) or COMPOSE_EFFECTS.search(source):
        errors.append('Behavior inside native passport renderer: '+name)
    authority = re.compile(
        r'\b(?:PassportFlowController|PassportChipReader|PassportAccessKey|PassportMRZOCRParser|'
        r'PassportReadObservation|PassportAuthenticatedPortrait|PassportCorrespondenceObservation|'
        r'NativeMRZSession|NFCTagReaderSession|SHA256|Digest|WorkflowController)\b|'
        r'\bimport\s+(?:PassportSDK|PassportNFC|PassportMRZCapture|CoreNFC|CryptoKit|Vision|AVFoundation)\b|'
        r'\.(?:send|read|scan|capture|parse|verify|setConsent|setActive|start|stop|retry)\s*\(')
    if authority.search(source):
        errors.append('Passport authority inside native passport renderer: '+name)
    allowed = {'guard isViewLoaded else { return }', 'if let preview = screen.preview {',
               'if let image = screen.image {'}
    for line in source.splitlines():
        if re.search(r'\b(?:if|guard|switch|when)\b', line) and line.strip() not in allowed:
            errors.append('Unreviewed decision inside native passport renderer: '+name)
    if re.search(r'\.(?:map|compactMap|flatMap|filter|reduce|sorted)\s*[(\{]|\s\?\s|\?:|==|!=|@(?:State|AppStorage|Binding)\b', source):
        errors.append('Derived workflow state inside native passport renderer: '+name)
    if any(pattern.search(source) for pattern in INLINE_STYLE):
        errors.append(INLINE_DESIGN_FAILURE+name)


def check_platform_container(name, source, errors):
    # OS availability, supplied visual variants and native layout are rendering
    # under UI-02. Workflow types and side effects remain outside this layer.
    if renderer_has_behavior(source) or WORKFLOW_OWNERSHIP.search(source) or COMPOSE_EFFECTS.search(source):
        errors.append('Workflow ownership or side effect inside platform container: '+name)
    if any(pattern.search(source) for pattern in INLINE_STYLE):
        errors.append(INLINE_DESIGN_FAILURE+name)


def check_resources(root, errors):
    # Authored application resources cannot become another string catalog.
    for path in (root/'reference-apps').rglob('*.xml'):
        if any(part in PRUNE for part in path.parts):
            continue
        if path.parent.name.startswith('values') and path.name != 'verification-metadata.xml':
            errors.append('Unmanaged native resource catalog: '+path.relative_to(root).as_posix())
        if path.name == 'AndroidManifest.xml':
            check_manifest(path.read_text(), errors)


def check_manifest(source, errors):
    application = ET.fromstring(source).find('application')
    if application is None or application.get('{http://schemas.android.com/apk/res/android}usesCleartextTraffic') != 'false':
        errors.append('Reference Android must explicitly disable cleartext traffic')
    if 'uses-permission' in source:
        errors.append('Reference stubs must not request camera/NFC/network permissions')
    if re.search(r'android:(?:label|description)="(?!@)[^"]+"', source):
        errors.append('Manifest authored copy must reference generated resource')


def check_gradle_verification(root, errors):
    path = root/'reference-apps/android/gradle/verification-metadata.xml'
    if not path.exists():
        errors.append('Reference Android dependency verification metadata missing')
        return
    ns = {'v': 'https://schema.gradle.org/dependency-verification'}
    tree = ET.parse(path)
    if tree.findtext('v:configuration/v:verify-metadata', namespaces=ns) != 'true':
        errors.append('Reference Android must verify metadata')
    if tree.findall('.//v:trusted-artifacts/*', ns):
        errors.append('Reference Android cannot bypass checksums with trusted artifacts')
    artifacts = tree.findall('.//v:artifact', ns)
    if not artifacts or any(not item.findall('v:sha256', ns) for item in artifacts):
        errors.append('Reference Android artifacts require SHA-256 digests')
    for path in (root/'reference-apps/android').rglob('*.gradle.kts'):
        if any(part in PRUNE for part in path.parts):
            continue
        if re.search(r'\b(?:exec|commandLine|mavenLocal|includeBuild)\b|http://|verificationMode', without_comments(path.read_text())):
            errors.append('Unreviewed Android build mechanism: '+path.relative_to(root).as_posix())



def check_biometric_composition(root, errors):
    swift = (root/'presentation/Package.swift').read_text()
    android = (root/'reference-apps/android/app/build.gradle.kts').read_text()
    module = (root/'reference-apps/android/biometric-contract/build.gradle.kts').read_text()
    if re.search(r'\.package\s*\(|\bBiometricSDK\b', without_comments(swift)):
        errors.append('Swift presentation must remain independent of capability packages')
    for path in (root/'presentation/Sources').rglob('*.swift'):
        if re.search(r'\b(?:import\s+(?:BiometricSDK|BiometricInference|BiometricVisualAssessment|MLXVLM|MLXLMCommon)|SyntheticBiometricEngine)\b', without_comments(path.read_text())):
            errors.append('Retired synthetic biometric runtime in Swift presentation')
    if 'implementation(project(":biometric-contract"))' not in android:
        errors.append('Synthetic host must consume the biometric Android integration module')
    if module.count('../../../biometric/android/biometric-sdk/src/main/kotlin') != 1 or 'kotlin.directories.addAll(listOf("../../../biometric/android/biometric-sdk/src/main/kotlin"))' not in module:
        errors.append('Android integration must consume the original biometric sources exactly once')




def check_passport_composition(root, errors):
    """Pin native reference host package products without coupling optional shared presentation."""
    path = root/'reference-apps/ios/project.yml'
    try:
        parser = "import YAML from 'yaml'; let input=''; for await (const chunk of process.stdin) input+=chunk; process.stdout.write(JSON.stringify(YAML.parse(input)));"
        project = json.loads(subprocess.check_output(
            ['node', '--input-type=module', '-e', parser], input=path.read_text(), cwd=ROOT, text=True))
    except (OSError, ValueError, subprocess.SubprocessError):
        errors.append('Native reference project YAML is invalid')
        return
    expected_packages = {'SQLCipher': {'url': 'https://github.com/sqlcipher/SQLCipher.swift.git', 'revision': '39f212458aeb88e33bdac2200a793a3f0d55d32b'},
                         'KenshikiDocument': {'path': '../../document'},
                         'KenshikiFaceQuality': {'path': '../../biometric/quality-apple'},
                         'KenshikiBiometric': {'path': '../../biometric'},
                         'KenshikiFoundation': {'path': '../..'},
                         'KenshikiMotion': {'path': '../../foundation/motion'},
                         'KenshikiPresentation': {'path': '../../presentation'},
                         'KenshikiPassport': {'path': '../../passport'}}
    if project.get('packages') != expected_packages:
        errors.append('Native reference package graph changed')
    dependencies = project.get('targets', {}).get('KenshikiReference', {}).get('dependencies')
    expected_dependencies = [
        {'package': 'KenshikiDocument', 'product': 'DocumentSDK'},
        {'package': 'KenshikiDocument', 'product': 'DocumentCaptureApple'},
        {'package': 'KenshikiDocument', 'product': 'DocumentCapturePreview'},
        {'package': 'KenshikiMotion', 'product': 'KenshikiMotion'},
        {'package': 'KenshikiFoundation', 'product': 'CaptureEvidenceCustody'},
        {'package': 'KenshikiFoundation', 'product': 'KenshikiEvidenceManifest'},
        {'package': 'SQLCipher', 'product': 'SQLCipher'},
        {'package': 'KenshikiFoundation', 'product': 'KenshikiProtectedStorage'},
        {'package': 'KenshikiFoundation', 'product': 'KenshikiOperationBinding'},
        {'package': 'KenshikiFoundation', 'product': 'KenshikiPulsePassport'},
        {'package': 'KenshikiPresentation'},
        {'package': 'KenshikiBiometric', 'product': 'BiometricCapture'},
        {'package': 'KenshikiBiometric', 'product': 'BiometricCapturePreview'},
        {'package': 'KenshikiBiometric', 'product': 'BiometricInference'},
        {'package': 'KenshikiFaceQuality', 'product': 'BiometricQuality'},
        {'package': 'KenshikiPassport', 'product': 'PassportSDK'},
        {'package': 'KenshikiPassport', 'product': 'PassportNFC'},
        {'package': 'KenshikiPassport', 'product': 'PassportMRZCapture'},
        {'package': 'KenshikiPassport', 'product': 'PassportMRZPreview'},
    ]
    if (not isinstance(dependencies, list)
            or sorted(json.dumps(value, sort_keys=True) for value in dependencies)
            != sorted(json.dumps(value, sort_keys=True) for value in expected_dependencies)):
        errors.append('Native reference product dependencies changed')
    expected_scripts = [{'name': 'Provision public passport trust',
                         'script': 'python3 "$SRCROOT/../../scripts/provision_reference_trust.py" --output "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"',
                         'basedOnDependencyAnalysis': False}]
    expected_scripts.append({'name': 'Provision pinned face model',
                             'script': 'python3 "$SRCROOT/../../scripts/provision_reference_model.py" --output "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"',
                             'basedOnDependencyAnalysis': False})
    expected_scripts.append({'name': 'Provision pinned face quality profile',
                             'script': 'python3 "$SRCROOT/../../scripts/provision_reference_quality.py" --output "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"',
                             'basedOnDependencyAnalysis': False})
    if project.get('targets', {}).get('KenshikiReference', {}).get('preBuildScripts') != expected_scripts:
        errors.append('Native reference public trust build provisioning changed')
    settings = project.get('targets', {}).get('KenshikiReference', {}).get('settings', {}).get('base', {})
    if (settings.get('CODE_SIGN_ENTITLEMENTS') != 'KenshikiReference.entitlements'
            or settings.get('INFOPLIST_KEY_NFCReaderUsageDescription') != '$(PRODUCT_NAME)'
            or settings.get('INFOPLIST_KEY_NSMotionUsageDescription') != '$(PRODUCT_NAME)'
            or settings.get('INFOPLIST_KEY_NSLocationWhenInUseUsageDescription') != '$(PRODUCT_NAME)'
            or 'INFOPLIST_KEY_com.apple.developer.nfc.readersession.iso7816.select-identifiers' in settings):
        errors.append('Native reference NFC capability declarations changed')
    expected_info = {'path': 'KenshikiReference-Info.plist', 'properties': {
        'PulsePassportBaseURL': 'https://id.kenshikilabs.com',
        'PulsePassportAppAttestEnvironment': 'production',
        'PulsePassportApplicationIdentifier': 'com.kenshiki.reference',
        'KenshikiKeychainAccessGroup': '$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)',
        'com.apple.developer.nfc.readersession.iso7816.select-identifiers': ['A0000002471001']}}
    if project.get('targets', {}).get('KenshikiReference', {}).get('info') != expected_info:
        errors.append('Native reference NFC Info.plist declaration changed')
    try:
        info = plistlib.loads((root/'reference-apps/ios/KenshikiReference-Info.plist').read_bytes())
        if info.get('com.apple.developer.nfc.readersession.iso7816.select-identifiers') != ['A0000002471001']:
            errors.append('Native reference NFC application identifier changed')
    except (OSError, ValueError):
        errors.append('Native reference NFC Info.plist is missing or invalid')

    try:
        entitlements = plistlib.loads((root/'reference-apps/ios/KenshikiReference.entitlements').read_bytes())
        if entitlements != {'com.apple.developer.devicecheck.appattest-environment': 'production',
                            'com.apple.developer.nfc.readersession.formats': ['TAG'],
                            'keychain-access-groups': ['$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)']}:
            errors.append('Native reference NFC entitlement changed')
    except (OSError, ValueError):
        errors.append('Native reference NFC entitlement is missing or invalid')



if __name__ == '__main__':
    findings = check()
    for finding in findings:
        print('FAIL '+finding)
    if not findings:
        print('PASS presentation inventory, dependency boundaries, display sinks and strict dependency verification')
    raise SystemExit(bool(findings))
