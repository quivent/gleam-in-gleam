import {test} from 'node:test';
import {assemble, Bytes, Label, Relative, Span, join as joinParts, symbols as assemblySymbols} from '../build/dev/javascript/gleam_native/native/assembler.mjs';
import {toList} from '../build/dev/javascript/gleam_native/gleam.mjs';
import assert from 'node:assert/strict';
import {mkdtempSync, readFileSync, writeFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {BitArray} from '../build/dev/javascript/gleam_native/gleam.mjs';
import {compile} from '../build/dev/javascript/gleam_native/native/compiler.mjs';
import {lex} from '../build/dev/javascript/gleam_native/native/lexer.mjs';
import {parse} from '../build/dev/javascript/gleam_native/native/parser.mjs';
import {module as checkModule} from '../build/dev/javascript/gleam_native/native/check.mjs';
import * as oracle from '../build/dev/javascript/gleam_native/oracle.mjs';
import * as bitOracle from '../build/dev/javascript/gleam_native/bit_oracle.mjs';
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
  ['generic_functions', [3]], ['generic_functions', [-3]], ['generic_function_reverse', [2]],
  ['generic_variable_names', [7]], ['higher_order', [3]], ['higher_order', [-3]],
  ['returned_function', [8]], ['returned_generic_function', [9]], ['callback_record', [10]],
  ['function_shadowing', [1]], ['local_function_alias', [11]],
  ['closure_returned', [7]], ['closure_nested', [8]], ['closure_shadow', [9]],
  ['closure_parameter_shadow', [10]], ['closure_generic', [11]], ['closure_in_record', [12]],
  ['use_nested', [3]], ['use_tuple', [4]], ['use_two', [-5]], ['use_two', [5]],
  ['use_zero', [6]], ['closure_case_scope', [7]], ['closure_case_scope', [-7]], ['closure_capture_data', [8]],
  ['closure_returned_data', [9]], ['closure_captures_function', [10]],
  ['use_indirect', [11]], ['use_repeated', [12]],
  ['closure_context_case', [8]],
  ['record_update_keep', [7]],
  ['record_update_type', [7]],
  ['record_update_generic', [7]],
  ['record_update_nested', [7]],
  ['record_update_closure', [7]],
  ['record_update_shorthand', [7]],
  ['record_update_callback', [7]],
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
test('indirect call evaluates target before arguments and cleans up its saved pointer', () => {
  const source = `fn add(a: Int,b: Int) -> Int { a+b }
    fn target() -> fn(Int,Int) -> Int { echo 1 add }
    pub fn main() -> Nil { echo target()(echo 2,echo 3) echo target()(4,5) Nil }`;
  const result = run(source);
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '1\n2\n3\n5\n1\n9\n');
});
test('returned closures keep independent environments after their factory returns', () => {
  const result = run(main('let first = make_adder(10) let second = make_adder(20) echo first(1) echo second(1) echo first(2)'));
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '11\n21\n12\n');
});
test('context is inferred from non-callback arguments without changing evaluation order', () => {
  const source = `fn run(f: fn(Int) -> Int,x: Int) -> Int { f(x) }
    pub fn main() -> Nil { let base = 4 echo run(fn(x) { echo x x+base },echo 3) Nil }`;
  const result = run(source);
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '3\n3\n7\n');
});
test('annotation provides lambda context and source shadowing does not change captures', () => {
  const source = `pub fn main() -> Nil { let n=7 let f: fn(Int) -> Int = fn(x) { n+x } let n=100 echo f(2) echo n Nil }`;
  const result = run(source);
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '9\n100\n');
});
test('multi-argument closure captures use the correct hidden descriptor offset', () => {
  const source = `fn make(n: Int) -> fn(Int,Int) -> Int { fn(a,b) { n+a*10+b } }
    pub fn main() -> Nil { let f=make(100) echo f(2,3) echo f(4,5) Nil }`;
  const result = run(source);
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '123\n145\n');
});
test('only free variables are captured; parameter shadowing does not capture the outer binding', () => {
  const source = `pub fn main() -> Nil { let n=99 let f=fn(n: Int) { n+1 } echo f(1) echo n Nil }`;
  const result = run(source);
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '2\n99\n');
});
test('typed closure records only actual lexical free variables', () => {
  const source = 'pub fn main() -> Nil { let used=3 let unused=9 let f=fn(x: Int) { let local=x+1 used+local } Nil }';
  const tokens = lex(new BitArray(Buffer.from(source)));
  const ast = parse(tokens[0]);
  const typed = checkModule(ast[0]);
  assert.equal(typed.isOk(), true, typed[0]);
  const statements = typed[0].toArray()[0].body.toArray();
  const closure = statements[2][1].node;
  assert.deepEqual(closure[2].toArray(), ['used']);
});
test('use continuation body is not executed when the callee skips it', () => {
  const source = `fn skip(_next: fn() -> Int) -> Int { 7 }
    pub fn main() -> Nil { let result={ use <- skip() echo 999 9 } echo result Nil }`;
  const result = run(source);
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '7\n');
});
test('use continuation can be invoked more than once with intact captures', () => {
  const source = `fn repeat(n: Int,next: fn(Int) -> Int) -> Int { next(n)+next(n+1) }
    pub fn main() -> Nil { let offset=10 let value={ use x <- repeat(3) echo x x+offset } echo value Nil }`;
  const result = run(source);
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '3\n4\n27\n');
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
test('record update saves original once and evaluates replacements in declaration order', () => {
  const result = run('type R { R(a: Int,b: Int) } fn old() -> R { echo 1 R(2,3) } pub fn main() -> Nil { let r=R(..old(),b: {echo 4 5},a: {echo 6 7}) echo r.a echo r.b Nil }');
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '1\n6\n4\n7\n5\n');
});
test('fully replaced update still evaluates its original and keeps it immutable', () => {
  const result = run('type R { R(x: Int) } pub fn main() -> Nil { let p=R(2) let q=R(..{echo 9 p},x:3) echo p.x echo q.x Nil }');
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '9\n2\n3\n');
});
test('record update infers anonymous parameter from retained generic field', () => {
  const result = run('type R(a) { R(f: fn(a) -> Int,x: a) } pub fn main() -> Nil { let p=R(fn(x: Int){x+1},3) let q=R(..p,f:fn(x){x+2}) let f=q.f echo f(q.x) Nil }');
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '5\n');
});
const rejected = [
  ['zero-field update is not a record constructor', 'pub type R { R } pub fn main() -> R { let r=R R(..r) }', /Invalid record update constructor/],
  ['unsafe variant update', 'type R { A(x: Int) B(x: Int) } fn f(r: R) -> R { A(..r,x:2) } pub fn main() -> Nil { Nil }', /Unsafe record update/],
  ['wrong known variant update', 'type R { A(x: Int) B(x: Int) } pub fn main() -> Nil { let a=B(1) let b=A(..a,x:2) Nil }', /Unsafe record update/],
  ['wrong nominal update', 'type R { R(x: Int) } type S { S(x: Int) } pub fn main() -> Nil { let a=S(1) let b=R(..a,x:2) Nil }', /Type mismatch/],
  ['unknown update field', 'type R { R(x: Int) } pub fn main() -> Nil { let a=R(1) let b=R(..a,y:2) Nil }', /Unknown constructor label/],
  ['duplicate update field', 'type R { R(x: Int) } pub fn main() -> Nil { let a=R(1) let b=R(..a,x:2,x:3) Nil }', /Duplicate constructor/],
  ['positional update field', 'type R { R(x: Int) } pub fn main() -> Nil { let a=R(1) let b=R(..a,2) Nil }', /require labelled/],
  ['update retained generic field constrains replacement', 'type R(a) { R(x: a,y: a) } pub fn main() -> Nil { let a=R(1,2) let b=R(..a,x:True) Nil }', /Type mismatch/],
  ['update cannot change concrete field type', 'type R { R(x: Int) } pub fn main() -> Nil { let a=R(1) let b=R(..a,x:True) Nil }', /Type mismatch/],

  ['return mismatch', 'pub fn main() -> Int { True }', /Type mismatch/],
  ['argument type', 'fn f(a: Int) -> Int { a } pub fn main() -> Int { f(True) }', /Type mismatch/],
  ['argument count', 'fn f(a: Int) -> Int { a } pub fn main() -> Int { f() }', /argument count/],
  ['missing name', 'pub fn main() -> Int { unknown }', /Unknown name/],
  ['duplicate function', 'pub fn main() -> Int { 1 } pub fn main() -> Int { 2 }', /Duplicate function/],
  ['duplicate parameter', 'pub fn main(a: Int, a: Int) -> Int { a }', /Duplicate parameter/],
  ['nonexhaustive', 'pub fn main() -> Int { case 1 { 1 -> 2 } }', /Non-exhaustive/],
  ['branch mismatch', 'pub fn main() -> Int { case True { True -> 1 False -> False } }', /Type mismatch/],
  ['pattern mismatch', 'pub fn main() -> Int { case 1 { True -> 1 _ -> 0 } }', /Type mismatch/],
  ['missing module source', 'import gleam/io pub fn main() -> Nil { Nil }', /Missing module source/],
  ['polymorphic named values pending', 'fn identity(x: a) -> a { x } pub fn main() -> Nil { let f = identity Nil }', /Polymorphic named function values are not implemented/],
  ['unterminated string', 'pub fn main() -> String { "hello }', /Unterminated string/],
  ['missing entrypoint', 'fn f() -> Int { 1 }', /Unknown name: main/],
  ['unimplemented literal range', 'pub fn main() -> Int { 9007199254740992 }', /literal range/],
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
  ['rigid generic return', 'fn f(x: a) -> a { 1 } pub fn main() -> Nil { Nil }', /Type mismatch/],
  ['rigid generic arithmetic', 'fn f(x: a) -> Int { x + 1 } pub fn main() -> Nil { Nil }', /Type mismatch/],
  ['rigid distinct variables', 'fn f(x: a,y: b) -> a { y } pub fn main() -> Nil { Nil }', /Type mismatch/],
  ['generic repeated call argument', 'fn f(x: a,y: a) -> a { x } pub fn main() -> Nil { let n = f(1,True) Nil }', /Type mismatch/],
  ['self polymorphic recursion', 'fn f(x: a) -> Int { f([x]) } pub fn main() -> Nil { Nil }', /Type mismatch/],
  ['rigid callback parameter', 'fn f(g: fn(a) -> a) -> Int { g(1) } pub fn main() -> Nil { Nil }', /Type mismatch/],
  ['wrong callback arguments', 'fn inc(x: Int) -> Int { x+1 } pub fn main() -> Nil { let f = inc let n = f(True) Nil }', /Type mismatch/],
  ['wrong callback count', 'fn inc(x: Int) -> Int { x+1 } pub fn main() -> Nil { let f = inc let n = f() Nil }', /Function argument count/],
  ['callback generic inconsistency', 'fn invert(x: Bool) -> Bool { !x } fn apply(f: fn(a) -> a,x: a) -> a { f(x) } pub fn main() -> Nil { let n = apply(invert,1) Nil }', /Type mismatch/],
  ['nonfunction shadows callable', 'fn f(x: Int) -> Int { x } pub fn main() -> Nil { let f = 1 let n = f(2) Nil }', /Value is not a function/],
  ['private type inside function signature', 'type Private { Private } pub fn expose(f: fn(Private) -> Int) -> Nil { Nil } pub fn main() -> Nil { Nil }', /Private type used in public interface/],
  ['unbound local annotation', 'fn f(x: a) -> a { let y: b = x y } pub fn main() -> Nil { Nil }', /Unbound type parameter/],
  ['lambda unknown parameter context', 'pub fn main() -> Nil { let f=fn(x) { x+1 } Nil }', /annotation or stronger type context/],
  ['lambda callback return mismatch', 'fn run(f: fn(Int) -> Bool) -> Nil { Nil } pub fn main() -> Nil { run(fn(x) { x+1 }) }', /Type mismatch/],
  ['lambda annotation mismatch', 'pub fn main() -> Nil { let f: fn(Int) -> Int=fn(x: Bool) { 1 } Nil }', /Type mismatch/],
  ['lambda duplicate parameter', 'pub fn main() -> Nil { let f=fn(x: Int,x: Int) { x } Nil }', /Duplicate anonymous parameter/],
  ['lambda wrong context arity', 'fn run(f: fn(Int) -> Int) -> Nil { Nil } pub fn main() -> Nil { run(fn(a: Int,b: Int) { a+b }) }', /parameter count mismatch/],
  ['lambda unknown capture', 'pub fn main() -> Nil { let f=fn() { missing } Nil }', /Unknown name/],
  ['lambda discarded value read', 'pub fn main() -> Nil { let f=fn(_x: Int) { _x } Nil }', /Discarded variable/],
  ['discarded callable read', 'fn f(_g: fn() -> Int) -> Int { _g() } pub fn main() -> Nil { Nil }', /Discarded variable/],
  ['lambda unresolved function parameter cannot become unsoundly polymorphic', 'fn pass(f: fn(a) -> a) -> fn(a) -> a { f } pub fn main() -> Nil { let f=pass(fn(x) { x+1 }) Nil }', /annotation or stronger type context/],
  ['lambda explicit parameter rejects wrong later call', 'fn pass(f: fn(a) -> a) -> fn(a) -> a { f } pub fn main() -> Nil { let f=pass(fn(x: Int) { x+1 }) echo f(True) Nil }', /Type mismatch/],
  ['use wrong pattern shape', 'fn run(n: Int,f: fn(Int) -> Int) -> Int { f(n) } pub fn main() -> Int { use #(a,b) <- run(1) a+b }', /Tuple pattern requires/],
  ['use duplicate bound names', 'fn run(f: fn(Int,Int) -> Int) -> Int { f(1,2) } pub fn main() -> Int { use x,x <- run() x }', /Duplicate anonymous parameter/],
  ['use refutable pattern', 'fn run(n: Int,f: fn(Int) -> Int) -> Int { f(n) } pub fn main() -> Int { use 1 <- run(1) 1 }', /Refutable let/],
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

test('relocation emission handles a large instruction stream without host recursion', () => {
  const parts = [new Relative(new BitArray(Uint8Array.of(0xe9)), 'end'),
    ...Array.from({length: 12000}, () => new Bytes(new BitArray(Uint8Array.of(0x90)))),
    new Label('end')];
  const result = assemble(toList(parts));
  assert.equal(result.isOk(), true, result[0]);
  const bytes = Buffer.from(result[0].rawBuffer);
  assert.equal(bytes.length, 12005);
  assert.equal(bytes[0], 0xe9);
  assert.equal(bytes.readInt32LE(1), 12000);
  assert.equal(bytes[12004], 0x90);
  const missing = assemble(toList([new Relative(new BitArray(Uint8Array.of(0xe9)), 'missing')]));
  assert.equal(missing.isOk(), false);
});

const bitSource = readFileSync(new URL('./bit_oracle.gleam', import.meta.url), 'utf8');

for (const [name, args] of [
  ['bit_empty', []], ['bit_default', [2]], ['bit_default', [-2]], ['bit_default', [257]],
  ['bit_little', [4660]], ['bit_big', [4660]], ['bit_endian', [4660]],
  ['bit_48', [1000000]], ['bit_signed', [-2]], ['bit_signed', [-128]],
  ['bit_concat', [7]], ['bit_tail_return', [8]], ['bit_capture', [9]],
  ['bit_zero', [99]], ['bit_options', [4660]],
  ['bit_literal', [1]], ['bit_literal', [2]], ['bit_literal', [3]],
  ['bit_lengths', [7]], ['bit_full_tail', [8]], ['bit_record', [9]],
]) {
  test(`upstream bit-array oracle: ${name}(${args.join(',')})`, () => {
    const result = run(`${bitSource}\npub fn main() -> Nil { echo ${name}(${args.join(',')}) Nil }`);
    assert.equal(result.status, 0);
    assert.equal(result.stdout, rendered(bitOracle[name](...args)) + '\n');
    assert.equal(result.stderr, '');
  });
}

test('bit-array nonzero segments evaluate left-to-right and static zero width skips evaluation', () => {
  const result = run(`${bitSource} pub fn main() -> Nil { let data=<<{echo 1 7}, {echo 2 <<8,9>>}:bits, {echo 3 99}:0>> echo byte_sum(data) Nil }`);
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '1\n2\n24\n');
});
test('bit-array alternatives check exact lengths before any byte load', () => {
  const result = run('fn read(data: BitArray) -> Int { case data { <<_,_,_,_>> -> 4 <<1,2>> -> 2 <<255,rest:bits>> -> 9 <<>> -> 0 _ -> 8 } } pub fn main() -> Nil { echo read(<<>>) echo read(<<1>>) echo read(<<1,2>>) echo read(<<255>>) echo read(<<1,2,3,4,5>>) Nil }');
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '0\n8\n2\n9\n8\n');
});
test('unsigned 64-bit extraction respects documented signed native Int limit', () => {
  const result = run('pub fn main() -> Nil { case <<-1:64>> { <<n:64>> -> {echo n Nil} _ -> Nil } }');
  assert.equal(result.status, 70);
  assert.equal(result.stdout, '');
});

