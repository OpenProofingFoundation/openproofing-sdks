#!/usr/bin/env node
import { checkPackage, runTests } from "../../scripts/check.mjs";
if (process.argv.length === 2) checkPackage("trusona");
else if (process.argv.length === 3 && process.argv[2] === "--tests") runTests("trusona");
else throw new Error("Unknown package check mode");
