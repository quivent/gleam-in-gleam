import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync,mkdtempSync,rmSync,symlinkSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
import {BitArray,toList,Ok,Error as ResultError} from '../build/dev/javascript/gleam_native/gleam.mjs';
import {compile as compileSingle,compile_project} from '../build/dev/javascript/gleam_native/native/compiler.mjs';
import * as coreOracle from '../build/dev/javascript/gleam_native/native/core.mjs';
import {Source,link} from '../build/dev/javascript/gleam_native/native/project.mjs';

const fixtures=[...JSON.parse(readFileSync(new URL('./modules-fixtures.json',import.meta.url),'utf8')),...JSON.parse(readFileSync(new URL('./aliases-guards-fixtures.json',import.meta.url),'utf8')),...JSON.parse(readFileSync(new URL('./strings-prelude-fixtures.json',import.meta.url),'utf8')),...JSON.parse(readFileSync(new URL('./multi-pattern-fixtures.json',import.meta.url),'utf8'))];
function sources(files) {return toList(Object.entries(files).map(([name,text])=>new Source(name,new BitArray(Buffer.from(text)))));}
function compile(files,entry='main') {return compile_project(entry,sources(files));}
function run(result) {
 assert.equal(result.isOk(),true,result[0]);
 const dir=mkdtempSync(join(tmpdir(),'gleam-modules-'));
 try {const path=join(dir,'app');writeFileSync(path,result[0].rawBuffer,{mode:0o755});return spawnSync(path,{encoding:'utf8',timeout:5000});}
 finally {rmSync(dir,{recursive:true,force:true});}
}
for (const f of fixtures) {
 test(`module resolution: ${f.name}`,()=>{
  const result=compile(f.files,f.entry);
  assert.equal(result.isOk(),f.accepted,result[0]);
  if(f.accepted) {const actual=run(result);assert.equal(actual.status,0);assert.equal(actual.stdout,f.stdout);assert.equal(actual.stderr,'');}
  else if(f.error) assert.match(result[0],new RegExp(f.error));
 });
}
test('module output is deterministic independent of supplied source order',()=>{
 const f=fixtures.find(f=>f.name==='diamond-dependency');
 const forward=compile(f.files),backward=compile(Object.fromEntries(Object.entries(f.files).reverse()));
 assert.equal(forward.isOk(),true,forward[0]);assert.equal(backward.isOk(),true,backward[0]);
 assert.deepEqual(forward[0].rawBuffer,backward[0].rawBuffer);
 const linked=link('main',sources(f.files));assert.equal(linked.isOk(),true,linked[0]);
 const names=linked[0].functions.toArray().map(f=>f.name);
 assert.equal(names.length,4);assert.equal(new Set(names).size,4);
});
test('unreachable supplied source does not leak or get parsed as a dependency',()=>{
 const result=compile({main:'pub fn main() -> Nil {echo 7 Nil}',unused:'invalid source @ !'});
 assert.equal(run(result).stdout,'7\n');
});
test('an imported main never supplies a missing project entrypoint',()=>{
 const result=compile({main:'import library fn f() -> Nil {Nil}',library:'pub fn main() -> Nil {Nil}'});
 assert.equal(result.isOk(),false);assert.match(result[0],/Unknown name: main/);
});
test('duplicate named source is rejected before linking',()=>{
 const bytes=new BitArray(Buffer.from('pub fn main() -> Nil {Nil}'));
 const result=compile_project('main',toList([new Source('main',bytes),new Source('main',bytes)]));
 assert.equal(result.isOk(),false);assert.match(result[0],/Duplicate module source/);
});
test('source names cannot request path traversal',()=>{
 const result=compile({'../outside':'pub fn main() -> Nil {Nil}'},'../outside');
 assert.equal(result.isOk(),false);assert.match(result[0],/Invalid module name/);
});
test('selective imports fail explicitly until supported',()=>{
 const result=compile({main:'import library.{f} pub fn main() -> Nil {echo f(1) Nil}',library:'pub fn f(n:Int) -> Int {n}'});
 assert.equal(result.isOk(),false);
});
test('CLI loads a nested entry from an explicit source root and preserves existing output',()=>{
 const dir=mkdtempSync(join(tmpdir(),'gleam-module-cli-'));
 try {
  mkdirSync(join(dir,'app'));writeFileSync(join(dir,'app/main.gleam'),'import library pub fn main() -> Nil {echo library.inc(4) Nil}');
  writeFileSync(join(dir,'library.gleam'),'pub fn inc(n:Int) -> Int {n+1}');
  const out=join(dir,'program'),args=['bootstrap.mjs',join(dir,'app/main.gleam'),out,'--source-root',dir];
  const built=spawnSync(process.execPath,args,{encoding:'utf8'});assert.equal(built.status,0,built.stderr);
  assert.equal(spawnSync(out,{encoding:'utf8'}).stdout,'5\n');const before=readFileSync(out);
  assert.notEqual(spawnSync(process.execPath,args,{encoding:'utf8'}).status,0);assert.deepEqual(readFileSync(out),before);
 } finally {rmSync(dir,{recursive:true,force:true});}
});
test('CLI refuses an imported symlink escaping its source root',()=>{
 const dir=mkdtempSync(join(tmpdir(),'gleam-module-root-'));
 try {
  const root=join(dir,'src');mkdirSync(root);writeFileSync(join(root,'main.gleam'),'import outside pub fn main() -> Nil {Nil}');
  writeFileSync(join(dir,'outside.gleam'),'pub fn f() -> Nil {Nil}');symlinkSync(join(dir,'outside.gleam'),join(root,'outside.gleam'));
  const result=spawnSync(process.execPath,['bootstrap.mjs',join(root,'main.gleam'),join(dir,'program')],{encoding:'utf8'});
  assert.notEqual(result.status,0);assert.match(result.stderr,/escapes the selected source root/);
 } finally {rmSync(dir,{recursive:true,force:true});}
});

