import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, readFileSync, writeFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {BitArray} from '../build/dev/javascript/gleam_native/gleam.mjs';
import {compile} from '../build/dev/javascript/gleam_native/native/compiler.mjs';
import * as oracle from '../build/dev/javascript/gleam_native/oracle.mjs';
import {probe} from '../build/dev/javascript/gleam_native/allocator_probe.mjs';

const base = readFileSync(new URL('./oracle.gleam', import.meta.url), 'utf8');
function compileResult(source) {
  return compile(new BitArray(Buffer.from(source)));
}
function run(source) {
  return runBinary(compileResult(source));
}
function runBinary(result) {
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
  ['list_work', [1]], ['list_work', [-2]], ['tuple_work', [3]],
  ['nested_pattern', [7]], ['chosen_list_sum', [0]], ['chosen_list_sum', [5]],
  ['custom_tree', [1]], ['custom_tree', [-3]], ['custom_option', [0]],
  ['custom_option', [6]], ['custom_destructure', [4]], ['custom_nested', [1]],
  ['custom_known', [7]], ['custom_result', [0]], ['custom_result', [8]], ['custom_public', [9]],
  ['generic_maybe', [0]], ['generic_maybe', [8]], ['generic_bool', [-1]], ['generic_bool', [2]],
  ['generic_duo', [3]], ['generic_duo', [-2]], ['generic_same', [5]],
  ['generic_recursive', [4]], ['generic_phantom', [7]],
  ['labelled_generic', [3]], ['labelled_pattern', [4]], ['labelled_spread', [5]],
  ['labelled_shorthand', [6]], ['labelled_common', [7]], ['labelled_known', [8]],
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
test('tuple/list fields evaluate left-to-right and list tails stay persistent', () => {
  const result = run(main(`
    let tail = [3]
    let xs = [echo 1, echo 2, ..{ echo 4 tail }]
    let pair = #(echo 5, echo 6)
    let #(first, second) = pair
    echo first + second
    echo list_sum(xs)
    echo list_sum(tail)
  `));
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '1\n2\n4\n5\n6\n11\n6\n3\n');
});
test('empty list annotations and nested empty-list refinement', () => {
  const result = run(main(`
    let empty: List(Int) = []
    echo list_sum(empty)
    let nested = [[], [7]]
    echo case nested {
      [[], [n]] -> n
      _ -> -1
    }
  `));
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '0\n7\n');
});
test('constructor fields preserve left-to-right evaluation and call results', () => {
  const source = `type Triple { Triple(Int, Int, Int) }
    fn get(t: Triple) -> Int { let Triple(a,b,c) = t a * 100 + b * 10 + c }
    pub fn main() -> Nil { echo get(Triple(echo 1, echo 2, echo 3)) Nil }`;
  const result = run(source);
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '1\n2\n3\n123\n');
});
test('forward-referenced and mutually recursive custom types', () => {
  const source = `type A { End AValue(B) }
    type B { BValue(A) }
    fn count(a: A) -> Int {
      case a { End -> 0 AValue(BValue(tail)) -> 1 + count(tail) }
    }
    pub fn main() -> Nil { echo count(AValue(BValue(AValue(BValue(End))))) Nil }`;
  const result = run(source);
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '2\n');
});
test('generic nullary values can instantiate independently without leaking bindings', () => {
  const source = `type Maybe(a) { None Just(a) }
    fn int_default(x: Maybe(Int)) -> Int { case x { None -> 1 Just(n) -> n } }
    fn bool_default(x: Maybe(Bool)) -> Bool { case x { None -> True Just(b) -> b } }
    pub fn main() -> Nil { let empty = None echo int_default(empty) echo bool_default(empty) Nil }`;
  const result = run(source);
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '1\nTrue\n');
});
test('generic arguments do not introduce native runtime type machinery', () => {
  const first = compileResult('type Box(a) { Box(a) } pub fn main() -> Nil { let box: Box(Int) = Box(1) Nil }');
  const second = compileResult('type Box(a) { Box(a) } pub fn main() -> Nil { let box: Box(Bool) = Box(True) Nil }');
  assert.equal(first.isOk(), true, first[0]);
  assert.equal(second.isOk(), true, second[0]);
  assert.deepEqual(first[0].rawBuffer, second[0].rawBuffer);
});
test('labelled constructor arguments evaluate in upstream declaration order', () => {
  const result = run('type Pair { Pair(first: Int, second: Int) } pub fn main() -> Nil { let pair = Pair(second: echo 2, first: echo 1) echo pair.first echo pair.second Nil }');
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '1\n2\n1\n2\n');
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
test('native arena accepts an exact fit', () => {
  const result = runBinary(probe(false));
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '');
});
test('native arena rejects allocation beyond its end before writing', () => {
  const result = runBinary(probe(true));
  assert.equal(result.status, 71);
  assert.equal(result.signal, null);
  assert.equal(result.stdout, '');
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
  ['generic functions pending', 'fn identity(x: a) -> a { x } pub fn main() -> Nil { Nil }', /generic function signatures are not implemented/],
  ['unterminated string', 'pub fn main() -> String { "hello }', /Unterminated string/],
  ['missing entrypoint', 'fn f() -> Int { 1 }', /Unknown name: main/],
  ['unimplemented literal range', 'pub fn main() -> Int { 2147483648 }', /literal range/],
  ['unimplemented structural equality', 'pub fn main() -> Bool { "a" == "a" }', /not implemented/],
  ['heterogeneous list', 'pub fn main() -> Nil { let xs = [1, True] Nil }', /Type mismatch/],
  ['bad list tail', 'pub fn main() -> Nil { let xs = [1, ..True] Nil }', /tail must be a list/],
  ['bad nested list', 'pub fn main() -> Nil { let xs = [[1], [True]] Nil }', /Type mismatch/],
  ['tuple index bounds', 'pub fn main() -> Int { #(1, 2).2 }', /out of bounds/],
  ['tuple index shape', 'pub fn main() -> Int { 1.0 }', /requires a tuple/],
  ['tuple pattern arity', 'pub fn main() -> Nil { case #(1, 2) { #(a, b, c) -> Nil _ -> Nil } }', /arity mismatch/],
  ['duplicate tuple binding', 'pub fn main() -> Nil { let #(x, x) = #(1, 2) Nil }', /Duplicate variable/],
  ['refutable let', 'pub fn main() -> Nil { let [x] = [1] Nil }', /Refutable let/],
  ['incomplete list case', 'pub fn main() -> Int { case [1] { [] -> 0 } }', /Non-exhaustive/],
  ['incomplete nonempty case', 'pub fn main() -> Int { case [1] { [] -> 0 [1, .._] -> 1 } }', /Non-exhaustive/],
  ['list element pattern type', 'pub fn main() -> Int { case [1] { [True] -> 1 _ -> 0 } }', /Type mismatch/],
  ['list equality pending', 'pub fn main() -> Bool { [1] == [1] }', /Structural compound equality/],
  ['compound echo pending', 'pub fn main() -> Nil { echo [1] Nil }', /Compound-value echo/],
  ['nominal constructor argument', 'type A { AValue(Int) } type B { BValue(Int) } fn f(a: A) -> Nil { Nil } pub fn main() -> Nil { f(BValue(1)) }', /Type mismatch/],
  ['nominal pattern', 'type A { AValue(Int) } type B { BValue(Int) } pub fn main() -> Int { case AValue(1) { BValue(x) -> x } }', /Type mismatch/],
  ['constructor underarity', 'pub type A { AValue(Int) } pub fn main() -> A { AValue }', /Constructor argument count/],
  ['constructor overarity', 'pub type A { AValue(Int) } pub fn main() -> A { AValue(1,2) }', /Constructor argument count/],
  ['constructor field mismatch', 'pub type A { AValue(Int) } pub fn main() -> A { AValue(True) }', /Type mismatch/],
  ['constructor pattern arity', 'type A { AValue(Int) } pub fn main() -> Int { case AValue(1) { AValue(x,y) -> x } }', /arity mismatch/],
  ['constructor missing variant', 'type A { First Second } fn read(a: A) -> Int { case a { First -> 1 } } pub fn main() -> Nil { Nil }', /Non-exhaustive custom-type/],
  ['constructor partial field coverage', 'type A { First(Int) Second } pub fn main() -> Int { case First(1) { First(0) -> 1 Second -> 2 } }', /Non-exhaustive custom-type/],
  ['duplicate constructor', 'type A { Same } type B { Same } pub fn main() -> Nil { Nil }', /Duplicate constructor/],
  ['duplicate custom type', 'type A { First } type A { Second } pub fn main() -> Nil { Nil }', /Duplicate type/],
  ['unknown custom field type', 'type A { First(Unknown) } pub fn main() -> Nil { Nil }', /Unknown type/],
  ['unknown function type', 'pub fn main() -> Unknown { Nil }', /Unknown type/],
  ['unknown annotation inside empty list', 'pub fn main() -> Nil { let xs: List(Unknown) = [] Nil }', /Unknown type/],
  ['constructor duplicate field binding', 'type A { Pair(Int, Int) } pub fn main() -> Int { let Pair(x,x) = Pair(1,2) x }', /Duplicate variable/],
  ['constructor mixed list types', 'type A { AValue } type B { BValue } pub fn main() -> Nil { let xs = [AValue, BValue] Nil }', /Type mismatch/],
  ['constructor equality pending', 'type A { AValue } pub fn main() -> Bool { AValue == AValue }', /Structural compound equality/],
  ['constructor echo pending', 'type A { AValue } pub fn main() -> Nil { echo AValue Nil }', /Compound-value echo/],
  ['zero-field constructor called', 'pub type A { AValue } pub fn main() -> A { AValue() }', /Zero-field constructor is a value/],
  ['private type return', 'type A { AValue } pub fn main() -> A { AValue }', /Private type used in public interface/],
  ['private type parameter', 'type A { AValue } pub fn expose(x: A) -> Nil { Nil } pub fn main() -> Nil { Nil }', /Private type used in public interface/],
  ['private type nested return', 'type A { AValue } pub fn main() -> List(A) { [] }', /Private type used in public interface/],
  ['private type in public constructor', 'type Private { Private } pub type Public { Public(Private) } pub fn main() -> Nil { Nil }', /Private type used in public interface/],
  ['unknown variant let', 'type A { First Second(Int) } fn read(x: A) -> Int { let Second(n) = x n } pub fn main() -> Nil { Nil }', /Refutable let/],
  ['known tag does not narrow fields', 'type A { First Second(Int) } pub fn main() -> Int { let Second(1) = Second(1) 1 }', /Refutable let/],
  ['nested constructor not falsely narrowed', 'type A { Zero One(Int) } type B { B(A) } pub fn main() -> Int { let B(One(x)) = B(One(1)) x }', /Refutable let/],
  ['known tag cannot change nominal type', 'type A { First } type B { Second } pub fn main() -> Int { let Second = First 0 }', /Type mismatch/],
  ['duplicate pub modifier', 'pub pub fn main() -> Nil { Nil }', /Declaration not implemented/],
  ['generic repeated parameter mismatch', 'type Same(a) { Same(a,a) } pub fn main() -> Nil { let x = Same(1,True) Nil }', /Type mismatch/],
  ['generic application mismatch', 'type Box(a) { Box(a) } fn take(x: Box(Bool)) -> Nil { Nil } pub fn main() -> Nil { take(Box(1)) }', /Type mismatch/],
  ['generic pattern mismatch', 'type Box(a) { Box(a) } pub fn main() -> Bool { case Box(1) { Box(n) -> n } }', /Type mismatch/],
  ['generic recursive argument mismatch', 'type Tree(a) { Leaf(a) Fork(Tree(a),Tree(a)) } pub fn main() -> Nil { let tree = Fork(Leaf(1),Leaf(True)) Nil }', /Type mismatch/],
  ['generic missing application argument', 'pub type Box(a) { Box(a) } fn take(x: Box) -> Nil { Nil } pub fn main() -> Nil { Nil }', /Type argument count/],
  ['generic extra application argument', 'type Box(a) { Box(a) } fn take(x: Box(Int,Bool)) -> Nil { Nil } pub fn main() -> Nil { Nil }', /Type argument count/],
  ['nongeneric application argument', 'type Box { Box } fn take(x: Box(Int)) -> Nil { Nil } pub fn main() -> Nil { Nil }', /Type argument count/],
  ['undeclared generic field variable', 'type Box(a) { Box(b) } pub fn main() -> Nil { Nil }', /Unbound type parameter/],
  ['duplicate generic parameter', 'type Box(a,a) { Box(a) } pub fn main() -> Nil { Nil }', /Duplicate type parameter/],
  ['private generic argument leak', 'type Private { Private } pub type Box(a) { Box(a) } pub fn expose() -> Box(Private) { Box(Private) } pub fn main() -> Nil { Nil }', /Private type used in public interface/],
  ['unknown constructor label', 'type Pair { Pair(x: Int,y: Int) } pub fn main() -> Nil { let p = Pair(z: 1,y: 2) Nil }', /Unknown constructor label/],
  ['duplicate constructor label', 'type Pair { Pair(x: Int,y: Int) } pub fn main() -> Nil { let p = Pair(x: 1,x: 2) Nil }', /Duplicate constructor/],
  ['duplicate field declaration', 'type Pair { Pair(x: Int,x: Bool) } pub fn main() -> Nil { Nil }', /Duplicate field label/],
  ['positional after labelled', 'type Pair { Pair(x: Int,y: Int) } pub fn main() -> Nil { let p = Pair(y: 2,1) Nil }', /Positional argument after labelled/],
  ['missing labelled field', 'type Pair { Pair(x: Int,y: Int) } pub fn main() -> Nil { let p = Pair(x: 1) Nil }', /missing field/],
  ['unknown record field', 'type Pair { Pair(x: Int,y: Int) } pub fn main() -> Nil { let p = Pair(1,2) echo p.z Nil }', /Unknown constructor label/],
  ['record field on integer', 'pub fn main() -> Nil { echo 1.value Nil }', /Record field access requires a custom type/],
  ['record field different positions', 'type V { A(x: Int,y: Bool) B(y: Bool,x: Int) } fn read(v: V) -> Int { v.x } pub fn main() -> Nil { Nil }', /same position and declared type/],
  ['record field different template types', 'type V(a) { A(x: a) B(x: Int) } fn read(v: V(Int)) -> Int { v.x } pub fn main() -> Nil { Nil }', /same position and declared type/],
  ['record field missing in variant', 'type V { A(x: Int) B } fn read(v: V) -> Int { v.x } pub fn main() -> Nil { Nil }', /Unknown constructor label/],
  ['unknown pattern label', 'type Pair { Pair(x: Int,y: Int) } pub fn main() -> Int { let Pair(z: n,..) = Pair(1,2) n }', /Unknown constructor label/],
  ['duplicate pattern label', 'type Pair { Pair(x: Int,y: Int) } pub fn main() -> Int { let Pair(x: a,x: b) = Pair(1,2) a+b }', /Duplicate constructor/],
  ['labelled function calls pending', 'fn f(x: Int) -> Int { x } pub fn main() -> Int { f(x: 1) }', /Labelled function calls are not implemented/],
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
