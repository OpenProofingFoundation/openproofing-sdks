"""Repinned real-package mutations must not change the reviewed licence execution graph."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('licence_contract', ROOT/'quality/licence_check_guards.py')
GUARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD)


class LicenceCheckContractTests(unittest.TestCase):
    def fixture(self, directory):
        root = Path(directory).resolve()
        for name in GUARD.EXPECTED_FILES | {GUARD.INVENTORY}:
            path = root/name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT/name, path)
        return root

    def repin(self, root, name):
        path = root/GUARD.INVENTORY
        record = json.loads(path.read_text())
        record['files'][name] = hashlib.sha256((root/name).read_bytes()).hexdigest()
        path.write_text(json.dumps(record))

    def mutate_json(self, root, relative, mutate):
        name = GUARD.DIRECTORY+'/'+relative
        path = root/name
        record = json.loads(path.read_text())
        mutate(record)
        path.write_text(json.dumps(record))
        self.repin(root, name)

    def test_registered_packages_pass_without_node_or_typescript(self):
        with mock.patch.object(GUARD.subprocess, 'run') as run:
            self.assertEqual(GUARD.check(ROOT), [])
            run.assert_not_called()
        self.assertEqual(len(GUARD.validate(ROOT)), 33)

    def test_extra_languages_resources_and_nested_build_names_are_not_hidden(self):
        for name in ('core/src/Hidden.c', 'core/src/Hidden.js', 'core/src/Hidden.txt',
                     'core/src/.build/Hidden.ts', 'trusona/test/node_modules/Hidden.ts', 'Hidden.mjs'):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = self.fixture(temporary)
                path = root/GUARD.DIRECTORY/name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('hidden')
                with self.assertRaisesRegex(ValueError, 'closed source inventory'):
                    GUARD.validate(root)

    def test_missing_changed_or_redirected_inputs_fail_closed(self):
        for kind in ('missing', 'changed', 'file-link', 'directory-link', 'root-link'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = self.fixture(temporary)
                path = root/GUARD.DIRECTORY/'core/src/index.ts'
                if kind == 'changed':
                    path.write_text(path.read_text()+'\n// substitution\n')
                elif kind == 'missing':
                    path.unlink()
                elif kind == 'file-link':
                    path.unlink()
                    path.symlink_to(ROOT/GUARD.DIRECTORY/'core/src/index.ts')
                else:
                    folder = root/GUARD.DIRECTORY/('core/src' if kind == 'directory-link' else '')
                    saved = root/'redirected-target'
                    folder.rename(saved)
                    folder.symlink_to(saved, target_is_directory=True)
                self.assertTrue(GUARD.check(root))

    def test_source_policy_cannot_drop_or_reclassify_inputs_and_required_tests(self):
        for kind in ('drop-file', 'escape', 'schema-bool', 'drop-tests'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = self.fixture(temporary)
                path = root/GUARD.INVENTORY
                record = json.loads(path.read_text())
                if kind == 'drop-file':
                    record['files'].pop(next(iter(record['files'])))
                elif kind == 'escape':
                    record['files']['../outside.ts'] = '0'*64
                elif kind == 'schema-bool':
                    record['schemaVersion'] = True
                else:
                    record['requiredTests']['trusona'] -= 1
                path.write_text(json.dumps(record))
                with self.assertRaisesRegex(ValueError, 'reviewed inventory or required tests'):
                    GUARD.validate(root)

    def test_repin_cannot_change_real_package_exports_dependencies_or_execution(self):
        mutations = (
            ('core/package.json', lambda v: v.update(exports={'.': './src/index.ts'})),
            ('core/package.json', lambda v: v.update(files=['..'])),
            ('core/package.json', lambda v: v['scripts'].update(test='node --test --test-name-pattern=one')),
            ('trusona/package.json', lambda v: v['dependencies'].update({'@kenshiki-labs/licence-check': 'file:../core'})),
            ('package.json', lambda v: v['workspaces'].append('hidden')),
            ('package.json', lambda v: v['scripts'].update(check='echo PASS')),
            ('package.json', lambda v: v['scripts'].update(test='npm run test --workspace @kenshiki-labs/licence-check')),
            ('package.json', lambda v: v['scripts'].update(publish='npm publish')),
            ('package.json', lambda v: v['devDependencies'].update(typescript='*')),
        )
        for relative, mutate in mutations:
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as temporary:
                root = self.fixture(temporary)
                self.mutate_json(root, relative, mutate)
                with self.assertRaisesRegex(ValueError, 'reviewed package/dependency/compiler graph'):
                    GUARD.validate(root)

    def test_repin_cannot_weaken_compiler_test_inputs_or_redirect_lock_graph(self):
        mutations = (
            ('core/tsconfig.json', lambda v: v['compilerOptions'].update(noEmit=True)),
            ('trusona/tsconfig.json', lambda v: v['compilerOptions'].update(skipLibCheck=True, outDir='/unreviewed')),
            ('core/tsconfig.test.json', lambda v: v.update(include=['src'])),
            ('package-lock.json', lambda v: v['packages']['node_modules/@kenshiki-labs/licence-check'].update(resolved='../elsewhere')),
            ('package-lock.json', lambda v: v['packages']['node_modules/typescript'].update(integrity='sha512-wrong')),
            ('package-lock.json', lambda v: v['packages'].update({'node_modules/hidden': {'version': '1.0.0'}})),
        )
        for relative, mutate in mutations:
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as temporary:
                root = self.fixture(temporary)
                self.mutate_json(root, relative, mutate)
                with self.assertRaisesRegex(ValueError, 'reviewed package/dependency/compiler graph'):
                    GUARD.validate(root)

    def test_repin_cannot_bypass_check_consumer_scripts_or_shared_vectors(self):
        for relative in GUARD.RUNNER_SHA256:
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as temporary:
                root = self.fixture(temporary)
                name = GUARD.DIRECTORY+'/'+relative
                path = root/name
                path.write_text(path.read_text()+'\n// bypass consumer or historical vectors\n')
                self.repin(root, name)
                with self.assertRaisesRegex(ValueError, 'reviewed executable/vector contract'):
                    GUARD.validate(root)

    def test_duplicate_json_keys_fail_while_graph_formatting_is_inert(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.fixture(temporary)
            name = GUARD.DIRECTORY+'/core/package.json'
            path = root/name
            record = json.loads(path.read_text())
            path.write_text(json.dumps(record, sort_keys=True))
            self.repin(root, name)
            GUARD.validate(root)
            path.write_text(path.read_text().replace('{', '{"type":"module",', 1))
            self.repin(root, name)
            with self.assertRaisesRegex(ValueError, 'Duplicate licence-check JSON key'):
                GUARD.validate(root)

    def report(self, tests=(14, 156), passed=(14, 156), skipped=(0, 0)):
        return ''.join(''.join('ℹ '+key+' '+str(value)+'\n' for key, value in (
            ('tests', tests[index]), ('pass', passed[index]), ('fail', 0), ('cancelled', 0),
            ('skipped', skipped[index]), ('todo', 0))) for index in range(2))

    def test_missing_filtered_failed_skipped_and_extra_execution_cannot_pass(self):
        GUARD.execution_counts(self.report())
        payloads = ('', self.report(tests=(14, 150)), self.report(passed=(14, 150)),
                    self.report(skipped=(0, 1)), self.report(tests=(14, 157)),
                    self.report().replace('ℹ fail 0', 'ℹ fail 1', 1), self.report()+self.report())
        for payload in payloads:
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                GUARD.execution_counts(payload)

    def consumer_fixture(self, root):
        folder = root/GUARD.DIRECTORY/'.build/consumer/attempt-new'
        folder.mkdir(parents=True)
        artifacts = {}
        for name in ('core.tgz', 'trusona.tgz'):
            path = folder/name
            path.write_bytes(b'unit artifact fixture')
            artifacts[str(path)] = GUARD.digest(path)
        record = {'passed': True, 'outcome': {'passed': True, 'assertions': GUARD.ASSERTIONS, 'supplierCalls': 0},
                  'commands': [{'status': 0} for _ in range(5)], 'tarballSHA256': artifacts}
        path = folder/'receipt.json'
        path.write_text(json.dumps(record))
        return path, record

    def test_consumer_evidence_must_be_fresh_complete_and_bind_archives(self):
        for kind in ('stale', 'failed', 'assertions', 'command', 'archive', 'boolean-status', 'boolean-calls'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                path, record = self.consumer_fixture(root)
                GUARD.consumer_evidence(root, set())
                previous = set()
                if kind == 'stale':
                    previous.add(path)
                elif kind == 'failed':
                    record['passed'] = False
                elif kind == 'assertions':
                    record['outcome']['assertions'] = ['unrelated']
                elif kind == 'command':
                    record['commands'].pop()
                elif kind == 'boolean-status':
                    record['commands'][0]['status'] = False
                elif kind == 'boolean-calls':
                    record['outcome']['supplierCalls'] = False
                else:
                    Path(next(iter(record['tarballSHA256']))).write_bytes(b'substituted')
                path.write_text(json.dumps(record))
                with self.assertRaises(ValueError):
                    GUARD.consumer_evidence(root, previous)

    def test_execution_cannot_replace_package_check_with_an_empty_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.execution_fixture(temporary)
            versions = ['v'+(ROOT/'.node-version').read_text().strip(), '10.9.4']
            with mock.patch.object(GUARD, 'checkout_identity', return_value=self.identity(root)), mock.patch.object(
                    GUARD.subprocess, 'check_output', side_effect=versions), mock.patch.object(
                    GUARD.subprocess, 'run') as run, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(GUARD.execute(root), 1)
                self.assertEqual(run.call_args.args[0], ['npm', 'run', 'check'])
                self.assertEqual(run.call_args.kwargs['cwd'], root/GUARD.DIRECTORY)
            receipts = list((root/'.build/licence-check').glob('*/receipt.json'))
            self.assertEqual(len(receipts), 1)
            record = json.loads(receipts[0].read_text())
            self.assertFalse(record['passed'])
            self.assertIn('all required cases', record['error'])

    def execution_fixture(self, directory):
        root = self.fixture(directory)
        for name in ('quality/licence_check_guards.py', '.node-version'):
            path = root/name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT/name, path)
        return root

    def identity(self, root, status=''):
        return {'repository': str(root), 'revision': '1'*40, 'gitStatus': status}

    def execution_record(self, root):
        receipts = list((root/'.build/licence-check').glob('*/receipt.json'))
        self.assertEqual(len(receipts), 1)
        return json.loads(receipts[0].read_text())

    def test_early_validation_and_snapshot_failures_preserve_failed_receipts(self):
        for missing in (GUARD.INVENTORY, GUARD.DIRECTORY+'/core/src/index.ts', 'quality/licence_check_guards.py'):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as temporary:
                root = self.execution_fixture(temporary)
                (root/missing).unlink()
                identity = self.identity(root, ' M rejected-source\n')
                with mock.patch.object(GUARD, 'checkout_identity', return_value=identity), mock.patch.object(
                        GUARD.subprocess, 'run') as run, contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(GUARD.execute(root), 1)
                    run.assert_not_called()
                record = self.execution_record(root)
                self.assertIs(record['passed'], False)
                self.assertIn('Licence-check', record['error'])
                self.assertLessEqual(record['startedEpoch'], record['finishedEpoch'])
                self.assertTrue(record['host']['system'])
                for key, value in identity.items():
                    self.assertEqual(record[key], value)

    def test_missing_git_metadata_cannot_succeed_and_preserves_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.execution_fixture(temporary)
            with mock.patch.object(GUARD, 'checkout_identity', side_effect=subprocess.CalledProcessError(
                    128, ['git', 'rev-parse', 'HEAD'])), mock.patch.object(
                    GUARD.subprocess, 'run') as run, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(GUARD.execute(root), 1)
                run.assert_not_called()
            record = self.execution_record(root)
            self.assertIs(record['passed'], False)
            self.assertIn('CalledProcessError', record['error'])

    def test_checkout_identity_reads_the_requested_repository(self):
        with mock.patch.object(GUARD.subprocess, 'check_output', side_effect=[
                '/synthetic/repository\n', '2'*40+'\n', ' M tracked.ts\n?? new.ts\n']) as git:
            root = Path('/synthetic/repository')
            self.assertEqual(GUARD.checkout_identity(root), {
                'repository': str(root), 'revision': '2'*40, 'gitStatus': ' M tracked.ts\n?? new.ts\n'})
            self.assertEqual([call.args[0] for call in git.call_args_list], [
                ['git', 'rev-parse', '--show-toplevel'], ['git', 'rev-parse', 'HEAD'], ['git', 'status', '--porcelain']])
            self.assertTrue(all(call.kwargs == {'cwd': root, 'text': True} for call in git.call_args_list))

    def stub_package_execution(self, root, stream):
        # Unit fixtures isolate receipt admission; actual package execution remains a separate lane.
        stream.write(self.report())
        self.consumer_fixture(root)
        for package in ('core', 'trusona'):
            folder = root/GUARD.DIRECTORY/package/'dist'
            folder.mkdir()
            for source in (root/GUARD.DIRECTORY/package/'src').glob('*.ts'):
                for extension in ('.js', '.d.ts'):
                    (folder/(source.stem+extension)).write_text('// unit artifact\n')

    def test_receipt_binds_clean_dirty_and_changed_checkouts(self):
        for kind in ('clean', 'dirty', 'changed-revision', 'changed-status'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = self.execution_fixture(temporary)
                identity = self.identity(root, ' M tracked.ts\n' if kind == 'dirty' else '')
                end_identity = dict(identity)
                if kind == 'changed-revision':
                    end_identity['revision'] = '2'*40
                elif kind == 'changed-status':
                    end_identity['gitStatus'] = ' M changed-during-run.ts\n'
                versions = ['v'+(ROOT/'.node-version').read_text().strip(), '10.9.4']
                with mock.patch.object(GUARD, 'checkout_identity', side_effect=[identity, end_identity]), mock.patch.object(
                        GUARD.subprocess, 'check_output', side_effect=versions), mock.patch.object(
                        GUARD.subprocess, 'run', side_effect=lambda *args, **kwargs: self.stub_package_execution(
                            root, kwargs['stdout'])), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(GUARD.execute(root), int(identity != end_identity))
                record = self.execution_record(root)
                for key, value in identity.items():
                    self.assertEqual(record[key], value)
                self.assertEqual(record['endCheckout'], end_identity)
                self.assertEqual(record['checkoutUnchanged'], identity == end_identity)
                self.assertEqual(record['passed'], identity == end_identity)
                self.assertTrue(record['sourceUnchanged'])
                self.assertEqual(len(record['sourceSHA256']), 35)
                self.assertEqual(record['sourceSHA256'], record['endSourceSHA256'])
                self.assertEqual(set(record['host']), {'system', 'release', 'machine', 'python'})
                self.assertTrue(all(record['host'].values()))
                if identity != end_identity:
                    self.assertIn('revision or dirty state changed', record['error'])

    def test_actual_ci_contract_rejects_skipped_redirected_and_unpreserved_licence_lane(self):
        original = (ROOT/'.github/workflows/ci.yml').read_text()
        mutations = (
            original.replace('  licence-check:\n', '  licence-check:\n    if: false\n', 1),
            original.replace('python3 quality/licence_check_guards.py --execute', 'echo python3 quality/licence_check_guards.py --execute', 1),
            original.replace('        working-directory: services/licence-check', '        working-directory: /tmp', 1),
            original.replace('name: licence-check-node', 'name: unrelated', 1),
        )
        script = """import fs from 'node:fs';import assert from 'node:assert/strict';import YAML from 'yaml';
import {expectedWorkflow} from './governance/ci-contract.mjs';
assert.deepEqual(YAML.parse(fs.readFileSync(process.argv[1],'utf8')),expectedWorkflow());"""
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)/'ci.yml'
            for index, value in enumerate((original,)+mutations):
                if index:
                    self.assertNotEqual(value, original, 'Mutation must alter the actual workflow')
                path.write_text(value)
                result = subprocess.run(['node', '--input-type=module', '-e', script, str(path)],
                                        cwd=ROOT, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, index == 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
