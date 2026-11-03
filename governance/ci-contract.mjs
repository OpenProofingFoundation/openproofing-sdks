// Reviewed execution contract for the real root workflow; no path filters or exclusions.
const pins = {
  checkout: 'actions/checkout@11d5960a326750d5838078e36cf38b85af677262',
  node: 'actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020',
  python: 'actions/setup-python@a26af69be951a213d495a4c3e4e4022e16d87065',
  java: 'actions/setup-java@cf277c60eb25467037889841efdb72551f06f6c3',
  android: 'android-actions/setup-android@9fc6c4e9069bf8d3d10b2204b1fb8f6ef7065407',
  upload: 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02',
};

function environmentSteps(lane, androidPlatform = '36') {
  const steps = [
    {uses: pins.checkout, with: {'fetch-depth': 0}},
    {uses: pins.node, with: {'node-version-file': '.node-version'}},
    {uses: pins.python, with: {'python-version-file': '.python-version'}},
  ];
  if (lane === 'android') steps.push(
    {uses: pins.java, with: {distribution: 'temurin', 'java-version': '17'}},
    {uses: pins.android, with: {packages: 'platform-tools', 'log-accepted-android-sdk-licenses': false}},
    {run: `sdkmanager "platforms;android-${androidPlatform}" "build-tools;36.0.0"`},
  );
  return steps;
}

