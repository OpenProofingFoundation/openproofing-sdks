import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

import boundary_gates
import capability_guards as guards

class GuardRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config=json.loads((cls.root/'Gates/config.json').read_text())

    @contextlib.contextmanager
    def checkout(self):
        with tempfile.TemporaryDirectory(prefix='capability-guard-test-') as folder:
            monorepo=Path(folder)/'repo'
            root=monorepo/self.root.name
            ignored=shutil.ignore_patterns('.git','.build','.gradle','node_modules','build','__pycache__')
            shutil.copytree(self.root,root,ignore=ignored)
            for shared in ('quality','contracts'):
                shutil.copytree(self.root.parent/shared,monorepo/shared,ignore=ignored)
            if self.config['capability'] == 'document':
                # The public example consumes the real design package. Its exported-product
                # check must see that package graph in the isolated checkout too.
                shutil.copytree(self.root.parent/'design-system',monorepo/'design-system',ignore=ignored)
            if self.config['capability'] == 'biometric':
                app = Path('reference-apps/ios')
                archive = app/'Sources/LegacyVisualArchive'
                shutil.copytree(self.root.parent/archive,monorepo/archive,ignore=ignored)
                shutil.copy2(self.root.parent/app/'project.yml',monorepo/app/'project.yml')
            (monorepo/'governance').mkdir()
            shutil.copy2(self.root.parent/'governance/tooling-lock.json', monorepo/'governance/tooling-lock.json')
            (monorepo/'node_modules').symlink_to(self.root.parent/'node_modules',target_is_directory=True)
            (root/'node_modules').symlink_to(self.root/'node_modules',target_is_directory=True)
            yield root


    def test_system_hashing_does_not_open_mobile_capture_imports(self):
        configured = boundary_gates.configure(boundary_gates.engine(self.root), self.root)
        expected = {'Foundation', 'CryptoKit', 'CoreFoundation'} if self.config['capability'] == 'biometric' else {'Foundation'}
        if self.config['capability'] == 'passport': expected = {'Foundation', 'CryptoKit'}
        self.assertEqual(configured.LEAF_ALLOWED, expected)
        with self.checkout() as root:
            target = root/'ios/Sources'/self.config['swiftModule']/'ForbiddenCapture.swift'
            target.write_text('import AVFoundation\npublic struct ForbiddenCapture {}\n')
            self.assertTrue(boundary_gates.findings(root))

    def test_test_fixture_resource_exception_cannot_redirect_production_sources(self):
        with self.checkout() as root:
            path = root/'android'/self.config['androidModule']/'build.gradle.kts'
            path.write_text(path.read_text()+'\nandroid.sourceSets["main"].java.srcDirs("../../hidden")\n')
            self.assertTrue(guards.scan(root))

    def test_boundary_regexes_preserve_declaration_and_field_captures(self):
        engine=boundary_gates.engine(self.root)
        for declaration in ('struct Value {', 'class Value: Codable, Sendable {',
                            'actor Value\n :\n Sendable \n {'):
            with self.subTest(declaration=declaration):
                match=engine._RECORD_DECL.search(declaration)
                self.assertIsNotNone(match)
                self.assertEqual(match.group(2),'Value')
        match=engine.STORE_CONFORMANCE.search('extension Cache\n: PersistedStore, Sendable {')
        self.assertEqual(match.group(2),'Cache')
        self.assertIn('PersistedStore',match.group(3))
        for field in ('message: string', 'message?: string', 'message \n ? \n : string'):
            self.assertEqual(engine.JS_STRING_FIELD.search(field).group(1),'message')
        self.assertIsNone(engine.JS_STRING_FIELD.search('object.message: string'))

    def test_boundary_regexes_bound_adversarial_missing_delimiters(self):
        # A subprocess timeout bounds regression failures rather than hanging the suite.
        probe='''
import importlib.util
import pathlib
import sys
import tempfile
spec=importlib.util.spec_from_file_location('boundary_engine',sys.argv[1])
engine=importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
for count in (10000,100000):
    assert engine._RECORD_DECL.search('struct A'+' '*count+'!') is None
    assert engine.STORE_CONFORMANCE.search('class A'+' '*count+'!') is None
    assert engine.JS_STRING_FIELD.search('message'+' '*count+'!') is None
    assert engine.JS_STRING_FIELD.search('m'+'a'*count+'!') is None
    with tempfile.TemporaryDirectory() as folder:
        root=pathlib.Path(folder)
        path=root/'Probe.ts'
        path.write_text('class A'+'a'*count)
        engine._rn_source_files=lambda directories,extensions: [path] if '.ts' in extensions else []
        assert engine._package_private_surface({'directories':[root],'directory':root})==(set(),set(),set())
        path.write_text('class Hidden { private constructor() {} }')
        assert engine._package_private_surface({'directories':[root],'directory':root})[1]=={'Hidden'}
'''
        result=subprocess.run([sys.executable,'-c',probe,str(self.root.parent/'quality/upstream/boundary_gates.py')],
                              text=True,capture_output=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_boundary_lexer_preserves_template_holes_and_jsx_code(self):
        engine=boundary_gates.engine(self.root)
        text='const msg = `Hello ${user.name} again ${`Nested ${value}`}!`; // hidden\n'
        masked=engine._rn_mask(text,'ts')
        self.assertIn('user.name',masked)
        self.assertIn('value',masked)
        for authored in ('Hello','again','Nested','hidden'):
            self.assertNotIn(authored,masked)
        self.assertEqual(len(masked),len(text))
        self.assertEqual(masked.count('\n'),text.count('\n'))
        jsx='return <Text>Hello {name}<Strong>Again</Strong></Text>'
        self.assertEqual([body for _,body in engine._jsx_text_runs(jsx)],['Hello ','Again'])
        for code in ('const identity = <T extends Value>(value: T) => value;',
                     'class Thing { private method<T>() {} }'):
            self.assertEqual(engine._jsx_text_runs(code),[])

    def test_clean_checkout_is_guarded(self):
        with self.checkout() as root:
            self.assertEqual(guards.scan(root),[])
            self.assertEqual(boundary_gates.findings(root),[])

    def test_swift_boundary_rejects_ambient_and_prose(self):
        with self.checkout() as root:
            p=root/'ios/Sources'/self.config['swiftModule']/'Probe.swift'
            p.write_text('import Foundation\npublic let now = Date()\npublic let instruction = "Hold the phone steady."\n')
            findings='\n'.join(boundary_gates.findings(root))
            self.assertIn('no_ambient',findings)
            self.assertIn('no_authored_sentence',findings)

    def test_unregistered_store_is_rejected(self):
        with self.checkout() as root:
            p=root/'ios/Sources'/self.config['swiftModule']/'Probe.swift'
            p.write_text('public struct ForgottenStore: PersistedStore {}\n')
            self.assertIn('allStores','\n'.join(boundary_gates.findings(root)))

    def test_private_surface_escape_is_rejected(self):
        with self.checkout() as root:
            self.assertEqual(guards.scan(root),[])
            self.assertEqual(boundary_gates.findings(root),[])
            p=root/'Package.swift'
            original=p.read_text()
            source_path='path: "ios/Sources/'+self.config['swiftModule']+'"'
            self.assertEqual(original.count(source_path),1,'mutation must select the real public leaf')
            mutated=original.replace(source_path,
                source_path+', swiftSettings: [.unsafeFlags(["-enable-testing"])]',1)
            p.write_text(mutated)
            findings=guards.scan(root)
            # Neutral targets reject compiler access overrides through the production
            # package-graph guard. Its diagnostic wording differs by capability.
            self.assertTrue(any(hit.startswith('Package.swift:') for hit in findings),findings)

    def test_missing_target_never_becomes_a_green_zero(self):
        with self.checkout() as root:
            shutil.rmtree(root/'ios/Sources'/self.config['swiftModule'])
            self.assertTrue(boundary_gates.findings(root))
            self.assertIn('required source root missing','\n'.join(guards.scan(root)))

    def test_unowned_source_is_rejected(self):
        with self.checkout() as root:
            (root/'Hidden.kt').write_text('class Hidden')
            self.assertIn('outside guarded production roots','\n'.join(guards.scan(root)))

    def test_production_symlink_is_rejected(self):
        with self.checkout() as root:
            (root/'ios/Sources'/'Hidden').symlink_to(self.root/'ios/Sources',target_is_directory=True)
            self.assertIn('source symlink','\n'.join(guards.scan(root)))

    def test_vendor_dependency_is_rejected(self):
        with self.checkout() as root:
            p=root/'android'/self.config['androidModule']/'build.gradle.kts'
            p.write_text(p.read_text()+'\ndependencies { implementation("com.regula:reader:1.0.0") }\n')
            self.assertIn('vendor/product/service dependency','\n'.join(guards.scan(root)))

    def test_android_source_redirection_is_rejected(self):
        with self.checkout() as root:
            p=root/'android'/self.config['androidModule']/'build.gradle.kts'
            p.write_text(p.read_text()+'\nandroid.sourceSets["main"].java.srcDirs("../../hidden")\n')
            self.assertIn('unreviewed source/dependency','\n'.join(guards.scan(root)))

    def test_new_android_module_is_rejected_until_guarded(self):
        with self.checkout() as root:
            p=root/'android/settings.gradle.kts';p.write_text(p.read_text()+'\ninclude(":hidden")\n')
            self.assertIn('unreviewed project/include graph','\n'.join(guards.scan(root)))

    def test_interpolation_cannot_hide_ambient_access(self):
        self.assertTrue(guards.inspect_kotlin('val hidden = "${System.getenv(\"TOKEN\")}"'))

    def test_kotlin_rules_with_comments_and_multiline_inputs(self):
        rejected={
            'ambient':'val clock = System.currentTimeMillis()',
            'diagnostics':'android.util.Log.d("tag", portraitBytes.toString())',
            'network':'import okhttp3.OkHttpClient',
            'rendering':'import androidx.compose.runtime.Composable',
            'prose channel':'override val message = "Try again."',
            'public surface escape':'val type = Class.forName("Private")',
            'policy number':'const val threshold = 0.38',
            'identity verdict':'fun isIdentityAccepted() = true',
        }
        for name,text in rejected.items():
            with self.subTest(name=name):self.assertIn(name,[rule for rule,_ in guards.inspect_kotlin(text)])
        self.assertEqual(guards.inspect_kotlin('/* outer /* nested */ */\n// System.getenv("secret")\nenum class Outcome { UNAVAILABLE }'),[])
        with self.assertRaises(ValueError):guards.kotlin_mask('/* unfinished')

    def test_outcome_drift_is_rejected(self):
        with self.checkout() as root:
            for p in (root/'android').rglob('*Outcome.kt'):
                p.write_text(p.read_text().replace('"unavailable"','"pass_anyway"'))
            self.assertIn('wire values differ','\n'.join(guards.scan(root)))

    def test_binary_and_privacy_assets_are_rejected(self):
        with self.checkout() as root:
            (root/'fixtures'/'identity.jpg').write_bytes(b'synthetic forbidden asset probe')
            self.assertIn('asset/binary requires rights','\n'.join(guards.scan(root)))

    def test_imported_guard_tampering_is_rejected(self):
        with self.checkout() as root:
            p=root.parent/'quality/upstream/boundary_gates.py';p.write_text(p.read_text()+'\n# changed\n')
            self.assertIn('imported guard changed','\n'.join(guards.scan(root)))

    def test_baseline_cannot_admit_debt(self):
        with self.checkout() as root:
            (root/'Gates/baselines.json').write_text('{"no_ambient": 100}')
            self.assertIn('baseline files cannot suppress','\n'.join(guards.scan(root)))

    def test_ci_cannot_drop_or_soften_lanes(self):
        for before,after in [('  ios-device:\n','  hidden-device:\n'),('    runs-on: macos-26','    if: false\n    runs-on: macos-26'),('      - run: python3 scripts/quality.py','      - run: python3 scripts/quality.py\n        continue-on-error: true')]:
            with self.subTest(after=after),self.checkout() as root:
                p=root/'Gates/native-lanes.yml';p.write_text(p.read_text().replace(before,after,1))
                self.assertIn('quality configuration','\n'.join(guards.scan(root)))

    def test_missing_shared_quality_configuration_is_rejected(self):
        with self.checkout() as root:
            (root.parent/'quality/quality_config.mjs').unlink()
            self.assertIn('quality configuration','\n'.join(guards.scan(root)))

    def test_missing_guard_script_fails(self):
        with self.checkout() as root:
            (root/'scripts/guards/quality-config.mjs').unlink()
            self.assertIn('quality configuration','\n'.join(guards.scan(root)))

    def assert_configuration_rejects(self, root):
        result=subprocess.run(['node','scripts/guards/quality-config.mjs'],cwd=root,text=True,capture_output=True)
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)

    def test_native_entry_point_cannot_hide_or_weaken_required_commands(self):
        original=(self.root/'scripts/check.sh').read_text()
        module=self.config['androidModule']
        mutations={
            'early success':original.replace('set -euo pipefail','set -euo pipefail\nexit 0',1),
            'guard replaced with echo':original.replace('python3 scripts/quality.py','echo python3 scripts/quality.py',1),
            'unit tests replaced with echo':original.replace('  swift test','  echo swift test',1),
            'failure hidden':original.replace('  swift test','  swift test || :',1),
            'device build removed':original.replace('CODE_SIGNING_ALLOWED=NO build','CODE_SIGNING_ALLOWED=NO -showBuildSettings',1),
            'Android tests removed':original.replace(' :'+module+':testDebugUnitTest','',1),
            'AAR inspection replaced with echo':original.replace('  python3 Gates/capability_guards.py --aar','  echo python3 Gates/capability_guards.py --aar',1),
        }
        for lane in ['macos','ios-device','ios-simulator','android']:
            command='  python3 scripts/guards/public_api.py '+lane
            mutations[lane+' API removed']=original.replace(command,'  # '+command,1)
        for label,mutated in mutations.items():
            with self.subTest(label=label),self.checkout() as root:
                self.assertNotEqual(mutated,original,'mutation must affect the real entry point')
                (root/'scripts/check.sh').write_text(mutated)
                self.assert_configuration_rejects(root)

    def test_ci_execution_context_cannot_redirect_required_commands(self):
        original=(self.root/'Gates/native-lanes.yml').read_text()
        mutations={
            'workflow directory':original.replace('jobs:\n','defaults:\n  run:\n    working-directory: /tmp\njobs:\n',1),
            'workflow shell':original.replace('jobs:\n','defaults:\n  run:\n    shell: "bash {0}"\njobs:\n',1),
            'workflow environment':original.replace('jobs:\n','env:\n  BASH_ENV: /tmp/skip.sh\njobs:\n',1),
            'job directory':original.replace('    runs-on: ubuntu-24.04','    defaults:\n      run:\n        working-directory: /tmp\n    runs-on: ubuntu-24.04',1),
            'job environment':original.replace('    runs-on: ubuntu-24.04','    env:\n      PATH: /tmp/tools\n    runs-on: ubuntu-24.04',1),
            'job shell':original.replace('    runs-on: ubuntu-24.04','    defaults:\n      run:\n        shell: "bash {0}"\n    runs-on: ubuntu-24.04',1),
            'step shell':original.replace('      - run: python3 scripts/quality.py','      - run: python3 scripts/quality.py\n        shell: "bash {0}"',1),
            'step environment':original.replace('      - run: python3 scripts/quality.py','      - run: python3 scripts/quality.py\n        env:\n          BASH_ENV: /tmp/skip.sh',1),
            'step directory':original.replace('      - run: python3 scripts/quality.py','      - run: python3 scripts/quality.py\n        working-directory: /tmp',1),
            'event path filter':original.replace('  push:\n','  push:\n    paths: ["never/**"]\n',1),
        }
        for label,mutated in mutations.items():
            with self.subTest(label=label),self.checkout() as root:
                self.assertNotEqual(mutated,original,'mutation must affect the real workflow')
                (root/'Gates/native-lanes.yml').write_text(mutated)
                self.assert_configuration_rejects(root)

    def test_packaged_vendor_classes_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            p=Path(temp)/'test.aar'; data=io.BytesIO()
            with zipfile.ZipFile(data,'w') as jar:jar.writestr('com/regula/Hidden.class',b'synthetic')
            with zipfile.ZipFile(p,'w') as aar:aar.writestr('classes.jar',data.getvalue())
            self.assertTrue(guards.inspect_aar(p))


