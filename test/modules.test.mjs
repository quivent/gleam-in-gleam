import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync,mkdtempSync,rmSync,symlinkSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
import {BitArray,toList} from '../build/dev/javascript/gleam_native/gleam.mjs';
import {compile as compileSingle,compile_project} from '../build/dev/javascript/gleam_native/native/compiler.mjs';
import {Source,link} from '../build/dev/javascript/gleam_native/native/project.mjs';

const fixtures=JSON.parse(readFileSync(new URL('./modules-fixtures.json',import.meta.url),'utf8'));
function sources(files) {return toList(Object.entries(files).map(([name,text])=>new Source(name,new BitArray(Buffer.from(text)))));}
function compile(files,entry='main') {return compile_project(entry,sources(files));}
function run(result) {
 assert.equal(result.isOk(),true,result[0]);
 const dir=mkdtempSync(join(tmpdir(),'gleam-modules-'));
 try {const path=join(dir,'app');writeFileSync(path,result[0].rawBuffer,{mode:0o755});return spawnSync(path,{encoding:'utf8'});}
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