export function expectedWorkflow() {
  const jobs = {};
  for (const lane of ['guards', 'macos', 'ios-device', 'ios-simulator', 'android']) {
    const steps = environmentSteps(lane);
    if (['ios-device', 'ios-simulator'].includes(lane)) steps.push({
      name: 'Install public document sample generator', if: "matrix.sdk == 'document'", run: 'brew install xcodegen',
    });
    steps.push(
      {run: 'npm ci --ignore-scripts'},
      {run: 'python3 scripts/bootstrap.py'},
      {run: 'python3 scripts/check.py --sdk ${{ matrix.sdk }} --platform '+lane},
      {name: 'Preserve scoped QA evidence', if: 'always()', uses: pins.upload, with: {
        name: '${{ matrix.sdk }}-'+lane+'-quality',
        path: '.build/validation/\n${{ matrix.sdk }}/.build/quality/',
        'if-no-files-found': 'error', 'retention-days': 7,
      }},
    );
    jobs[lane] = {
      name: '${{ matrix.sdk }} / '+lane,
      'runs-on': ['guards', 'android'].includes(lane) ? 'ubuntu-24.04' : 'macos-26',
      'timeout-minutes': 45,
      strategy: {'fail-fast': false, matrix: {sdk: ['document', 'passport', 'biometric']}},
      steps,
    };
  }
  jobs['nist-linux'] = {
    name: 'biometric / NIST tooling',
    'runs-on': 'ubuntu-24.04',
    'timeout-minutes': 25,
    steps: [
      {uses: pins.checkout},
      {uses: pins.python, with: {'python-version-file': '.python-version'}},
      {run: 'sudo apt-get update && sudo apt-get install -y --no-install-recommends libssl-dev cmake ninja-build g++-13'},
      {run: 'python3 biometric/nist/check.py --compiler g++-13'},
      {run: 'python3 biometric/cpp/check_inference.py'},
      {name: 'Preserve NIST tooling evidence', if: 'always()', uses: pins.upload, with: {
        name: 'biometric-nist-tooling', path: '.build/nist/\n.build/inference/',
        'if-no-files-found': 'error', 'retention-days': 7,
      }},
    ],
  };
  for (const lane of ['macos', 'ios-device', 'ios-simulator', 'ios-ui', 'android']) {
    const steps = environmentSteps(lane, '37.0');
    steps.push(
      {run: 'npm ci --ignore-scripts'},
      {run: 'python3 scripts/bootstrap.py'},
      {run: 'python3 scripts/check.py --platform guards'},
      {run: 'python3 scripts/presentation_check.py --platform '+lane},
      {name: 'Preserve presentation evidence', if: 'always()', uses: pins.upload, with: {
        name: 'presentation-'+lane, path: '.build/presentation/\n.build/validation/',
        'if-no-files-found': 'error', 'retention-days': 7,
      }},
    );
    jobs['presentation-'+lane] = {
      name: 'presentation / '+lane, 'runs-on': lane === 'android' ? 'ubuntu-24.04' : 'macos-26',
      'timeout-minutes': 45, steps,
    };
  }
  const captureSteps = environmentSteps('ios-simulator');
  captureSteps.push(
    {run: 'npm ci --ignore-scripts'},
    {run: 'python3 scripts/bootstrap.py'},
    {run: 'python3 scripts/check.py --platform guards'},
    {run: 'python3 scripts/capture_check.py'},
    {name: 'Preserve capture evidence', if: 'always()', uses: pins.upload, with: {
      name: 'biometric-capture-ios', path: '.build/capture/',
      'if-no-files-found': 'error', 'retention-days': 7,
    }},
  );
  const documentSteps = environmentSteps('ios-simulator');
  documentSteps.push(
    {run: 'npm ci --ignore-scripts'},
    {run: 'python3 scripts/bootstrap.py'},
    {run: 'python3 scripts/check.py --platform guards'},
    {run: 'python3 scripts/document_capture_check.py'},
    {name: 'Preserve document capture evidence', if: 'always()', uses: pins.upload, with: {
      name: 'document-capture-ios', path: '.build/document-capture/',
      'if-no-files-found': 'error', 'retention-days': 7,
    }},
  );
  jobs['document-capture-ios'] = {name: 'document / capture iOS', 'runs-on': 'macos-26', 'timeout-minutes': 45, steps: documentSteps};
  jobs['capture-ios'] = {
    name: 'biometric / capture iOS', 'runs-on': 'macos-26',
    'timeout-minutes': 45, steps: captureSteps,
  };
  const passportSteps = environmentSteps('ios-simulator');
  passportSteps.push(
    {run: 'npm ci --ignore-scripts'},
    {run: 'python3 scripts/bootstrap.py'},
    {run: 'python3 scripts/check.py --platform guards'},
    {run: 'python3 scripts/passport_check.py'},
    {name: 'Preserve passport evidence', if: 'always()', uses: pins.upload, with: {
      name: 'passport-nfc-ios', path: '.build/passport/',
      'if-no-files-found': 'error', 'retention-days': 7,
    }},
  );
  jobs['passport-ios'] = {
    name: 'passport / NFC iOS', 'runs-on': 'macos-26',
    'timeout-minutes': 45, steps: passportSteps,
  };
  jobs.foundation = {
    name: 'foundation / SwiftPM root', 'runs-on': 'macos-26',
    'timeout-minutes': 20,
    steps: [
      {uses: pins.checkout, with: {'fetch-depth': 0}},
      {uses: pins.python, with: {'python-version-file': '.python-version'}},
      {run: 'python3 foundation/scripts/check.py'},
      {run: 'python3 foundation/motion/check.py'},
      {name: 'Preserve foundation evidence', if: 'always()', uses: pins.upload, with: {
        name: 'foundation-root-swiftpm', path: '.build/foundation-validation/\n.build/foundation-motion/',
        'if-no-files-found': 'error', 'retention-days': 7,
      }},
    ],
  };
  for (const platform of ['ios-device', 'ios-simulator']) {
    jobs['foundation-'+platform] = {
      name: 'foundation / '+platform, 'runs-on': 'macos-26', 'timeout-minutes': 30,
      steps: [
        {uses: pins.checkout, with: {'fetch-depth': 0}},
        {uses: pins.python, with: {'python-version-file': '.python-version'}},
        {run: 'python3 foundation/scripts/check.py --platform '+platform},
        {name: 'Preserve foundation iOS evidence', if: 'always()', uses: pins.upload, with: {
          name: 'foundation-'+platform, path: '.build/foundation-validation/',
          'if-no-files-found': 'error', 'retention-days': 7,
        }},
      ],
    };
  }
  for (const platform of ['macos', 'ios-device', 'ios-simulator']) {
    jobs['pulse-'+platform] = {
      name: 'Pulse service / '+platform, 'runs-on': 'macos-26', 'timeout-minutes': 35,
      steps: [
        {uses: pins.checkout, with: {'fetch-depth': 0}},
        {uses: pins.python, with: {'python-version-file': '.python-version'}},
        {run: 'python3 scripts/pulse_check.py --platform '+platform},
        {name: 'Preserve shared Pulse service evidence', if: 'always()', uses: pins.upload, with: {
          name: 'pulse-'+platform, path: '.build/pulse-validation/',
          'if-no-files-found': 'error', 'retention-days': 7,
        }},
      ],
    };
  }
  for (const platform of ['macos', 'ios-device', 'ios-simulator']) {
    jobs['sensors-'+platform] = {
      name: 'Sensors / '+platform, 'runs-on': 'macos-26', 'timeout-minutes': 25,
      steps: [
        {uses: pins.checkout, with: {'fetch-depth': 0}},
        {uses: pins.python, with: {'python-version-file': '.python-version'}},
        {run: 'python3 foundation/sensors/check.py --platform '+platform},
        {name: 'Preserve Sensors evidence', if: 'always()', uses: pins.upload, with: {
          name: 'sensors-'+platform, path: '.build/sensors-qualification/',
          'if-no-files-found': 'error', 'retention-days': 7,
        }},
      ],
    };
  }
  jobs['licence-check'] = {
    name: 'licence-check / Node packages', 'runs-on': 'ubuntu-24.04', 'timeout-minutes': 20,
    steps: [
      ...environmentSteps('guards'),
      {run: 'python3 quality/licence_check_guards.py'},
      {run: 'npm ci --ignore-scripts', 'working-directory': 'services/licence-check'},
      {run: 'python3 quality/licence_check_guards.py --execute'},
      {name: 'Preserve licence-check evidence', if: 'always()', uses: pins.upload, with: {
        name: 'licence-check-node', path: '.build/licence-check/\nservices/licence-check/.build/consumer/',
        'if-no-files-found': 'error', 'retention-days': 7,
      }},
    ],
  };
  return {
    name: 'SDK quality',
    on: {push: null, pull_request: null, workflow_dispatch: null},
    permissions: {contents: 'read'},
    concurrency: {group: 'sdk-quality-${{ github.workflow }}-${{ github.ref }}', 'cancel-in-progress': '${{ github.event_name == \'pull_request\' }}'},
    jobs,
  };
}
