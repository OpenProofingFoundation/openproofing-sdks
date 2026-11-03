#!/usr/bin/env node
import { checkPackage, runTests } from "../../scripts/check.mjs";
if (process.argv.length === 2) checkPackage("core");
else if (process.argv.length === 3 && process.argv[2] === "--tests") runTests("core");
else throw new Error("Unknown package check mode");
