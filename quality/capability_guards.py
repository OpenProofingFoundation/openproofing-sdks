#!/usr/bin/env python3
"""Capability-specific guard extensions. Conservative source checks, not data-flow proofs."""
from pathlib import Path
import hashlib
import io
import json
import os
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

PACKAGE_MANIFEST='Package.swift'
SWIFT_SUFFIX='.swift'
IOS_SOURCES='ios/Sources'
EMBEDDING_CONTRACT='embedding primitive contract'
DEPENDENCY_VERIFICATION='Android dependency verification'
NATIVE_SUFFIXES={SWIFT_SUFFIX,'.kt','.java','.m','.mm','.h','.hpp','.cpp','.c'}
PRUNE = {'.git', '.build', '.gradle', 'node_modules', 'build', 'DerivedData', '__pycache__'}
BANNED = re.compile(r'regula|insightface|kenshiki[-_.]?identity|pulse[-_.]?(?:worker|gov|ios)', re.I)
ASSETS = {'.mlmodel', '.mlmodelc', '.mlpackage', '.onnx', '.tflite', '.pt', '.pth', '.bin', '.aar', '.jar', '.framework', '.xcframework', '.jpg', '.jpeg', '.png', '.heic', '.pdf', '.p12', '.pem', '.key'}

def files(root):
    for current, dirs, names in os.walk(root):
        for name in dirs:
            p = Path(current) / name
            if p.is_symlink() and name not in PRUNE:
                yield p
        dirs[:] = sorted(d for d in dirs if d not in PRUNE and not (Path(current)/d).is_symlink())
        for name in sorted(names):
            yield Path(current)/name

def _block_comment_end(text, start):
    index=start+2
    depth=1
    while index<len(text) and depth:
        if text.startswith('/*',index):
            depth+=1;index+=2
        elif text.startswith('*/',index):
            depth-=1;index+=2
        else:
            index+=1
    if depth:raise ValueError('Unclosed Kotlin comment')
    return index


def _literal_end(text, start):
    quote='"""' if text.startswith('"""',start) else text[start]
    index=start+len(quote)
    while index<len(text):
        if text.startswith(quote,index):return index+len(quote)
        if len(quote)==1 and text[index]=='\\':index+=2
        else:index+=1
    raise ValueError('Unclosed Kotlin literal')


def _masked_span(text, index, strings):
    if text.startswith('//',index):
        end=text.find('\n',index)
        return (len(text) if end<0 else end),True
    if text.startswith('/*',index):return _block_comment_end(text,index),True
    if text[index] in '\"\'':return _literal_end(text,index),not strings
    return index+1,False


def kotlin_mask(text, strings=False):
    """Blank nested comments/literals while retaining offsets and line breaks."""
    out=list(text);index=0
    while index<len(text):
        end,blank=_masked_span(text,index,strings)
        if blank:
            for position in range(index,end):
                if out[position]!='\n':out[position]=' '
        index=end
    return ''.join(out)


def inspect_kotlin(text):
    code=kotlin_mask(text); literals=kotlin_mask(text,strings=True); failures=[]
    patterns={
        'ambient': r'\b(?:System\.(?:getenv|getProperties|currentTimeMillis|nanoTime)|Instant\.now|Clock\.system\w*|Locale\.getDefault|TimeZone\.getDefault|GlobalScope|Dispatchers\.(?:IO|Default|Main)|File\s*\(|Environment\.get\w+|getSharedPreferences|PreferenceManager\.getDefaultSharedPreferences)\b',
        'prose channel': r'\b(?:override\s+(?:val|var)\s+(?:message|localizedMessage)|getLocalizedMessage\s*\()',
        'public surface escape': r'\b(?:java\.lang\.reflect|Class\.forName|setAccessible|Unsafe|System\.load|System\.loadLibrary)\b',
        'rendering': r'\b(?:androidx\.compose|android\.widget|DateFormat|SimpleDateFormat|NumberFormat)\b',
        'diagnostics': r'\b(?:println|print|printf|Log\s*\.|Timber\s*\.|Logger\b|android\.util\.Log|java\.util\.logging|System\s*\.\s*(?:out|err))',
        'network': r'\b(?:java\.net|javax\.net|okhttp3|retrofit2|io\.ktor\.client|URLSession|HttpClient)\b',
        'policy number': r'\b(?:const\s+val|(?:val|var)\s+\w*(?:threshold|Threshold|limit|Limit|confidence|Confidence)\w*\s*(?::\s*\w+)?\s*=)\s*\w*\s*(?::\s*\w+)?\s*=?.*?\d',
        'identity verdict': r'\b(?:fun|val|var)\s+(?:isIdentityVerified|isIdentityAccepted|identityAccepted|identityVerified|enrollmentApproved)\b',
    }
    for name,pattern in patterns.items():
        for match in re.finditer(pattern,code): failures.append((name,code.count('\n',0,match.start())+1))
    # Interpolated strings are rejected until a reviewed diagnostics/serialization mechanism exists.
    # This closes hidden side effects inside ${...}; no marker comment grants an exception.
    if re.search(r'\$\{|\$[A-Za-z_]',literals): failures.append(('string interpolation requires reviewed mechanism',1))
    if re.search(r'"[^"\n]*\b\w+\s+\w+[.!?][^"\n]*"',literals): failures.append(('authored sentence',1))
    if re.search(r'\b(?:regula|insightface|Pulse\w*|Kenshiki\w*)\b',literals,re.I): failures.append(('vendor identifier',1))
    return failures


