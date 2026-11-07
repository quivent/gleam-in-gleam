#!/usr/bin/env node
// Stage-0 host IO only. Compiler policy and machine-code generation are Gleam.
// This bridge is not a native/self-hosted compiler and is not the final artifact.
import {readFileSync, writeFileSync, realpathSync} from 'node:fs';
import {resolve, dirname, relative, sep, isAbsolute} from 'node:path';
import {BitArray, toList} from './build/dev/javascript/gleam_native/gleam.mjs';
import {compile_project, dependencies} from './build/dev/javascript/gleam_native/native/compiler.mjs';
import {Source} from './build/dev/javascript/gleam_native/native/project.mjs';

const [source, output, ...rest] = process.argv.slice(2);
if (!source || !output || !(rest.length === 0 || rest.length === 2 && rest[0] === '--source-root')) {
  console.error('Usage: node bootstrap.mjs SOURCE.gleam NEW_OUTPUT [--source-root DIRECTORY]');
  process.exit(2);
}
try {
  const root = realpathSync(resolve(rest[1] ?? dirname(source)));
  const input = realpathSync(source);
  function withinRoot(path) {
    const name = relative(root, path);
    if (name === '..' || name.startsWith('..' + sep) || isAbsolute(name)) {
      throw new Error('Module source escapes the selected source root');
    }
    return name;
  }
  const entryPath = withinRoot(input);
  if (!entryPath.endsWith('.gleam')) throw new Error('Source must have a .gleam extension');
  const entry = entryPath.slice(0, -6).split(sep).join('/');
  const files = new Map();
  function load(name) {
    if (files.has(name)) return;
    const path = realpathSync(resolve(root, name + '.gleam'));
    withinRoot(path);
    const content = new BitArray(readFileSync(path));
    files.set(name, new Source(name, content));
    // Gleam parses/validates imports. This bridge only follows its file requests;
    // compile_project independently validates cycles and semantic visibility.
    const requested = dependencies(content);
    if (!requested.isOk()) throw new Error(requested[0]);
    for (const dependency of requested[0].toArray()) load(dependency);
  }
  load(entry);
  const result = compile_project(entry, toList([...files.values()]));
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