test('module namespacing cannot bypass explicit builtin-shadowing subset restriction',()=>{
 const result=compile({main:'import bad pub fn main() -> Nil {Nil}',bad:'type BitArray {Foo}'});
 assert.equal(result.isOk(),false);assert.match(result[0],/Builtin type shadowing is not implemented/);
});

test('static module name resolution matches equivalent single-module machine code',()=>{
 const f=fixtures.find(f=>f.name==='nested-path-default-alias');
 const modular=compile(f.files);
 const flat=compileSingle(new BitArray(Buffer.from('pub fn add(a: Int,b: Int) -> Int {a+b} pub fn main() -> Nil {echo add(4,5) Nil}')));
 assert.equal(modular.isOk(),true,modular[0]);assert.equal(flat.isOk(),true,flat[0]);
 assert.deepEqual(modular[0].rawBuffer,flat[0].rawBuffer);
});

test('type aliases erase completely into the underlying machine code',()=>{
 const aliased=compileSingle(new BitArray(Buffer.from('type Pair(a)=#(a,a) fn sum(p:Pair(Int)) -> Int {let #(a,b)=p a+b} pub fn main() -> Nil {echo sum(#(3,4)) Nil}')));
 const direct=compileSingle(new BitArray(Buffer.from('fn sum(p:#(Int,Int)) -> Int {let #(a,b)=p a+b} pub fn main() -> Nil {echo sum(#(3,4)) Nil}')));
 assert.equal(aliased.isOk(),true,aliased[0]);assert.equal(direct.isOk(),true,direct[0]);
 assert.deepEqual(aliased[0].rawBuffer,direct[0].rawBuffer);
 const linked=link('main',sources({main:'type Count=Int pub fn main() -> Nil {echo 3 Nil}'}));
 assert.equal(linked.isOk(),true,linked[0]);assert.equal(linked[0].aliases.toArray().length,0);assert.equal(linked[0].custom_types.toArray().length,0);
});
test('guard short-circuiting skips overflow in an unreachable operand',()=>{
 const result=compile({main:'pub fn main() -> Nil {echo case 0 {n if False && {2147483647*2147483647*3>0} -> 0 _ -> 1} Nil}'});
 const actual=run(result);assert.equal(actual.status,0);assert.equal(actual.stdout,'1\n');
});

test('the actual compiler-owned core module compiles and runs natively',()=>{
 const own=readFileSync(new URL('../src/native/core.gleam',import.meta.url),'utf8');
 const driver=readFileSync(new URL('./owned-core-driver.source',import.meta.url),'utf8');
 const actual=run(compileSingle(new BitArray(Buffer.from(own+'\n'+driver))));
 assert.equal(actual.status,0);assert.equal(actual.stderr,'');
 const nums=toList([1,2,3]);
 const values=[coreOracle.length(coreOracle.reverse(nums)),coreOracle.decimal(1234),coreOracle.uppercase_name('Zebra'),coreOracle.discarded_name('_x'),coreOracle.lookup(toList([['x',7]]),'x')[0],coreOracle.byte_length(coreOracle.bytes(nums)),coreOracle.nth(coreOracle.map(nums,n=>n*2),1)[0],coreOracle.lookup(coreOracle.put(toList([['x',1]]),'x',9),'x')[0],coreOracle.lookup(toList([]),'missing')[0]==='Unknown name: missing',coreOracle.try_map(nums,n=>n===2?new ResultError('stop'):new Ok(n+1))[0]==='stop'];
 assert.equal(actual.stdout,values.map(v=>v===true?'True':v===false?'False':String(v)).join('\n')+'\n');
});

test('Boolean product coverage agrees with an independent finite truth table',()=>{
 for(let mask=0;mask<16;mask++) {
  const rows=[];for(let assignment=0;assignment<4;assignment++)if(mask&(1<<assignment))rows.push([!!(assignment&2),!!(assignment&1)]);
  const text=rows.map(row=>row.map(v=>v?'True':'False').join(',')+' -> 1').join(' ');
  const result=compile({main:`fn choose(a:Bool,b:Bool) -> Int {case a,b {${text}}} pub fn main() -> Nil {Nil}`});
  assert.equal(result.isOk(),mask===15,`concrete mask ${mask}`);
 }
 let seed=971;
 for(let trial=0;trial<48;trial++) {
  const rows=[];for(let i=0;i<5;i++){const row=[];for(let j=0;j<3;j++){seed=(Math.imul(seed,1664525)+1013904223)>>>0;row.push(seed%3);}rows.push(row);}
  const complete=Array.from({length:8},(_,bits)=>rows.some(row=>row.every((p,j)=>p===2||p===((bits>>j)&1)))).every(Boolean);
  const body=rows.map(row=>row.map(p=>p===2?'_':p===1?'True':'False').join(',')+' -> 1').join(' ');
  const result=compile({main:`fn choose(a:Bool,b:Bool,c:Bool) -> Int {case a,b,c {${body}}} pub fn main() -> Nil {Nil}`});
  assert.equal(result.isOk(),complete,`wildcard trial ${trial}`);
 }
});
