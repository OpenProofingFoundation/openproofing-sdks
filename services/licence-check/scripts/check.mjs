#!/usr/bin/env node
/** Package-local functional checks. Repository governance/host qualification remain separate. */
import { spawnSync } from "node:child_process";
import { lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import ts from "typescript";

export const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export function run(command, args, cwd = root) {
  const child = spawnSync(command, args, { cwd, stdio: "inherit" });
  if (child.status !== 0) throw new Error(`Package check failed: ${command} ${args.join(" ")}`);
}
function files(folder) {
  return readdirSync(folder).flatMap(name => {
    const path = join(folder, name), stat = lstatSync(path);
    if (stat.isSymbolicLink()) throw new Error(`Redirected package source: ${path}`);
    if (stat.isDirectory()) return files(path);
    if (!path.endsWith(".ts")) throw new Error(`Unexpected package source: ${path}`);
    return [path];
  });
}
function validateSource(packageName, path) {
  const source = readFileSync(path, "utf8");
  const tree = ts.createSourceFile(path, source, ts.ScriptTarget.ES2022, true);
  const visit = node => {
    if (ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) {
      const specifier = node.moduleSpecifier?.text;
      if (specifier !== undefined && !/^\.\/[A-Za-z][A-Za-z0-9]*\.js$/.test(specifier)
        && !(packageName === "trusona" && specifier === "@kenshiki-labs/licence-check"))
        throw new Error(`Import outside package boundary: ${path}: ${specifier}`);
    }
    if (ts.isCallExpression(node) && node.expression.kind === ts.SyntaxKind.ImportKeyword)
      throw new Error(`Dynamic import: ${path}`);
    if (ts.isIdentifier(node) && ["process", "globalThis", "require"].includes(node.text))
      throw new Error(`Host access outside package boundary: ${path}: ${node.text}`);
    if (ts.isCallExpression(node)) {
      const called = node.expression.getText(tree);
      if (packageName === "core" && ["fetch", "Date.now", "Math.random"].includes(called))
        throw new Error(`Core host effect: ${path}: ${called}`);
      if (packageName === "trusona" && relative(join(root, packageName), path) !== "src/http.ts" && called === "fetch")
        throw new Error(`Network access outside transport: ${path}`);
    }
    ts.forEachChild(node, visit);
  };
  visit(tree);
}
export function checkBoundaries(packageName) {
  if (!["core", "trusona"].includes(packageName)) throw new Error("Unknown package");
  for (const path of files(join(root, packageName, "src"))) validateSource(packageName, path);
  if (!files(join(root, packageName, "test")).length) throw new Error("Missing tests");
}
export function runTests(packageName) {
  if (!["core", "trusona"].includes(packageName)) throw new Error("Unknown package");
  const packageRoot = join(root, packageName);
  const scratch = join(packageRoot, ".build");
  mkdirSync(scratch, { recursive: true });
  const output = mkdtempSync(join(scratch, "test-"));
  // Own the nearest package scope as well as every emitted test/source file. A stale
  // parent .build/package.json must not reinterpret these ESM artifacts as CommonJS.
  writeFileSync(join(output, "package.json"), JSON.stringify({ type: "module" }));
  run(process.execPath, [join(root, "node_modules/typescript/bin/tsc"), "-p",
    join(packageRoot, "tsconfig.test.json"), "--outDir", output], packageRoot);
  const tests = files(join(packageRoot, "test")).filter(path => path.endsWith(".test.ts"))
    .map(path => join(output, "test", relative(join(packageRoot, "test"), path).replace(/\.ts$/, ".js")));
  if (!tests.length) throw new Error("Missing executable tests");
  run(process.execPath, ["--test", "--test-reporter=spec", ...tests], packageRoot);
}
export function checkPackage(packageName) {
  checkBoundaries(packageName);
  run("npm", ["run", "build"]);
  run("npm", ["run", "test", "--workspace", `@kenshiki-labs/licence-check${packageName === "trusona" ? "-trusona" : ""}`]);
}
if (resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) {
  for (const name of ["core", "trusona"]) checkBoundaries(name);
  run("npm", ["run", "build"]);
  run("npm", ["test"]);
  run(process.execPath, ["scripts/consumer.mjs"]);
  console.log("PASS licence-check functional packages, contract vectors and independent consumer");
}