for (const [name, source, error] of [
  ['wrong integer segment type', 'pub fn main() -> Nil { let a=<<True>> Nil }', /Type mismatch/],
  ['wrong bits segment type', 'pub fn main() -> Nil { let a=<<1:bits>> Nil }', /Type mismatch/],
  ['pattern on wrong subject', 'pub fn main() -> Nil { case 1 { <<>> -> Nil _ -> Nil } }', /Type mismatch/],
  ['unsized tail not last', 'fn f(a: BitArray) -> Int { case a { <<r:bits,x>> -> x _ -> 0 } } pub fn main() -> Nil { Nil }', /tail must be last/],
  ['duplicate pattern names', 'fn f(a: BitArray) -> Int { case a { <<x,x>> -> x _ -> 0 } } pub fn main() -> Nil { Nil }', /Duplicate variable/],
  ['conflicting sizes', 'pub fn main() -> Nil { let a=<<1:8-16>> Nil }', /Duplicate\/conflicting/],
  ['conflicting endianness', 'pub fn main() -> Nil { let a=<<1:big-little>> Nil }', /Duplicate\/conflicting/],
  ['zero-width pattern', 'fn f(a: BitArray) -> Int { case a { <<x:0>> -> x _ -> 0 } } pub fn main() -> Nil { Nil }', /byte-aligned/],
  ['signed construction option', 'pub fn main() -> Nil { let a=<<1:signed>> Nil }', /only valid in patterns/],
  ['bytes construction option', 'pub fn main() -> Nil { let a=<<<<1>>:bytes>> Nil }', /only valid in patterns/],
  ['unaligned segment pending', 'pub fn main() -> Nil { let a=<<1:3>> Nil }', /byte-aligned/],
  ['oversized segment pending', 'pub fn main() -> Nil { let a=<<1:72>> Nil }', /byte-aligned/],
  ['float option pending', 'pub fn main() -> Nil { let a=<<1:float>> Nil }', /option not implemented/],
  ['dynamic size pending', 'fn f(n: Int) -> BitArray { <<1:size(n)>> } pub fn main() -> Nil { Nil }', /Expected ','|option|Expression/],
  ['compound bit-array printing pending', 'pub fn main() -> Nil { echo <<1>> Nil }', /Compound-value echo/],
  ['builtin BitArray shadowing', 'type BitArray { A } pub fn main() -> Nil { Nil }', /Builtin type shadowing/],
]) {
  test(`bit arrays reject without fallback: ${name}`, () => {
    const result=compileResult(source);
    assert.equal(result.isOk(), false);
    assert.match(result[0], error);
  });
}

