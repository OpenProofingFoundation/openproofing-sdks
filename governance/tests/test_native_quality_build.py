"""Pinned supplier acquisition must reject stale or changed build inputs before compilation."""
import hashlib
import plistlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
import zipfile
import shutil
import subprocess
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('native_quality_recipe_tests', ROOT/'biometric/tools/native_quality/build.py')
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)
ACTUAL_ARCHIVE_PROBE = build.archive_architectures


class NativeQualityBuildTests(unittest.TestCase):
    def source_archive(self, root):
        revision = 'a' * 40
        archive = root/'downloads'/('opencv-'+revision+'.tar.gz')
        archive.parent.mkdir(parents=True)
        with tarfile.open(archive, 'w:gz') as stream:
            for name, payload in [('CMakeLists.txt', b'project(SyntheticDependency)\n'), ('include/header.h', b'#pragma once\n')]:
                member = tarfile.TarInfo('supplier-'+revision+'/'+name)
                member.size = len(payload)
                stream.addfile(member, io.BytesIO(payload))
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        return archive, {'opencv': ('supplier/synthetic', revision, digest)}

    def test_verified_archive_extracts_and_identical_cached_tree_is_reusable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); _, sources = self.source_archive(root)
            with mock.patch.object(build, 'SOURCES', sources), mock.patch.object(build.urllib.request, 'urlretrieve', side_effect=AssertionError('No network in this test')):
                build.acquire(root)
                self.assertEqual((root/'sources/opencv/include/header.h').read_bytes(), b'#pragma once\n')
                build.acquire(root)

    def test_corrupt_archive_is_rejected_even_when_extracted_cache_exists(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); archive, sources = self.source_archive(root)
            with mock.patch.object(build, 'SOURCES', sources):
                build.acquire(root)
                archive.write_bytes(b'corrupt supplier archive')
                with self.assertRaises(ValueError): build.acquire(root)

    def test_modified_cached_source_never_inherits_archive_checksum_provenance(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); _, sources = self.source_archive(root)
            with mock.patch.object(build, 'SOURCES', sources):
                build.acquire(root)
                (root/'sources/opencv/include/header.h').write_text('altered build input')
                with self.assertRaises(ValueError): build.acquire(root)

    def test_added_or_deleted_cached_source_is_rejected(self):
        for mutation in ('extra', 'missing'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); _, sources = self.source_archive(root)
                with mock.patch.object(build, 'SOURCES', sources):
                    build.acquire(root)
                    if mutation == 'extra': (root/'sources/opencv/extra.cpp').write_text('unreviewed source')
                    else: (root/'sources/opencv/include/header.h').unlink()
                    with self.assertRaises(ValueError): build.acquire(root)

    def test_symlinked_cached_source_cannot_point_to_an_unverified_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); _, sources = self.source_archive(root)
            with mock.patch.object(build, 'SOURCES', sources):
                build.acquire(root)
                outside = root/'unverified-header.h'; outside.write_bytes(b'#pragma once\n')
                header = root/'sources/opencv/include/header.h'
                header.unlink(); header.symlink_to(outside)
                with self.assertRaises(ValueError): build.acquire(root)


