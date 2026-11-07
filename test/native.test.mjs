import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, readFileSync, writeFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {BitArray} from '../build/dev/javascript/gleam_native/gleam.mjs';
import {compile} from '../build/dev/javascript/gleam_native/native/compiler.mjs';
import * as oracle from '../build/dev/javascript/gleam_native/oracle.mjs';

const base = readFileSync(new URL('./oracle.gleam', import.meta.url), 'utf8');
function compileResult(source) {
  return compile(new BitArray(Buffer.from(source)));
}
function run(source) {
  const result = compileResult(source);
  assert.equal(result.isOk(), true, result[0]);
  const dir = mkdtempSync(join(tmpdir(), 'gleam-native-proof-'));
  try {
    const executable = join(dir, 'program');
    writeFileSync(executable, result[0].rawBuffer, {mode: 0o755});
    const executed = spawnSync(executable, [], {encoding: 'utf8', timeout: 3000});
    assert.ifError(executed.error);
    return {...executed, bytes: result[0].rawBuffer};
  } finally { rmSync(dir, {recursive: true, force: true}); }
}
function main(body) { return `${base}\npub fn main() -> Nil { ${body}\nNil }`; }
function rendered(value) { return value === undefined ? 'Nil' : value === true ? 'True' : value === false ? 'False' : String(value); }

const cases = [
  ['fibonacci', [0]], ['fibonacci', [1]], ['fibonacci', [10]], ['fibonacci', [16]],
  ['arithmetic', [7, 4, 3]], ['arithmetic', [-7, -4, 3]],
  ['quotient', [12, 0]], ['quotient', [-17, 5]], ['quotient', [17, -5]],
  ['remainder', [12, 0]], ['remainder', [-17, 5]], ['remainder', [17, -5]],
  ['bool_case', [3, 4]], ['bool_case', [4, 4]], ['bool_case', [5, 4]],
  ['integer_case', [-1]], ['integer_case', [0]], ['integer_case', [1]], ['integer_case', [9]],
  ['shadow', [7]], ['chosen_string', [0]], ['chosen_string', [1]], ['unit', []],
];
for (const [name, args] of cases) {
  test(`upstream semantic oracle: ${name}(${args.join(',')})`, () => {
    const result = run(main(`echo ${name}(${args.join(',')})`));
    assert.equal(result.status, 0);
    assert.equal(result.stderr, '');
    assert.equal(result.stdout, rendered(oracle[name](...args)) + '\n');
  });
}

test('short-circuiting does not evaluate the right branch', () => {
  const result = run(main('echo False && { echo "BAD" True }\necho True || { echo "BAD" False }'));
  assert.equal(result.status, 0);
  assert.equal(result.stdout, 'False\nTrue\n');
});
test('argument evaluation order and native calling convention', () => {
  const result = run('fn order(a: Int, b: Int, c: Int) -> Int { a * 100 + b * 10 + c }\npub fn main() -> Nil { echo order(echo 1, echo 2, echo 3) Nil }');
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '1\n2\n3\n123\n');
});
test('checked fixed-width overflow exits rather than silently wrapping', () => {
  const result = run(main('let n = 2147483647 * 2147483647\necho n * 3'));
  assert.equal(result.status, 70);
  assert.equal(result.stdout, '');
});
test('deterministic raw machine code with no interpreter or dynamic linkage', () => {
  const source = 'pub fn main() -> Nil { echo 42 Nil }';
  const first = compileResult(source)[0].rawBuffer;
  const second = compileResult(source)[0].rawBuffer;
  assert.deepEqual(first, second);
  assert.equal(Buffer.from(first.subarray(0, 4)).toString('hex'), '7f454c46');
  assert.equal(first[4], 2); // ELF64
  const b = Buffer.from(first);
  assert.equal(b.readUInt16LE(18), 62); // x86-64
  const count = b.readUInt16LE(56);
  const headers = Array.from({length: count}, (_, i) => ({type: b.readUInt32LE(64 + i * 56), flags: b.readUInt32LE(68 + i * 56)}));
  assert.equal(headers.some(h => h.type === 2 || h.type === 3), false); // DYNAMIC or INTERP
  assert.deepEqual(headers.find(h => h.type === 0x6474e551), {type: 0x6474e551, flags: 6});
});
const rejected = [
  ['return mismatch', 'pub fn main() -> Int { True }', /Type mismatch/],
  ['argument type', 'fn f(a: Int) -> Int { a } pub fn main() -> Int { f(True) }', /Type mismatch/],
  ['argument count', 'fn f(a: Int) -> Int { a } pub fn main() -> Int { f() }', /argument count/],
  ['missing name', 'pub fn main() -> Int { unknown }', /Unknown name/],
  ['duplicate function', 'pub fn main() -> Int { 1 } pub fn main() -> Int { 2 }', /Duplicate function/],
  ['duplicate parameter', 'pub fn main(a: Int, a: Int) -> Int { a }', /Duplicate parameter/],
  ['nonexhaustive', 'pub fn main() -> Int { case 1 { 1 -> 2 } }', /Non-exhaustive/],
  ['branch mismatch', 'pub fn main() -> Int { case True { True -> 1 False -> False } }', /Type mismatch/],
  ['pattern mismatch', 'pub fn main() -> Int { case 1 { True -> 1 _ -> 0 } }', /Type mismatch/],
  ['unknown import', 'import gleam/io pub fn main() -> Nil { Nil }', /not implemented/],
  ['unimplemented ADT', 'type Value { Value } pub fn main() -> Nil { Nil }', /not implemented/],
  ['unterminated string', 'pub fn main() -> String { "hello }', /Unterminated string/],
  ['missing entrypoint', 'fn f() -> Int { 1 }', /Unknown name: main/],
  ['unimplemented literal range', 'pub fn main() -> Int { 2147483648 }', /literal range/],
  ['unimplemented structural equality', 'pub fn main() -> Bool { "a" == "a" }', /not implemented/],
];
for (const [name, source, error] of rejected) {
  test(`rejects without fallback: ${name}`, () => {
    const result = compileResult(source);
    assert.equal(result.isOk(), false);
    assert.match(result[0], error);
  });
}
test('no declared third-party packages', () => {
  const manifest = readFileSync(new URL('../manifest.toml', import.meta.url), 'utf8');
  assert.match(manifest, /packages = \[\s*\]/);
});
