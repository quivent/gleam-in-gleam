#!/usr/bin/env node
// Stage-0 host IO only. Compiler policy and machine-code generation are Gleam.
// This bridge is not a native/self-hosted compiler and is not the final artifact.
import {readFileSync, writeFileSync} from 'node:fs';
import {BitArray} from './build/dev/javascript/gleam_native/gleam.mjs';
import {compile} from './build/dev/javascript/gleam_native/native/compiler.mjs';

const [source, output, ...rest] = process.argv.slice(2);
if (!source || !output || rest.length) {
  console.error('Usage: node bootstrap.mjs SOURCE.gleam NEW_OUTPUT');
  process.exit(2);
}
try {
  const result = compile(new BitArray(readFileSync(source)));
  if (!result.isOk()) {
    console.error(result[0]);
    process.exitCode = 1;
  } else {
    writeFileSync(output, result[0].rawBuffer, {flag: 'wx', mode: 0o755});
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