def _check_swift_graph(root,c,fail):
    swift=c['swiftModule']
    manifest=(root/PACKAGE_MANIFEST).read_text()
    from boundary_gates import configure,engine
    gate=configure(engine(root),root)
    if c['capability']=='passport':
        from passport_guards import check_graph
        check_graph(root, gate, fail)
        return
    if c['capability']=='document':
        from document_capture_guards import graph
        problems=[];graph(root,gate,problems)
        for problem in problems:fail(PACKAGE_MANIFEST,problem)
        return
    expected = ['AuraFaceNative', 'BiometricCapture', 'BiometricCapturePreview', 'BiometricInference', swift, 'quality-apple/BiometricQuality'] if c['capability']=='biometric' else [swift]
    if gate.neutral_targets()!=expected: fail(PACKAGE_MANIFEST,'unexpected target inventory')
    if c['capability']=='biometric':
        from inference_guards import check as check_inference
        for problem in check_inference(root): fail(PACKAGE_MANIFEST,problem)
        from visual_assessment_guards import check as check_visual
        for problem in check_visual(root): fail(PACKAGE_MANIFEST,problem)
        from native_quality_guards import check as check_quality
        for problem in check_quality(root): fail(PACKAGE_MANIFEST,problem)
        manifest = re.sub(r'\.binaryTarget\s*\([^)]*\)', '', manifest)
        manifest = re.sub(r'\.package\s*\(\s*url:\s*"[^"]+"\s*,\s*revision:\s*"[^"]+"\s*\)', '', manifest)
        manifest = re.sub(r'\.package\s*\(\s*path:\s*"\.\./foundation/motion"\s*\)', '', manifest)
    if re.search(r'\.package\s*\(|\.binaryTarget\s*\(|unsafeFlags|\.plugin\s*\(',manifest): fail(PACKAGE_MANIFEST,'dependency/plugin/binary needs reviewed provenance and boundary extension')

def _check_android_settings(root,c,fail):
    module=c['androidModule']
    settings=(root/'android/settings.gradle.kts').read_text()
    includes=re.findall(r'include\(\s*"([^"]+)"\s*\)',settings)
    if includes!=[':'+module] or re.search(r'includeBuild|projectDir|apply\s*\(',settings): fail('android/settings.gradle.kts','unreviewed project/include graph')

def _check_gradle_file(root,p,fail):
    rel=str(p.relative_to(root)); text=p.read_text()
    if BANNED.search(text): fail(rel,'vendor/product/service dependency')
    reviewed_fixture_build = rel == 'android/biometric-sdk/build.gradle.kts' and root.name == 'biometric'
    scan_text = text
    if reviewed_fixture_build:
        lock = json.loads((root/'Gates/portrait-test-tooling.json').read_text())
        if hashlib.sha256(p.read_bytes()).hexdigest() != lock.get(rel):
            fail(rel,'shared-vector test generator changed without reviewed pin')
        scan_text = text.replace('android.sourceSets.getByName("test").resources.srcDir(portraitVectorsOutput)', '')
    if re.search(r'sourceSets|srcDirs?|buildConfigField|externalNativeBuild|fileTree|files\s*\(|project\s*\(|maven\s*\{|apply\s*\(',scan_text): fail(rel,'unreviewed source/dependency/repository extension')
    if re.search(r'\b(?:implementation|api|compileOnly|runtimeOnly)\s*\(',text):fail(rel,'runtime dependency needs inventory/provenance/lock extension')
    if re.search(r'version\s*"[^"\n]*(?:\+|latest|SNAPSHOT|\[|\])',text):fail(rel,'dynamic dependency version')

