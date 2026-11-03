import fs from 'node:fs';
import path from 'node:path';
import YAML from 'yaml';
const products = {
  document: {scheme: 'KenshikiDocumentSDK-Package', androidModule: 'document-sdk'},
  passport: {scheme: 'KenshikiPassportSDK-Package', androidModule: 'passport-sdk'},
  biometric: {scheme: 'KenshikiBiometricSDK-Package', androidModule: 'biometric-sdk'},
};
const expected = {
  guards: ['ubuntu-24.04', 'python3 scripts/quality.py'],
  macos: ['macos-26', 'scripts/check.sh macos'],
  'ios-device': ['macos-26', 'scripts/check.sh ios-device'],
  'ios-simulator': ['macos-26', 'scripts/check.sh ios-simulator'],
  android: ['ubuntu-24.04', 'scripts/check.sh android'],
};
function nativeEntryPoint(scheme, androidModule) {
  const portrait = androidModule === "biometric-sdk";
  const document = androidModule === "document-sdk";
  return [
    "#!/usr/bin/env bash",
    "set -euo pipefail",
    "repo_dir=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")/..\" && pwd)\"",
    "cd \"$repo_dir\"",
    "case \"${1:-all}\" in",
    "  guards|macos|ios-device|ios-simulator|apple|android|all) check_platform=\"${1:-all}\" ;;",
    "  *) echo 'Usage: scripts/check.sh [guards|macos|ios-device|ios-simulator|apple|android|all]' >&2; exit 2 ;;",
    "esac",
    "python3 scripts/quality.py",
    ...(portrait ? [
      "# The local native artifact belongs only to the explicitly checked optional sidecar.",
      "# Plain BiometricSDK SwiftPM consumers never resolve or bootstrap it.",
      "if [[ \"$check_platform\" == macos || \"$check_platform\" == ios-device || \"$check_platform\" == ios-simulator || \"$check_platform\" == apple || \"$check_platform\" == all ]]; then",
      "  python3 tools/native_quality/build.py --ensure",
      "fi",
    ] : []),
    "if [[ \"$check_platform\" == macos || \"$check_platform\" == apple || \"$check_platform\" == all ]]; then",
    ...(document ? ["  python3 scripts/provision_native.py"] : []),
    "  xcodebuild -version",
    "  swift --version",
    ...(document ? ["  python3 scripts/provision_test_assets.py"] : []),
    ...(portrait ? [
      "  rm -f .build/portrait-tests.xml",
      "  swift test --parallel --disable-swift-testing --xunit-output .build/portrait-tests.xml",
      "  python3 ../quality/portrait_evidence.py --platform swift --report .build/portrait-tests.xml",
      "  mkdir -p quality-apple/.build",
      "  rm -f quality-apple/.build/quality-tests.xml",
      "  swift test --package-path quality-apple --parallel --disable-swift-testing --xunit-output \"$repo_dir/quality-apple/.build/quality-tests.xml\"",
      "  python3 ../quality/portrait_evidence.py --platform quality-swift --report quality-apple/.build/quality-tests.xml",
    ] : ["  swift test"]),
    "  python3 scripts/guards/public_api.py macos",
    "fi",
    "if [[ \"$check_platform\" == ios-device || \"$check_platform\" == apple || \"$check_platform\" == all ]]; then",
    ...(document ? ["  python3 scripts/provision_native.py"] : []),
    "  xcodebuild -version",
    `  xcodebuild -scheme ${scheme} -destination "generic/platform=iOS" \\`,
    "    -derivedDataPath \"$repo_dir/.build/ios-device\" CODE_SIGNING_ALLOWED=NO build",
    ...(portrait ? [
      "  cd \"$repo_dir/quality-apple\"",
      "  xcodebuild -scheme KenshikiFaceQuality -destination \"generic/platform=iOS\" \\",
      "    -derivedDataPath \"$repo_dir/quality-apple/.build/ios-device\" CODE_SIGNING_ALLOWED=NO build",
      "  cd \"$repo_dir\"",
    ] : []),
    "  python3 scripts/guards/public_api.py ios-device",
    ...(document ? ["  python3 scripts/check_example.py ios-device"] : []),
    "fi",
    "if [[ \"$check_platform\" == ios-simulator || \"$check_platform\" == apple || \"$check_platform\" == all ]]; then",
    ...(document ? ["  python3 scripts/provision_native.py"] : []),
    "  xcodebuild -version",
    `  xcodebuild -scheme ${scheme} -destination "generic/platform=iOS Simulator" \\`,
    "    -derivedDataPath \"$repo_dir/.build/ios-simulator\" CODE_SIGNING_ALLOWED=NO build",
    ...(portrait ? [
      "  cd \"$repo_dir/quality-apple\"",
      "  xcodebuild -scheme KenshikiFaceQuality -destination \"generic/platform=iOS Simulator\" \\",
      "    -derivedDataPath \"$repo_dir/quality-apple/.build/ios-simulator\" CODE_SIGNING_ALLOWED=NO build",
      "  cd \"$repo_dir\"",
    ] : []),
    "  python3 scripts/guards/public_api.py ios-simulator",
    ...(document ? ["  python3 scripts/check_example.py ios-simulator"] : []),
    "fi",
    "if [[ \"$check_platform\" == android || \"$check_platform\" == all ]]; then",
    "  java -version",
    "  cd \"$repo_dir/android\"",
    `  ./gradlew :${androidModule}:assembleDebug :${androidModule}:lintDebug :${androidModule}:testDebugUnitTest --console=plain`,
    "  cd \"$repo_dir\"",
    ...(portrait ? ["  python3 ../quality/portrait_evidence.py --platform android --report android/biometric-sdk/build/test-results/testDebugUnitTest"] : []),
    "  python3 scripts/guards/public_api.py android",
    `  python3 Gates/capability_guards.py --aar android/${androidModule}/build/outputs/aar/${androidModule}-debug.aar`,
    "fi"
  ].join('\n') + '\n';
}
class QualityConfiguration {
  constructor(root, capability) {
    if (!Object.hasOwn(products, capability)) throw new Error('Unknown capability quality contract');
    this.root = root;
    this.product = products[capability];
    this.problems = [];
  }
  read(name) { return fs.readFileSync(path.join(this.root, name), 'utf8'); }
  fail(message) { this.problems.push(message); }
  rejectExecutionOverrides(record, location, keys) {
    for (const key of keys) if (Object.hasOwn(record ?? {}, key)) this.fail(`${location} cannot override ${key}`);
  }
  checkManifest() {
    JSON.parse(this.read('Gates/config.json'));
    const pkg = JSON.parse(this.read('package.json'));
    if (pkg.private !== true || pkg.scripts?.check !== 'python3 scripts/quality.py') this.fail('Root tooling must be private and npm check must run the quality runner');
  }
  checkWorkflow(workflow) {
    if (!['push', 'pull_request', 'workflow_dispatch'].every(event => Object.hasOwn(workflow.on ?? {}, event))) this.fail('CI must run on push, pull request and manual dispatch');
    if (Object.keys(workflow.permissions ?? {}).join() !== 'contents' || workflow.permissions.contents !== 'read') this.fail('CI requires read-only contents permission');
    this.rejectExecutionOverrides(workflow, 'workflow', ['defaults', 'env']);
    for (const event of ['push', 'pull_request', 'workflow_dispatch']) {
      if (workflow.on?.[event] !== null) this.fail(`${event} must remain unconditional without event filters`);
    }
    if (Object.keys(workflow.jobs ?? {}).sort((left, right) => left.localeCompare(right, 'en')).join() !== Object.keys(expected).sort((left, right) => left.localeCompare(right, 'en')).join()) this.fail('Every required QA lane must remain independently visible');
    for (const [key, [runner, command]] of Object.entries(expected)) this.checkJob(workflow.jobs?.[key], key, runner, command);
  }
  checkJob(job, key, runner, command) {
    if (job?.['runs-on'] !== runner || Object.hasOwn(job, 'if') || Object.hasOwn(job, 'continue-on-error') || job.strategy) {
      this.fail(`Required job ${key} cannot be skipped, softened or matrix-excluded`);
      return;
    }
    this.rejectExecutionOverrides(job, key, ['defaults', 'env', 'container', 'services', 'needs', 'permissions']);
    if (!Number.isInteger(job['timeout-minutes']) || job['timeout-minutes'] > 45) this.fail(`${key} needs a bounded timeout`);
    const steps = job.steps ?? [];
    this.checkRequiredSteps(steps, key, command);
    for (const step of steps) this.checkStep(step, key);
    const upload = steps.find(step => step.uses?.startsWith('actions/upload-artifact@'));
    if (upload?.if !== 'always()' || upload.with?.path !== '.build/quality/') this.fail(`${key} must preserve quality evidence even on failure`);
  }
  checkRequiredSteps(steps, key, command) {
    let previous = -1;
    for (const run of ['npm ci --ignore-scripts', command]) {
      const index = steps.findIndex(step => step.run === run);
      if (index <= previous || Object.hasOwn(steps[index] ?? {}, 'if') || Object.hasOwn(steps[index] ?? {}, 'continue-on-error') || steps[index]?.['working-directory']) this.fail(`${key} must run ${run} unconditionally from the root`);
      previous = index;
    }
  }
  checkStep(step, key) {
    this.rejectExecutionOverrides(step, `${key} step`, ['shell', 'working-directory', 'env']);
    if (Object.hasOwn(step, 'if') && !step.uses?.startsWith('actions/upload-artifact@')) this.fail(`${key} contains a conditional prerequisite`);
    if (Object.hasOwn(step, 'continue-on-error')) this.fail(`${key} contains a softened step`);
    if (step.uses && !/@[0-9a-f]{40}$/.test(step.uses)) this.fail('Action references must pin immutable commits');
  }
  run() {
    this.checkManifest();
    this.checkWorkflow(YAML.parse(this.read('Gates/native-lanes.yml'), {uniqueKeys: true}));
    const {scheme, androidModule} = this.product;
    if (this.read('scripts/check.sh') !== nativeEntryPoint(scheme, androidModule)) this.fail('Native entry point differs from the exact reviewed command template');
    for (const problem of this.problems) console.error(problem);
    if (this.problems.length) process.exitCode = 1;
    else console.log('Quality entry points and mandatory CI lanes are enforced');
  }
}
export function checkQualityConfig(root, capability) { new QualityConfiguration(root, capability).run(); }