test('64-bit extraction supports signed negatives and unsigned values in native range', () => {
  const result = run('pub fn main() -> Nil { case <<-2:64-little,1000000:64>> { <<a:64-little-signed,b:64>> -> { echo a echo b Nil } _ -> Nil } }');
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '-2\n1000000\n');
});
test('unsigned 64-bit discard/literal matching does not misinterpret its high bit', () => {
  const result = run('pub fn main() -> Nil { let a=<<-1:64>> echo case a { <<-1:64>> -> 9 <<_:64>> -> 1 _ -> 0 } Nil }');
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '1\n');
});
for (const [name, source] of [
 ['unaligned completeness remains conservative', 'fn f(a: BitArray) -> Int { case a { <<>> -> 0 <<_,rest:bits>> -> 1 } } pub fn main() -> Nil { Nil }'],
 ['bytes tail is refutable without assertion', 'fn f(a: BitArray) -> BitArray { let <<tail:bytes>>=a tail } pub fn main() -> Nil { Nil }'],
 ['unbraced segment arithmetic', 'pub fn main() -> Nil { let a=<<1+2>> Nil }'],
]) {
 test(`bit-array source checking: ${name}`, () => { assert.equal(compileResult(source).isOk(), false); });
}

for (const width of [8,16,24,32,40,48,56,64]) {
 for (const endian of ['big','little']) {
  test(`exact bytes and independent signed decoding: ${width}-${endian}`, () => {
   const bytes=Array(width/8).fill(255);
   bytes[endian==='little' ? 0 : bytes.length-1]=254;
   const literal=bytes.join(',');
   const result=run(`pub fn main() -> Nil { echo case <<-2:${width}-${endian}>> { <<${literal}>> -> 1 _ -> 0 } case <<${literal}>> { <<n:${width}-${endian}-signed>> -> {echo n Nil} _ -> Nil } Nil }`);
   assert.equal(result.status,0);
   assert.equal(result.stdout,'1\n-2\n');
  });
 }
}
test('bit-array construction fails before copying beyond the bounded arena', () => {
 const result=run('fn grow(a: BitArray,n: Int) -> BitArray { case n { 0 -> a _ -> grow(<<a:bits,a:bits>>,n-1) } } pub fn main() -> Nil { let _a=grow(<<1>>,25) echo 99 Nil }');
 assert.equal(result.status,71);
 assert.equal(result.stdout,'');
});