def _check_android_gradle(root,fail):
    for p in (root/'android').rglob('*.gradle.kts'):
        if not any(part in PRUNE for part in p.relative_to(root).parts):
            _check_gradle_file(root,p,fail)

def _check_android_manifest(root,p,fail):
    try:
        tree=ET.fromstring(p.read_text())
        if list(tree):fail(str(p.relative_to(root)),'manifest permissions/components require reviewed capture integration')
    except ET.ParseError:fail(str(p.relative_to(root)),'invalid Android manifest')

def _check_android_manifests(root,fail):
    for p in (root/'android').rglob('AndroidManifest.xml'):
        if not any(part in PRUNE for part in p.relative_to(root).parts):
            _check_android_manifest(root,p,fail)

def _check_wrapper_and_provenance(root,fail):
    wrapper=(root/'android/gradle/wrapper/gradle-wrapper.properties').read_text()
    if 'distributionSha256Sum=ed1a8d686605fd7c23bdf62c7fc7add1c5b23b2bbc3721e661934ef4a4911d7c' not in wrapper or 'gradle-8.14.3-all.zip' not in wrapper: fail('gradle-wrapper.properties','review wrapper version and checksum together')
    provenance=json.loads((root/'Gates/import-provenance.json').read_text())
    for item in provenance['files']:
        p=root/item['destination']
        if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=item['destinationSHA256']:fail(item['destination'],'imported guard changed without provenance review')
    if (root/'Gates/baselines.json').exists():fail('Gates/baselines.json','new capability has zero debt; baseline files cannot suppress findings')

def _check_outcomes(root,c,fail):
    module=c['androidModule'];swift=c['swiftModule']
    sp=root/IOS_SOURCES/swift/(c['outcomeType']+'.swift')
    kp=root/'android'/module/'src/main/kotlin'/Path(*c['androidPackage'].split('.'))/(c['outcomeType']+'.kt')
    if sp.is_file() and kp.is_file():
        values=[]
        for name,value in re.findall(r'\bcase\s+(\w+)(?:\s*=\s*"([^"]+)")?',sp.read_text()): values.append(value or name)
        kvals=re.findall(r'\b[A-Z_]+\("([^"]+)"\)',kp.read_text())
        if values!=c['outcomes'] or kvals!=c['outcomes']: fail('outcome contract','Swift/Kotlin wire values differ from approved vocabulary')
    else:fail('outcome contract','required platform contract missing')

def _check_embedding_contract(root,c,fail):
    module=c['androidModule'];swift=c['swiftModule']
    contract_path=root.parent/'contracts/embedding-math-v1.json'
    try:
        contract=json.loads(contract_path.read_text())
        if contract['featurePrecision']!='float32' or contract['normAndCoordinatePrecision']!='float64' or contract['angularDistanceUnit']!='radian' or contract['invalidVectorBehavior']!='typed_error' or contract['cosineRange']!=[-1,1]:
            fail(EMBEDDING_CONTRACT,'numerical/units contract requires reviewed version change')
        swift_source=(root/IOS_SOURCES/swift/'EmbeddingMath.swift').read_text()
        kotlin_source=kotlin_mask((root/'android'/module/'src/main/kotlin'/Path(*c['androidPackage'].split('.'))/'EmbeddingMath.kt').read_text(),strings=True)
        _check_embedding_enums(contract,swift_source,kotlin_source,fail)
        _check_test_dependency_catalog(root,module,fail)
    except (OSError,ValueError,KeyError):fail(EMBEDDING_CONTRACT,'missing or invalid shared contract/source')

