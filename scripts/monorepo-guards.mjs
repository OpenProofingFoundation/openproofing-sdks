#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {isDeepStrictEqual} from 'node:util';
import YAML from 'yaml';
import {expectedWorkflow} from '../governance/ci-contract.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const failures = [];
const fail = message => failures.push(message);
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
const json = name => JSON.parse(read(name));
const products = ['document', 'passport', 'biometric'];
const registry = json('sdks.json');
if (registry.schemaVersion !== 1 || !isDeepStrictEqual(Object.keys(registry.products ?? {}).sort((left, right) => left.localeCompare(right, 'en')), [...products].sort((left, right) => left.localeCompare(right, 'en')))) fail('Exactly three declared capability products are required');
for (const name of products) {
  const product = registry.products?.[name];
  if (product?.path !== name || !/^\d+\.\d+\.\d+$/.test(product.version) || !isDeepStrictEqual(product.dependencies, [])) fail(name+': product identity/version/independent dependency contract changed');
  const config = json(name+'/Gates/config.json');
  if (product.swiftProduct !== config.swiftModule || product.androidModule !== config.androidModule) fail(name+': registry and native products differ');
  for (const file of ['Package.swift', 'android/settings.gradle.kts', 'AGENTS.md', 'CLAUDE.md', 'Gates/native-lanes.yml', 'scripts/check.sh']) {
    if (!fs.existsSync(path.join(root, name, file))) fail(name+': missing required package/QA/guidance file '+file);
  }
  for (const file of ['AGENTS.md', 'CLAUDE.md']) {
    if (!read(name+'/'+file).includes('../governance/architecture/APP-ARCH-001.md') || !read(name+'/'+file).includes('revision 0.2')) fail(name+': missing current architecture adoption in '+file);
  }
}
const pkg = json('package.json');
if (pkg.private !== true || pkg.scripts?.check !== 'bash scripts/python.sh scripts/check.py --platform guards' || pkg.scripts?.bootstrap !== 'bash scripts/python.sh scripts/bootstrap.py') fail('Root package must use the complete reviewed tooling entry points');
const pythonVersion = read('.python-version').trim();
if (!/^3\.\d+\.\d+$/.test(pythonVersion)) fail('Python requires an exact stable patch pin');
const sonarProperties = read('.sonarcloud.properties').split(/\r?\n/).filter(line => line.trim() && !line.trim().startsWith('#'));
if (!isDeepStrictEqual(sonarProperties, ['sonar.python.version='+pythonVersion.split('.').slice(0, 2).join('.')])) fail('Sonar Python target must match the runtime pin without analysis exclusions');
const workflow = YAML.parse(read('.github/workflows/ci.yml'), {uniqueKeys: true});
if (!isDeepStrictEqual(workflow, expectedWorkflow())) fail('Executed root CI differs from the reviewed complete three-product/five-lane contract');
if (!isDeepStrictEqual(fs.readdirSync(path.join(root, '.github/workflows')).sort((left, right) => left.localeCompare(right, 'en')), ['ci.yml'])) fail('Unreviewed workflow requires inventory/permission/QA review');
const imported = json('governance/imports.json');
for (const [name, expected] of Object.entries(imported.referenceSnapshotSHA256)) {
  if (!name.startsWith('governance/references/') || name.split('/').includes('..')) {fail('Invalid reference snapshot path'); continue;}
  if (!fs.existsSync(path.join(root, name)) || crypto.createHash('sha256').update(fs.readFileSync(path.join(root, name))).digest('hex') !== expected) fail('Frozen reference changed without provenance review: '+name);
}
const tooling = json('governance/tooling-lock.json');
const presentationSources = json('governance/presentation-sources.json').sources;
const foundationSources = json('foundation/sources.json').sources;
const pulseSources = json('services/pulse/sources.json').sources;
const licenceSources = json('services/licence-check/sources.json').files;
const foundationDependencies = json('foundation/dependencies.json');
for (const name of ['gradlew', 'gradlew.bat', 'gradle/wrapper/gradle-wrapper.jar', 'gradle/wrapper/gradle-wrapper.properties']) {
  if (!Object.hasOwn(tooling, 'reference-apps/android/'+name)) fail('Unregistered reference Gradle bootstrap: '+name);
}
for (const [name, expected] of Object.entries(tooling)) {
  if (!fs.existsSync(path.join(root, name)) || crypto.createHash('sha256').update(fs.readFileSync(path.join(root, name))).digest('hex') !== expected) fail('Execution tooling changed without reviewed lock update: '+name);
}
const prune = new Set(['.git', '.build', '.gradle', 'build', 'node_modules', '__pycache__', '.swiftpm', 'DerivedData']);
const native = /\.(swift|kt|java|cpp|c|h|hpp|mm|m)$/i;
const researchPDFs = new Set(json('governance/research/manifest.json').papers.map(entry => 'governance/research/'+entry.localPath));
const assets = /\.(pdf|onnx|mlmodel|mlmodelc|mlpackage|tflite|pt|pth|safetensors|jpg|jpeg|png|heic|bin|aar|jar|pem|p12|key)$/i;
function inspectFile(name) {
  if (name.startsWith('quality/') && !Object.hasOwn(tooling, name)) fail('Unregistered shared QA source: '+name);
  const capability = products.some(product => name.startsWith(product+'/'));
  if (native.test(name) && !capability && !Object.hasOwn(presentationSources, name) && !Object.hasOwn(foundationSources, name) && !Object.hasOwn(pulseSources, name)) fail('Native source outside registered capability guard coverage: '+name);
  if (/\.(?:[cm]?ts|tsx)$/i.test(name) && !Object.hasOwn(licenceSources, name)) fail('TypeScript source outside registered licence-check coverage: '+name);
  if (assets.test(name) && !researchPDFs.has(name) && ![...products.map(product => product+'/android/gradle/wrapper/gradle-wrapper.jar'), 'reference-apps/android/gradle/wrapper/gradle-wrapper.jar'].includes(name)) fail('Unreviewed binary/model/identity asset: '+name);
}
function walk(folder) {
  for (const entry of fs.readdirSync(path.join(root, folder), {withFileTypes: true})) {
    if (prune.has(entry.name)) continue;
    const name = path.posix.join(folder, entry.name);
    if (entry.isSymbolicLink()) {fail('Unreviewed source symlink: '+name); continue;}
    if (entry.isDirectory() && /^services\/licence-check\/(?:core|trusona)\/dist$/.test(name)) continue;
    if (entry.isDirectory()) {walk(name); continue;}
    inspectFile(name);
  }
}
walk('');
for (const name of Object.keys(foundationSources)) {
  if ((name !== 'Package.swift' && !name.startsWith('foundation/')) || !fs.existsSync(path.join(root, name))) fail('Invalid foundation source inventory: '+name);
}
for (const name of Object.keys(pulseSources)) {
  if (!name.startsWith('services/pulse/') || name.split('/').includes('..') || !fs.existsSync(path.join(root, name))) fail('Invalid Pulse adapter source inventory: '+name);
}
for (const [name, expected] of Object.entries(licenceSources)) {
  if (!name.startsWith('services/licence-check/') || name.split('/').includes('..') || !fs.existsSync(path.join(root, name))) fail('Invalid licence-check source inventory: '+name);
  if (tooling[name] !== expected) fail('Licence-check source missing reviewed tooling registration: '+name);
}
for (const name of Object.keys(foundationSources).filter(name => name.includes('/Sources/'))) {
  const imports = [...read(name).matchAll(/^\s*(?:@[^\n]+?\s+)?import\s+(\w+)/gm)].map(match => match[1]);
  const override = Object.entries(foundationDependencies.importOverrides).find(([scope]) => name === scope || (scope.endsWith('/') && name.startsWith(scope)));
  const allowed = override ? override[1] : foundationDependencies.defaultImports;
  if (imports.some(module => !allowed.includes(module))) fail('Forbidden foundation dependency: '+name);
}
for (const failure of failures) console.error('FAIL '+failure);
if (failures.length) process.exitCode = 1;
else console.log('PASS monorepo products, actual CI execution, tooling, provenance and source/data inventory');
