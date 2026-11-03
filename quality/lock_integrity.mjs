#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';


const sections = ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies'];
const exactVersion = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;
const digestBytes = { sha256: 32, sha384: 48, sha512: 64 };
class LockIntegrity {
  constructor(root) { this.root = root; this.failures = []; }
  fail(location, rule) { this.failures.push(`${location}: ${rule}`); }
  readJSON(name) {
    try {
      return JSON.parse(readFileSync(resolve(this.root, name), 'utf8'));
    } catch {
      this.fail(name, 'must contain readable JSON');
      return {};
    }
  }

  dependencyMap(value) {
    return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
  }

  readDependencies(record, section, location) {
    const value = record[section];
    if (value !== undefined && (!value || typeof value !== 'object' || Array.isArray(value))) {
      this.fail(`${location} ${section}`, 'must be a dependency map');
    }
    return this.dependencyMap(value);
  }

  inspectDirectDependencies(manifest, packages) {
    const lockedRoot = packages[''] ?? {};
    for (const section of sections) {
      const declared = this.readDependencies(manifest, section, 'package.json');
      const locked = this.readDependencies(lockedRoot, section, 'package-lock.json root');
      for (const name of new Set([...Object.keys(declared), ...Object.keys(locked)])) {
        const location = `package.json ${section}.${name}`;
        const version = declared[name];
        if (typeof version !== 'string' || !exactVersion.test(version)) {
          this.fail(location, 'requires an exact version; ranges, tags and local dependencies are not allowed');
        }
        if (version !== locked[name]) this.fail(location, 'must match the lockfile root declaration');
        if (version !== packages[`node_modules/${name}`]?.version) {
          this.fail(location, 'must match the locked direct package version');
        }
      }
    }
  }

  registryArchive(value) {
    if (typeof value !== 'string') return false;
    try {
      const url = new URL(value);
      return (
        url.protocol === 'https:' &&
        url.hostname === 'registry.npmjs.org' &&
        !url.port &&
        !url.username &&
        !url.password &&
        !url.search &&
        !url.hash &&
        url.pathname.endsWith('.tgz')
      );
    } catch {
      return false;
    }
  }

  strongIntegrity(value) {
    if (typeof value !== 'string' || !value.trim()) return false;
    return value.split(/\s+/).every((token) => {
      const match = /^(sha256|sha384|sha512)-([A-Za-z0-9+/]+={0,2})$/.exec(token);
      if (!match) return false;
      const bytes = Buffer.from(match[2], 'base64');
      return bytes.length === digestBytes[match[1]] && bytes.toString('base64') === match[2];
    });
  }

  inspectPackages(packages) {
    for (const [location, entry] of Object.entries(packages)) {
      if (location === '') continue;
      // There are no authorized file:, workspace:, git or linked packages in this toolchain.
      if (!location.startsWith('node_modules/') || entry?.link) {
        this.fail(location, 'local packages require an explicit reviewed policy change');
      }
      if (!this.registryArchive(entry?.resolved)) this.fail(location, 'requires an HTTPS npm registry archive');
      if (!this.strongIntegrity(entry?.integrity)) this.fail(location, 'requires canonical SHA-256 or stronger SRI');
    }
  }

  run() {
    const manifest = this.readJSON('package.json');
    const lock = this.readJSON('package-lock.json');
    const packages = this.dependencyMap(lock.packages);
    if (lock.lockfileVersion !== 3) this.fail('package-lock.json', 'requires lockfileVersion 3');
    if (!packages['']) this.fail('package-lock.json', 'requires a root package record');
    for (const field of ['name', 'version']) {
      if (
        typeof manifest[field] !== 'string' ||
        manifest[field] !== lock[field] ||
        manifest[field] !== packages['']?.[field]
      ) {
        this.fail(`package.json ${field}`, 'must match both lockfile root records');
      }
    }
    this.inspectDirectDependencies(manifest, packages);
    this.inspectPackages(packages);
    for (const failure of this.failures) console.error(failure);
    if (this.failures.length) process.exitCode = 1;
    else
      console.log(
        `Lock integrity passed: ${Object.keys(packages).length - 1} registry packages; no local dependencies.`,
      );
  }
}
export function checkLockIntegrity(root) { new LockIntegrity(root).run(); }