def _check_test_dependency_catalog(root,module,fail):
    gradle=(root/'android'/module/'build.gradle.kts').read_text()
    declarations=re.findall(r'\btestImplementation\(([^)]+)\)',gradle)
    catalog=root/'android/gradle/libs.versions.toml'
    if declarations!=['libs.junit'] or not catalog.is_file() or catalog.is_symlink():
        fail('Android primitive tests','test dependency inventory/pin changed');return
    if hashlib.sha256(catalog.read_bytes()).hexdigest()!='1e45cb09ef3a6362c570d8279af906c0973bbc40a20f406e59902b46c0f40a27':
        fail('Android primitive tests','reviewed JUnit version catalogue changed')


def _check_quality_configuration(root,fail):
    import subprocess
    result=subprocess.run(['node','scripts/guards/quality-config.mjs'],cwd=root,capture_output=True,text=True)
    if result.returncode:fail('quality configuration',result.stdout.strip() or 'configuration guard failed')

def _check_embedding_enums(contract,swift_source,kotlin_source,fail):
    for enum_name,field in [('EmbeddingDomain','domains'),('PrimitiveFailure','failures')]:
        ss=re.search(r'enum '+enum_name+r'[^\{]*\{([^}]+)\}',swift_source)
        ks=re.search(r'enum class '+enum_name+r'[^\{]*\{([^}]+)\}',kotlin_source)
        sv=re.findall(r'case\s+\w+\s*=\s*"([^"\n]+)"',ss[1]) if ss else []
        kv=re.findall(r'\b[A-Z_]+\("([^"\n]+)"\)',ks[1]) if ks else []
        if sv!=contract[field] or kv!=contract[field]:fail(EMBEDDING_CONTRACT,enum_name+' Swift/Kotlin wire vocabulary differs')

def _nist_sources(root,c,fail):
    if c['capability']!='biometric':return set()
    from nist_integrity import verify
    sources,problems=verify(root)
    for message in problems:fail('nist',message)
    return sources


def _check_source_file(root,p,source_roots,nist_sources,fail):
    rel=p.relative_to(root).as_posix()
    if p.is_symlink():
        fail(rel,'source symlink is forbidden');return
    if rel in nist_sources:return
    if p.suffix in NATIVE_SUFFIXES and p.name!=PACKAGE_MANIFEST:
        _check_source_location(rel,p,source_roots,fail)
    if p.suffix.lower() in ASSETS and rel!='android/gradle/wrapper/gradle-wrapper.jar':
        fail(rel,'asset/binary requires rights, digest and packaging guard extension')


def _check_source_location(rel,p,source_roots,fail):
    test=rel.startswith('ios/Tests/') or re.match(r'android/[^/]+/src/(?:test|androidTest)/',rel)
    if test:return
    if not any(p.is_relative_to(x) for x in source_roots):
        fail(rel,'source outside guarded production roots; extend the inventory and guards before adding a module')
    if p.suffix not in {SWIFT_SUFFIX,'.kt'}:fail(rel,'new source language requires guard/QA extension')


def _check_native_file(root,c,p,fail):
    if not p.is_file():return
    if p.suffix=='.kt':_check_kotlin_file(root,c,p,fail)
    elif p.suffix==SWIFT_SUFFIX:_check_swift_file(root,p,fail,c['capability'])


def _check_kotlin_file(root,c,p,fail):
    try:
        text=re.sub(r'(?m)^package[ \t]+'+re.escape(c['androidPackage'])+r'(?:\.\w+)*[ \t]*;?[ \t]*$','',p.read_text())
        for rule,line in inspect_kotlin(text):fail(str(p.relative_to(root))+':'+str(line),rule)
    except ValueError:fail(str(p.relative_to(root)),'Kotlin lexical scan failed')


def _check_swift_file(root,p,fail,capability=None):
    from boundary_gates import engine
    source=p.read_text()
    if capability == 'passport':
        from passport_guards import reviewed_diagnostic_source
        source=reviewed_diagnostic_source(p.relative_to(root).as_posix(),source)
    code=engine(root).mask(source)
    if re.search(r'\b(?:print|debugPrint|dump|NSLog|os_log|Logger)\b',code):
        fail(str(p.relative_to(root)),'native diagnostics require a reviewed reason-code sink')
    if re.search(r'\b(?:URLSession|URLRequest|NWConnection|CFNetwork)\b',code):
        fail(str(p.relative_to(root)),'mandatory network mechanism belongs in optional adapters')


def _check_native_roots(root,c,source_roots,fail):
    for folder in source_roots:
        if not folder.is_dir():fail(str(folder.relative_to(root)),'required source root missing')
        for path in folder.rglob('*'):_check_native_file(root,c,path,fail)