test('wide literal scanning and 64-bit immediates preserve every exact boundary digit', () => {
 const values=[2147483647,2147483648,4294967295,4294967296,4503599627370495,
  4503599627370496,9007199254740987,9007199254740988,9007199254740989,
  9007199254740990,9007199254740991];
 const source='pub fn main() -> Nil {'+values.map(n=>'echo '+n+' echo -'+n).join(' ')+' Nil}';
 const actual=run(source);
 assert.equal(actual.status,0);
 assert.equal(actual.stdout,values.flatMap(n=>[String(n),String(-n)]).join('\n')+'\n');
});
test('wide patterns compare complete words rather than truncated or sign-extended immediates', () => {
 const values=[2147483648,4294967295,4294967296,9007199254740991,-2147483649,-9007199254740991];
 for(const n of values){
  const low=Number(BigInt.asIntN(32,BigInt(n)));
  const source='fn f(n: Int) -> Bool {case n {'+n+' -> True _ -> False}} pub fn main() -> Nil {echo f('+n+') echo f('+low+') Nil}';
  const actual=run(source);assert.equal(actual.status,0);assert.equal(actual.stdout,'True\nFalse\n');
 }
});
test('out-of-range magnitudes are rejected before bootstrap rounding, including negative literals and patterns', () => {
 for(const digits of ['9007199254740992','9007199254740993','9223372036854775807','999999999999999999999999999999999999']){
  for(const source of ['pub fn main() -> Nil {echo '+digits+' Nil}',
   'pub fn main() -> Nil {echo -'+digits+' Nil}',
   'pub fn main() -> Nil {case 0 {'+digits+' -> Nil _ -> Nil}}']){
   const result=compileResult(source);assert.equal(result.isOk(),false);assert.match(result[0],/exact 53-bit literal range/);
  }
 }
});


