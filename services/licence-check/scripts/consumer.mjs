#!/usr/bin/env node
/** Install only packed artifacts into a clean consumer; execute JS and type-check declarations. */
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { root } from "./check.mjs";

const output = join(root, ".build/consumer");
mkdirSync(output, { recursive: true });
const attempt = mkdtempSync(join(output, "attempt-"));
const hash = path => createHash("sha256").update(readFileSync(path)).digest("hex");
function execute(command, args, cwd) {
  const result = spawnSync(command, args, { cwd, encoding: "utf8" });
  writeFileSync(join(attempt, `command-${logs.length}.log`), (result.stdout ?? "")+(result.stderr ?? ""));
  logs.push({ command: [command, ...args], cwd, status: result.status });
  assert.equal(result.status, 0, `${command} failed: ${result.stderr}\n${result.stdout}`);
  return result.stdout;
}
const logs = [];
const receipt = { scope: "Offline independent npm tarball import, declaration consumption and public API composition", passed: false, commands: logs };
try {
  const tarballs = [];
  for (const directory of ["core", "trusona"]) {
    const [packed] = JSON.parse(execute("npm", ["pack", "--ignore-scripts", "--json", "--pack-destination", attempt], join(root, directory)));
    const files = packed.files.map(file => file.path);
    assert.ok(files.includes("dist/index.js") && files.includes("dist/index.d.ts") && files.includes("README.md"));
    assert.ok(files.every(path => path === "package.json" || path === "README.md" || /^dist\/[A-Za-z]+\.(js|d\.ts)$/.test(path)));
    tarballs.push(join(attempt, packed.filename));
  }
  const app = join(attempt, "app");
  mkdirSync(app);
  writeFileSync(join(app, "package.json"), JSON.stringify({ name: "licence-check-consumer", private: true, type: "module" }));
  execute("npm", ["install", "--offline", "--ignore-scripts", "--no-audit", "--no-fund", ...tarballs], app);
  const require = createRequire(join(app, "package.json"));
  for (const name of ["licence-check", "licence-check-trusona"]) {
    const folder = join(app, "node_modules/@kenshiki-labs", name);
    assert.equal(lstatSync(folder).isSymbolicLink(), false);
    assert.equal(realpathSync(join(folder, "dist/index.js")), join(folder, "dist/index.js"));
    assert.throws(() => require.resolve(`@kenshiki-labs/${name}/src/index.js`), { code: "ERR_PACKAGE_PATH_NOT_EXPORTED" });
  }
  const fixture = JSON.parse(readFileSync(join(root, "contracts/trusona-adapter-vectors.json"), "utf8")).vectors[0];
  writeFileSync(join(app, "fixture.json"), JSON.stringify(fixture));
  writeFileSync(join(app, "main.mjs"), `
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {bindsDocumentSubject, requiredChecks} from '@kenshiki-labs/licence-check';
import {trusonaAdapter, trusonaConnection} from '@kenshiki-labs/licence-check-trusona';
const fixture=JSON.parse(readFileSync(new URL('./fixture.json',import.meta.url)));
let calls=0;
const runtime={now:()=>Date.parse('2026-10-11T12:00:00Z'),sleep:async()=>{},fetch:async(_url,init)=>{
  calls++;
  if(init.method==='POST') {assert.equal(JSON.parse(init.body).transactionId,fixture.request.operation_id);return new Response(JSON.stringify(fixture.supplier.create.body),{status:201});}
  return new Response(JSON.stringify(fixture.supplier.reads[0].body),{status:200});
}};
const connection=trusonaConnection('synthetic-no-provider-authority',{});
assert.ok(connection);
const adapter=trusonaAdapter(connection,'full_available',runtime);
const execution=await adapter.execute(fixture.request,Date.parse(fixture.request.expires_at));
assert.equal(execution.kind,'result');assert.equal(calls,2);
assert.equal(execution.result.evaluation.status,'incomplete');
assert.equal(execution.result.checks.street_line1.comparison_scope,'unqualified');
assert.ok(requiredChecks(fixture.request.evidence.document,'full_available').includes('zip4'));
assert.equal(bindsDocumentSubject(execution.result,fixture.request,adapter.profile),true);
const started=Date.parse('2026-10-11T12:00:00Z');
const deadline=started+1000;
for(const clock of [[started,deadline-1],[started,deadline],[started,deadline+1],[started,deadline-1,deadline]]) {
 let reads=0,dispatches=0;
 const boundary=trusonaAdapter(connection,'full_available',{
  now:()=>clock[Math.min(reads++,clock.length-1)],sleep:async()=>{},
  fetch:async()=>{dispatches++;throw new Error('synthetic lost create');}
 });
 const attempted=clock.at(-1)<deadline;
 assert.deepEqual(await boundary.execute(fixture.request,deadline),attempted
  ? {kind:'outcome_unknown',cause:'create_lost',supplierReference:null}
  : {kind:'not_dispatched'});
 assert.equal(dispatches,attempted?1:0);
}
console.log(JSON.stringify({passed:true,assertions:['artifact-import','public-adapter-flow','unqualified-evaluation','bound-subject','pre-dispatch-expiry','post-dispatch-uncertainty'],supplierCalls:0,
resolutions:[import.meta.resolve('@kenshiki-labs/licence-check'),import.meta.resolve('@kenshiki-labs/licence-check-trusona')]}));
`);
  const stdout = execute(process.execPath, ["main.mjs"], app);
  const outcome = JSON.parse(stdout);
  assert.equal(outcome.passed, true);
  assert.equal(outcome.assertions.length, 6);
  assert.deepEqual(outcome.resolutions.map(value => fileURLToPath(value)), ["licence-check", "licence-check-trusona"].map(
    name => join(app, "node_modules/@kenshiki-labs", name, "dist/index.js")));
  writeFileSync(join(app, "types.ts"), `
import {bindsDocumentSubject, type CompareRequest, type LicenseComparisonAdapter} from '@kenshiki-labs/licence-check';
import {trusonaAdapter, trusonaConnection} from '@kenshiki-labs/licence-check-trusona';
const connection=trusonaConnection('synthetic',{});
if (!connection) throw new Error('Invalid connection');
const adapter: LicenseComparisonAdapter=trusonaAdapter(connection,'full_available');
export async function compare(request:CompareRequest) {
 const execution=await adapter.execute(request,Date.parse(request.expires_at));
 return execution.kind==='result' && bindsDocumentSubject(execution.result,request,adapter.profile);
}
`);
  writeFileSync(join(app, "tsconfig.json"), JSON.stringify({ compilerOptions: { target: "ES2022", module: "NodeNext", moduleResolution: "NodeNext", strict: true, noEmit: true, types: [], lib: ["ES2022", "DOM"] }, include: ["types.ts"] }));
  execute(process.execPath, [join(root, "node_modules/typescript/bin/tsc"), "-p", "tsconfig.json"], app);
  Object.assign(receipt, { passed: true, outcome, tarballSHA256: Object.fromEntries(tarballs.map(path => [path, hash(path)])) });
} finally {
  writeFileSync(join(attempt, "receipt.json"), JSON.stringify(receipt, null, 2)+"\n");
  console.log(`${receipt.passed ? "PASS" : "FAIL"} ${join(attempt, "receipt.json")}`);
}