class NativeQualityRecipeIntegrityTests(unittest.TestCase):
    def setUp(self):
        # Tiny portable fixtures prove structure, not real Mach-O qualification.
        # Actual native builds separately prove each advertised architecture.
        self.archive_probe = mock.patch.object(build, 'archive_architectures', side_effect=self.fixture_architectures)
        self.archive_probe.start()
        self.addCleanup(self.archive_probe.stop)

    @staticmethod
    def fixture_architectures(path):
        return ['arm64'] if path.parent.name == 'ios-arm64' else ['arm64', 'x86_64']

    def runtime_archive(self, root):
        archive = root/'downloads/onnxruntime-1.22.0.zip'; archive.parent.mkdir(parents=True)
        with zipfile.ZipFile(archive, 'w') as stream:
            stream.writestr('runtime/onnxruntime.xcframework/ios-arm64/Headers/onnxruntime_cxx_api.h', b'official-header-fixture')
            stream.writestr('runtime/onnxruntime.xcframework/Info.plist', b'official-runtime-fixture')
        return archive, hashlib.sha256(archive.read_bytes()).hexdigest()

    def test_runtime_and_supplied_headers_must_match_the_pinned_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); _, expected = self.runtime_archive(root)
            with mock.patch.object(build, 'RUNTIME_SHA256', expected):
                verified = build.acquire_runtime(root)
                supplied = root/'supplied-framework'; shutil.copytree(verified, supplied)
                self.assertEqual(build.acquire_runtime(root, supplied), supplied)
                (supplied/'ios-arm64/Headers/onnxruntime_cxx_api.h').write_bytes(b'substituted header')
                with self.assertRaises(ValueError): build.acquire_runtime(root, supplied)
                (verified/'Info.plist').write_bytes(b'altered verified cache')
                with self.assertRaises(ValueError): build.acquire_runtime(root)

    def test_runtime_archive_tampering_is_refused_before_extraction(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); archive, expected = self.runtime_archive(root)
            with mock.patch.object(build, 'RUNTIME_SHA256', expected):
                archive.write_bytes(b'not the pinned archive')
                with self.assertRaises(ValueError): build.acquire_runtime(root)
                self.assertFalse((root/'runtime-verified').exists())

    def versioned_runtime_archive(self, root, mutation=None):
        archive = root/'downloads/onnxruntime-1.22.0.zip'; archive.parent.mkdir(parents=True)
        prefix = 'runtime/onnxruntime.xcframework/macos-arm64/onnxruntime.framework/'
        with zipfile.ZipFile(archive, 'w') as stream:
            stream.writestr(prefix+'Versions/A/Headers/onnxruntime_cxx_api.h', b'verified-versioned-header')
            stream.writestr(prefix+'Versions/A/onnxruntime', b'verified-runtime-binary')
            stream.writestr('runtime/onnxruntime.xcframework/Info.plist', b'verified-runtime-info')
            links = [('Versions/Current', 'A'), ('Headers', 'Versions/Current/Headers'), ('onnxruntime', 'Versions/Current/onnxruntime')]
            if mutation == 'escape': links[1] = ('Headers', '../../../../outside')
            if mutation == 'absolute': links[1] = ('Headers', '/outside')
            for name, target in links:
                member = zipfile.ZipInfo(prefix+name); member.create_system = 3; member.external_attr = 0o120777 << 16
                stream.writestr(member, target)
            if mutation == 'ancestor_write': stream.writestr(prefix+'Headers/injected.h', b'write through link')
        return hashlib.sha256(archive.read_bytes()).hexdigest()

    def test_official_shaped_versioned_runtime_links_preserve_exact_internal_targets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); expected = self.versioned_runtime_archive(root)
            with mock.patch.object(build, 'RUNTIME_SHA256', expected):
                verified = build.acquire_runtime(root)
                framework = verified/'macos-arm64/onnxruntime.framework'
                self.assertTrue((framework/'Headers').is_symlink())
                self.assertEqual((framework/'Headers/onnxruntime_cxx_api.h').read_bytes(), b'verified-versioned-header')
                supplied = root/'supplied'; shutil.copytree(verified, supplied, symlinks=True)
                self.assertEqual(build.acquire_runtime(root, supplied), supplied)
                (supplied/'macos-arm64/onnxruntime.framework/Headers').unlink()
                (supplied/'macos-arm64/onnxruntime.framework/Headers').symlink_to('/outside')
                with self.assertRaises(ValueError): build.acquire_runtime(root, supplied)

    def test_runtime_links_cannot_escape_or_receive_archive_writes_through_ancestors(self):
        for mutation in ('escape', 'absolute', 'ancestor_write'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); expected = self.versioned_runtime_archive(root, mutation)
                with mock.patch.object(build, 'RUNTIME_SHA256', expected):
                    with self.assertRaises(ValueError): build.acquire_runtime(root)
                    self.assertFalse((root/'runtime-verified').exists())

    def test_source_archive_traversal_duplicate_and_link_members_are_rejected(self):
        for mutation in ('traversal', 'duplicate', 'link'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); archive = root/'unsafe.tar.gz'
                with tarfile.open(archive, 'w:gz') as stream:
                    member = tarfile.TarInfo('supplier/file'); member.size = 1
                    stream.addfile(member, io.BytesIO(b'x'))
                    if mutation == 'traversal': member = tarfile.TarInfo('supplier/../escape')
                    elif mutation == 'duplicate': member = tarfile.TarInfo('supplier/file')
                    else:
                        member = tarfile.TarInfo('supplier/link'); member.type = tarfile.SYMTYPE; member.linkname = '../outside'
                    stream.addfile(member)
                with self.assertRaises(ValueError): build.extract_archive(archive, root/'extracted')
                self.assertFalse((root/'extracted').exists())
                self.assertFalse((root/'escape').exists())

    def artifact(self, root):
        artifact = root/'OFIQNative.xcframework'; artifact.mkdir()
        libraries = []
        for name, platform, variant in [('ios-arm64', 'ios', None), ('ios-arm64_x86_64-simulator', 'ios', 'simulator'), ('macos-arm64_x86_64', 'macos', None)]:
            folder = artifact/name; (folder/'Headers').mkdir(parents=True)
            magic = b'!<arch>\n' if variant is None and platform == 'ios' else b'\xca\xfe\xba\xbe'
            (folder/'libOFIQNative.a').write_bytes(magic+b'synthetic-structural-fixture')
            shutil.copyfile(build.CAPABILITY/'cpp/quality/include/ofiq_native.h', folder/'Headers/ofiq_native.h')
            (folder/'Headers/module.modulemap').write_text('module OFIQNative { header "ofiq_native.h" export * link "c++" link "z" }\n')
            row = {'LibraryIdentifier': name, 'LibraryPath': 'libOFIQNative.a', 'HeadersPath': 'Headers',
                'SupportedPlatform': platform, 'SupportedArchitectures': self.fixture_architectures(folder/'libOFIQNative.a')}
            if variant: row['SupportedPlatformVariant'] = variant
            libraries.append(row)
        (artifact/'Info.plist').write_bytes(plistlib.dumps({'AvailableLibraries': libraries,
            'CFBundlePackageType': 'XFWK', 'XCFrameworkFormatVersion': '1.0'}))
        receipt = {'platforms': list(build.PLATFORMS), 'runtimeArchiveSHA256': build.RUNTIME_SHA256,
            'recipeSHA256': build.digest(Path(build.__file__)),
            'bridgeSHA256': build.digest(build.CAPABILITY/'cpp/quality/ofiq_bridge.cpp'),
            'headerSHA256': build.digest(build.CAPABILITY/'cpp/quality/include/ofiq_native.h'),
            'profileSHA256': build.digest(Path(build.__file__).with_name('profile.json')),
            'members': build.file_inventory(artifact)}
        authored = {key: receipt[key] for key in ('recipeSHA256', 'bridgeSHA256', 'headerSHA256', 'profileSHA256')}
        receipt['buildInputsAtStart'] = dict(authored)
        receipt['buildInputsAtEnd'] = dict(authored)
        return artifact, receipt

    def test_cached_artifact_change_addition_deletion_and_symlink_cannot_reuse_receipt(self):
        for mutation in ('changed', 'extra', 'missing', 'symlink'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); artifact, receipt = self.artifact(root)
                self.assertTrue(build.validate_cached_artifact(artifact, receipt))
                library = artifact/'ios-arm64/libOFIQNative.a'
                if mutation == 'changed': library.write_bytes(b'changed-library')
                elif mutation == 'extra': (artifact/'extra.a').write_bytes(b'not in receipt')
                elif mutation == 'missing': library.unlink()
                else:
                    outside = root/'outside.a'; outside.write_bytes(library.read_bytes()); library.unlink(); library.symlink_to(outside)
                self.assertFalse(build.validate_cached_artifact(artifact, receipt))

    def test_cached_artifact_requires_all_platforms_and_current_recipe_bridge_profile_header_runtime(self):
        with tempfile.TemporaryDirectory() as temporary:
            artifact, receipt = self.artifact(Path(temporary))
            for key in ('recipeSHA256', 'bridgeSHA256', 'headerSHA256', 'profileSHA256', 'runtimeArchiveSHA256'):
                with self.subTest(key=key):
                    modified = dict(receipt, **{key: '0' * 64})
                    self.assertFalse(build.validate_cached_artifact(artifact, modified))
            self.assertFalse(build.validate_cached_artifact(artifact, dict(receipt, platforms=['ios-device'])))
            self.assertFalse(build.validate_cached_artifact(artifact, dict(receipt, platforms=['unreviewed'])))

    def test_missing_or_changed_before_after_build_inputs_cannot_qualify_cached_artifact(self):
        with tempfile.TemporaryDirectory() as temporary:
            artifact, receipt = self.artifact(Path(temporary))
            self.assertTrue(build.validate_cached_artifact(artifact, receipt))
            for key in ('buildInputsAtStart', 'buildInputsAtEnd'):
                changed = dict(receipt); changed.pop(key)
                self.assertFalse(build.validate_cached_artifact(artifact, changed))
                changed = dict(receipt); changed[key] = dict(receipt[key], bridgeSHA256='0' * 64)
                self.assertFalse(build.validate_cached_artifact(artifact, changed))

    def test_artifact_structure_cannot_be_forged_by_repinning_members_or_platform_labels(self):
        for mutation in ('missing_info', 'single_platform', 'wrong_platform', 'wrong_architecture', 'foreign_header', 'foreign_modulemap', 'not_archive', 'empty'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                artifact, receipt = self.artifact(Path(temporary))
                info = artifact/'Info.plist'
                if mutation == 'missing_info': info.unlink()
                elif mutation in ('single_platform', 'wrong_platform', 'wrong_architecture'):
                    data = plistlib.loads(info.read_bytes())
                    if mutation == 'single_platform': data['AvailableLibraries'] = data['AvailableLibraries'][:1]
                    elif mutation == 'wrong_platform': data['AvailableLibraries'][0]['SupportedPlatform'] = 'watchos'
                    else: data['AvailableLibraries'][0]['SupportedArchitectures'] = ['x86_64']
                    info.write_bytes(plistlib.dumps(data))
                elif mutation == 'foreign_header': (artifact/'ios-arm64/Headers/ofiq_native.h').write_bytes(b'foreign ABI')
                elif mutation == 'foreign_modulemap': (artifact/'ios-arm64/Headers/module.modulemap').write_text('module Unreviewed {}')
                elif mutation == 'not_archive': (artifact/'ios-arm64/libOFIQNative.a').write_bytes(b'not an ar archive')
                else:
                    for path in list(artifact.iterdir()):
                        if path.is_dir(): shutil.rmtree(path)
                        else: path.unlink()
                receipt['members'] = build.file_inventory(artifact)
                self.assertFalse(build.validate_cached_artifact(artifact, receipt))

    def test_universal_simulator_and_macos_require_both_actual_and_advertised_architectures(self):
        for platform_index in (1, 2):
            for architectures in (['arm64'], ['x86_64'], ['arm64', 'arm64', 'x86_64'], ['arm64', 'x86_64', 'arm64e'], []):
                with self.subTest(platform_index=platform_index, architectures=architectures), tempfile.TemporaryDirectory() as temporary:
                    artifact, receipt = self.artifact(Path(temporary))
                    info = artifact/'Info.plist'; data = plistlib.loads(info.read_bytes())
                    data['AvailableLibraries'][platform_index]['SupportedArchitectures'] = architectures
                    info.write_bytes(plistlib.dumps(data)); receipt['members'] = build.file_inventory(artifact)
                    self.assertFalse(build.validate_cached_artifact(artifact, receipt))
        with tempfile.TemporaryDirectory() as temporary:
            artifact, receipt = self.artifact(Path(temporary))
            info = artifact/'Info.plist'; data = plistlib.loads(info.read_bytes())
            for row in data['AvailableLibraries']: row['SupportedArchitectures'].reverse()
            info.write_bytes(plistlib.dumps(data)); receipt['members'] = build.file_inventory(artifact)
            self.assertTrue(build.validate_cached_artifact(artifact, receipt))
            for actual in (['arm64'], ['x86_64'], ['arm64', 'arm64', 'x86_64'], ['arm64', 'x86_64', 'arm64e'], []):
                with self.subTest(actual=actual), mock.patch.object(build, 'archive_architectures', side_effect=lambda path: ['arm64'] if path.parent.name == 'ios-arm64' else actual):
                    self.assertFalse(build.validate_cached_artifact(artifact, receipt))

    def test_claimed_universal_architectures_cannot_hide_thin_archive_or_probe_failure(self):
        for identifier in ('ios-arm64_x86_64-simulator', 'macos-arm64_x86_64'):
            with self.subTest(identifier=identifier), tempfile.TemporaryDirectory() as temporary:
                artifact, receipt = self.artifact(Path(temporary))
                library = artifact/identifier/'libOFIQNative.a'
                library.write_bytes(b'!<arch>\nthin-library-with-claimed-universal-metadata')
                receipt['members'] = build.file_inventory(artifact)
                self.assertFalse(build.validate_cached_artifact(artifact, receipt))
        with tempfile.TemporaryDirectory() as temporary:
            artifact, receipt = self.artifact(Path(temporary))
            with mock.patch.object(build, 'archive_architectures', side_effect=ValueError('Unreadable actual architecture')):
                self.assertFalse(build.validate_cached_artifact(artifact, receipt))
            with mock.patch.object(build, 'archive_architectures', side_effect=subprocess.CalledProcessError(1, ['xcrun', 'lipo'])):
                self.assertFalse(build.validate_cached_artifact(artifact, receipt))

    def test_archive_architecture_probe_reads_actual_library_with_argument_boundaries(self):
        library = Path('/private/tmp/library folder/libOFIQNative.a')
        with mock.patch.object(build.subprocess, 'check_output', return_value='x86_64 arm64\n') as command:
            self.assertEqual(ACTUAL_ARCHIVE_PROBE(library), ['x86_64', 'arm64'])
            command.assert_called_once_with(['xcrun', 'lipo', '-archs', str(library)], text=True)

    def test_thin_architecture_builds_use_separate_configuration_and_output_paths(self):
        self.assertEqual(build.ARCHITECTURES, {'ios-device': ('arm64',),
            'ios-simulator': ('arm64', 'x86_64'), 'macos': ('arm64', 'x86_64')})
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); patched = root/'patched'; patched.mkdir()
            (patched/'OFIQlib/modules').mkdir(parents=True)
            (patched/'OFIQlib/probe.cpp').write_text('int fixture;\n')
            for platform, runtime_slice in [('ios-simulator', 'ios-arm64_x86_64-simulator'), ('macos', 'macos-arm64_x86_64')]:
                headers = root/'runtime'/runtime_slice/'onnxruntime.framework/Headers'
                headers.mkdir(parents=True); (headers/'onnxruntime_cxx_api.h').write_text('// fixture\n')
                outputs = []
                with mock.patch.object(build.subprocess, 'check_output', return_value='/fixture-sdk\n'), mock.patch.object(build, 'run') as commands:
                    for architecture in ('arm64', 'x86_64'):
                        opencv, _ = build.opencv(root, platform, 'cmake', 'ninja', 2, architecture)
                        for name in ['core', 'calib3d', 'imgproc', 'dnn', 'ml', 'features2d', 'flann']:
                            path = opencv/'lib'/('libopencv_'+name+'.a'); path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b'!<arch>\n')
                        protobuf = opencv/'3rdparty/lib/liblibprotobuf.a'; protobuf.parent.mkdir(parents=True); protobuf.write_bytes(b'!<arch>\n')
                        outputs.append(build.native(root, platform, patched, opencv, root/'runtime', 'cmake', 'ninja', 2, architecture))
                    self.assertNotEqual(outputs[0], outputs[1])
                    configure = [call.args[0] for call in commands.call_args_list if '-G' in call.args[0]]
                    self.assertEqual(len(configure), 4)
                    self.assertEqual([next(str(value) for value in command if str(value).startswith('-DCMAKE_OSX_ARCHITECTURES=')) for command in configure],
                        ['-DCMAKE_OSX_ARCHITECTURES=arm64'] * 2 + ['-DCMAKE_OSX_ARCHITECTURES=x86_64'] * 2)
                    directories = [command[command.index('-B')+1] for command in configure]
                    self.assertEqual(len(set(directories)), 4)

    def test_pristine_ofiq_cache_is_verified_before_reapplying_bounded_patches(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); revision = 'a' * 40
            archive = root/'downloads'/('ofiq-'+revision+'.tar.gz'); archive.parent.mkdir(parents=True)
            payloads = {'OFIQlib/modules/landmarks/src/adnet_landmarks.cpp': b'Ort::SessionOptions{nullptr}; std::vector<const char*> outputNames; outputName.release(); inputName.release();',
                'OFIQlib/modules/segmentations/src/ONNXRTSegmentation.cpp': b'Ort::SessionOptions{ nullptr }; std::vector<const char*> outputNames; outputName.release(); inputName.release();',
                'OFIQlib/modules/poseEstimators/src/HeadPose3DDFAV2.cpp': b'Ort::SessionOptions{nullptr};',
                'OFIQlib/src/OFIQInitialization.cpp': b'networks.release();'}
            with tarfile.open(archive, 'w:gz') as stream:
                for name, payload in payloads.items():
                    member = tarfile.TarInfo('supplier/'+name); member.size = len(payload)
                    stream.addfile(member, io.BytesIO(payload))
            sources = {'ofiq': ('supplier/ofiq', revision, build.digest(archive))}
            with mock.patch.object(build, 'SOURCES', sources):
                build.acquire(root)
                patched = build.prepare_ofiq(root)
                content = (patched/'OFIQlib/modules/landmarks/src/adnet_landmarks.cpp').read_text()
                self.assertIn('outputNameOwners.push_back(std::move(outputName));', content)
                self.assertNotIn('outputName.release();', content)
                self.assertIn('options.SetIntraOpNumThreads(1)', (patched/'kenshiki_ofiq_options.h').read_text())
                pristine = root/'sources/ofiq/OFIQlib/src/OFIQInitialization.cpp'
                pristine.write_bytes(b'altered cached source')
                with self.assertRaises(ValueError): build.prepare_ofiq(root)