def _check_dependency_verification(root,fail):
    manifest=root/'docs/test-dependencies.json'
    data=json.loads(manifest.read_text())
    expected=data['gradleVerificationSHA256']
    path=root/'android/gradle/verification-metadata.xml'
    if not path.is_file() or path.is_symlink():
        fail(DEPENDENCY_VERIFICATION,'required verification metadata missing');return
    if hashlib.sha256(path.read_bytes()).hexdigest()!=expected:
        fail(DEPENDENCY_VERIFICATION,'reviewed metadata digest differs');return
    tree=ET.fromstring(path.read_bytes())
    namespace={'v':'https://schema.gradle.org/dependency-verification'}
    if tree.findtext('v:configuration/v:verify-metadata',namespaces=namespace)!='true':
        fail(DEPENDENCY_VERIFICATION,'metadata verification must be enabled')
    if tree.findtext('v:configuration/v:verify-signatures',namespaces=namespace)!='false':
        fail(DEPENDENCY_VERIFICATION,'review checksum verification policy')


def scan(root):
    c=json.loads((root/'Gates/config.json').read_text());failures=[]
    def fail(path,rule):failures.append(f'{path}: {rule}')
    source_roots=[root/IOS_SOURCES/c['swiftModule'],root/'android'/c['androidModule']/'src/main']
    approved=_nist_sources(root,c,fail)
    if c['capability']=='passport':
        from passport_guards import check, ROOTS
        source_roots += [root/name for name in ROOTS]
        passport_sources, problems = check(root)
        approved.update(passport_sources)
        for problem in problems:fail('passport',problem)
    if c['capability']=='document':
        from document_capture_guards import check, ROOTS
        source_roots += [root/name for name in ROOTS if root/name not in source_roots]
        reviewed,problems=check(root)
        approved.update(reviewed)
        for problem in problems:fail('document-capture',problem)
    if c['capability']=='biometric':
        from capture_guards import check as check_capture, CAPTURE, PREVIEW
        source_roots += [root/CAPTURE, root/PREVIEW, root/'ios/Sources/BiometricInference', root/'quality-apple/Sources/BiometricQuality']
        for problem in check_capture(root):fail('capture',problem)
        from native_quality_guards import SOURCES as quality_sources
        approved.update(name for name in quality_sources if name.startswith(('quality-apple/Sources/', 'quality-apple/Tests/')) and name.endswith(SWIFT_SUFFIX))
        from cpp_guards import check as check_cpp
        cpp_sources, cpp_failures = check_cpp(root)
        approved.update(cpp_sources)
        for problem in cpp_failures:fail('cpp',problem)
    for path in files(root):_check_source_file(root,path,source_roots,approved,fail)
    _check_native_roots(root,c,source_roots,fail)
    for mechanism in [_check_swift_graph,_check_android_settings,_check_outcomes]:
        mechanism(root,c,fail)
    for mechanism in [_check_android_gradle,_check_android_manifests,_check_wrapper_and_provenance,_check_quality_configuration]:
        mechanism(root,fail)
    if c['capability']=='biometric':
        _check_embedding_contract(root,c,fail)
        try:_check_dependency_verification(root,fail)
        except (OSError,ValueError,KeyError,ET.ParseError):fail(DEPENDENCY_VERIFICATION,'missing or invalid verification inventory')
    return failures

def inspect_aar(path):
    problems=[]
    with zipfile.ZipFile(path) as archive:
        for name in archive.namelist():
            if BANNED.search(name) or name.startswith(('jni/','assets/')):problems.append('unreviewed packaged dependency/asset: '+name)
            if name.endswith('.jar'):
                with zipfile.ZipFile(io.BytesIO(archive.read(name))) as jar:
                    for entry in jar.namelist():
                        if BANNED.search(entry):problems.append('vendor/product class in packaged artifact')
    return problems

def main(root):
    if len(sys.argv)==3 and sys.argv[1]=='--aar': problems=inspect_aar(Path(sys.argv[2]))
    elif len(sys.argv)==1:problems=scan(root)
    else:raise SystemExit('Usage: capability_guards.py [--aar PATH]')
    for p in problems:print('FAIL '+p)
    if not problems:print('PASS capability source, dependency, provenance, privacy and contract guards')
    return bool(problems)
