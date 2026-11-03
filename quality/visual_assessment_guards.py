"""Keep retired Liquid inference out of SDKs; historical readers are app-owned and inert."""
import re
ARCHIVE = 'reference-apps/ios/Sources/LegacyVisualArchive'
ARCHIVE_FILES = {'CaptureMeasurements.swift', 'ReviewJSON.swift', 'VisualFaceAssessment.swift',
                 'VisualEvidenceReview.swift', 'LiquidEvidencePass.swift', 'LegacyEvidenceBindings.swift'}
RUNTIME = re.compile(r'\b(?:import\s+(?:MLX\w*|Tokenizers)|(?:actor|class)\s+(?:LiquidFaceAssessment|LiquidEvidenceAssessment|LiquidMLXRuntime)|LiquidPassService|runLiquid\s*\(|loadModelContainer\s*\()')
ARCHIVE_EFFECTS = re.compile(r'\b(?:actor|class|Task|FileManager|URLSession|HubApi|CGImage|modelDirectory|generate|loadModelContainer)\b|Data\s*\(\s*contentsOf:')

def check_graph(root, failures):
    manifest = (root/'Package.swift').read_text()
    if re.search(r'BiometricVisualAssessment|mlx-swift|swift-transformers|MLX\w*|Tokenizers', manifest):
        failures.append('Retired visual runtime must not be an SDK product or dependency')
    packages = re.findall(r'\.package\s*\(\s*path:\s*"([^"]+)"\s*\)', manifest)
    if packages != ['../foundation/motion'] or re.search(r'\.package\s*\(\s*url:', manifest):
        failures.append('Biometric package dependencies must remain the reviewed local motion package')

def check(root):
    failures = []
    check_graph(root, failures)
    for path in (root/'ios/Sources').rglob('*.swift'):
        if RUNTIME.search(path.read_text()):
            failures.append('Retired visual inference in SDK: '+path.relative_to(root).as_posix())
    if any((root/'ios/Sources/BiometricVisualAssessment').glob('*.swift')):
        failures.append('Retired visual SDK source target remains')
    if any((root/'api/BiometricVisualAssessment').glob('*.json')):
        failures.append('Retired experimental visual API snapshots remain')
    parent = root.parent
    archive = parent/ARCHIVE
    actual = {p.name for p in archive.glob('*.swift') if p.is_file() and not p.is_symlink()}
    if actual != ARCHIVE_FILES or any(p.is_symlink() for p in archive.glob('*')):
        failures.append('Historical visual archive must have the exact reviewed app-only inventory')
    for path in archive.glob('*.swift'):
        text = path.read_text()
        if ARCHIVE_EFFECTS.search(text) or RUNTIME.search(text):
            failures.append('Historical visual archive must not load files, schedule work or run inference: '+path.name)
        if set(re.findall(r'(?m)^import\s+(\w+)', text)) - {'Foundation', 'CryptoKit'}:
            failures.append('Historical visual archive has an active dependency: '+path.name)
    app = parent/'reference-apps/ios'
    for path in (app/'Sources').rglob('*.swift'):
        if RUNTIME.search(path.read_text()):
            failures.append('Retired visual inference in reference app: '+path.relative_to(parent).as_posix())
    project = app/'project.yml'
    if project.exists() and re.search(r'BiometricVisualAssessment|provision_reference_visual_model|LiquidFaceModel|MLX', project.read_text()):
        failures.append('Reference app still links or provisions the retired visual runtime')
    if (parent/'scripts/provision_reference_visual_model.py').exists():
        failures.append('Retired model provisioning script remains executable')
    return failures