test('immutable instruction spans preserve flat bytes and cross-span label offsets',()=>{
 const b=xs=>new Bytes(new BitArray(Uint8Array.from(xs))),jump=name=>new Relative(new BitArray(Uint8Array.of(0xe9)),name);
 const flat=toList([new Label('start'),b([0x90]),jump('end'),b([0x91]),jump('start'),new Label('end'),b([0xc3])]);
 const left=toList([new Label('start'),b([0x90]),jump('end')]),right=toList([new Span(toList([])),b([0x91]),new Span(toList([jump('start'),new Label('end')])),b([0xc3])]);
 const nested=joinParts(left,right);const a=assemble(flat),z=assemble(nested);assert.equal(a.isOk(),true,a[0]);assert.equal(z.isOk(),true,z[0]);assert.deepEqual(z[0].rawBuffer,a[0].rawBuffer);assert.deepEqual(assemblySymbols(nested),assemblySymbols(flat));
 assert.equal(joinParts(left,toList([])),left);assert.equal(joinParts(toList([]),right),right);
});
test('span traversal rejects duplicate and unresolved labels across composition boundaries',()=>{
 const duplicate=assemble(toList([new Span(toList([new Label('same')])),new Span(toList([new Label('same')]))]));assert.equal(duplicate.isOk(),false);assert.match(duplicate[0],/Duplicate assembly label/);
 const absent=assemble(toList([new Span(toList([new Relative(new BitArray(Uint8Array.of(0xe9)),'missing')]))]));assert.equal(absent.isOk(),false);assert.match(absent[0],/Unknown name/);
});
test('deep instruction-span nesting is walked with an explicit pending stack',()=>{
 let parts=toList([new Bytes(new BitArray(Uint8Array.of(0xc3)))]);
 for(let i=0;i<20000;i++)parts=toList([new Span(parts)]);
 const result=assemble(parts);assert.equal(result.isOk(),true,result[0]);assert.deepEqual([...result[0].rawBuffer],[0xc3]);
});

test('comparison cases consume flags without materializing and reloading a Boolean',()=>{
 const source='fn choose(n:Int)->Int {case n%3<1 {True->11 False->22}} pub fn main()->Nil {echo choose(4) Nil}';
 const result=run(source);assert.equal(result.status,0);assert.equal(result.stdout,'22\n');
 const dir=mkdtempSync(join(tmpdir(),'gleam-case-flags-'));
 try {
  const image=Buffer.from(result.bytes),entry=Number(image.readBigUInt64LE(24)),ph=Number(image.readBigUInt64LE(32)),base=Number(image.readBigUInt64LE(ph+16));
  const raw=join(dir,'code');writeFileSync(raw,image.subarray(entry-base));const listing=spawnSync('objdump',['-D','-b','binary','-m','i386:x86-64',raw],{encoding:'utf8'});assert.equal(listing.status,0,listing.stderr);assert.match(listing.stdout,/\bjge\b/);assert.doesNotMatch(listing.stdout,/\bsetl\b/);
 } finally {rmSync(dir,{recursive:true,force:true});}
});
