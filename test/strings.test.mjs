import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,readFileSync,writeFileSync,rmSync} from 'node:fs';
import {join} from 'node:path';import {tmpdir} from 'node:os';import {spawnSync} from 'node:child_process';
import {BitArray} from '../build/dev/javascript/gleam_native/gleam.mjs';
import {compile} from '../build/dev/javascript/gleam_native/native/compiler.mjs';
import {valid} from '../build/dev/javascript/gleam_native/native/utf8.mjs';
import * as oracle from '../build/dev/javascript/gleam_native/string_oracle.mjs';
const source=readFileSync(new URL('./string_oracle.gleam',import.meta.url),'utf8');
function run(text) {
 const result=compile(new BitArray(Buffer.from(text)));assert.equal(result.isOk(),true,result[0]);
 const dir=mkdtempSync(join(tmpdir(),'gleam-string-'));
 try {const file=join(dir,'app');writeFileSync(file,result[0].rawBuffer,{mode:0o755});return spawnSync(file,{encoding:'utf8',timeout:5000});}
 finally {rmSync(dir,{recursive:true,force:true});}
}
for(const [name,args] of [['words',[]],['unicode',[]],['empty_left',[]],['empty_right',[]],['newlines',[]],['normalization',[]],['equality',[]],['inequality',[]],['empty_equality',[]],['length_mismatch',[]],['prefix',[0]],['prefix',[1]],['prefix_as',[]],['full_prefix',[]],['empty_prefix',[]],['guard_concat',[]],['returned_tail',[]],['result_string',[0]],['result_string',[1]]]) {
 test(`upstream string oracle: ${name}`,()=>{
  const actual=run(`${source}\npub fn main() -> Nil {echo ${name}(${args.join(',')}) Nil}`);
  const expected=oracle[name](...args);
  assert.equal(actual.status,0);assert.equal(actual.stderr,'');
  assert.equal(actual.stdout,(expected===true?'True':expected===false?'False':expected)+'\n');
 });
}
test('concat evaluates operands once, left to right',()=>{
 const actual=run('pub fn main() -> Nil {let s={echo 1 "a"} <> {echo 2 "β"} <> {echo 3 "c"} echo s Nil}');
 assert.equal(actual.status,0);assert.equal(actual.stdout,'1\n2\n3\naβc\n');
});
test('string growth exhausts the arena before an oversized copy',()=>{
 const actual=run('fn grow(s:String,n:Int) -> String {case n {0 -> s _ -> grow(s<>s,n-1)}} pub fn main() -> Nil {let _s=grow("x",25) echo 99 Nil}');
 assert.equal(actual.status,71);assert.equal(actual.stdout,'');
});
test('UTF-8 validator agrees with independent fatal decoder on boundaries and deterministic samples',()=>{
 const decoder=new TextDecoder('utf-8',{fatal:true});
 const cases=[[0],[127],[194,128],[223,191],[224,160,128],[237,159,191],[240,144,128,128],[244,143,191,191],[128],[192,128],[193,191],[224,128,128],[237,160,128],[240,128,128,128],[244,144,128,128],[245,128,128,128],[226,130]];
 for(let n=0;n<256;n++)cases.push([n]);
 let seed=719;
 for(let i=0;i<1000;i++){const bytes=[];for(let j=0;j<i%8;j++){seed=(Math.imul(seed,1664525)+1013904223)>>>0;bytes.push(seed>>>24);}cases.push(bytes);}
 for(const bytes of cases){let expected=true;try{decoder.decode(Uint8Array.from(bytes));}catch{expected=false;}
  assert.equal(valid(new BitArray(Uint8Array.from(bytes))),expected,JSON.stringify(bytes));}
});
test('invalid UTF-8 source is rejected before parsing',()=>{
 for(const invalid of [[192,128],[237,160,128],[244,144,128,128],[226,130]]){
  const bytes=Buffer.concat([Buffer.from('pub fn main() -> Nil {echo "'),Buffer.from(invalid),Buffer.from('" Nil}')]);
  const result=compile(new BitArray(bytes));assert.equal(result.isOk(),false);assert.match(result[0],/not valid UTF-8/);
 }
});

test('the compiler-owned UTF-8 validator also compiles and executes natively',()=>{
 const own=readFileSync(new URL('../src/native/utf8.gleam',import.meta.url),'utf8');
 const cases=[[],[65],[194,128],[224,160,128],[237,159,191],[240,144,128,128],[244,143,191,191],[192,128],[237,160,128],[244,144,128,128],[226,130]];
 const body=cases.map(bytes=>`echo valid(<<${bytes.join(',')}>>)` ).join(' ');
 const actual=run(`${own} pub fn main() -> Nil {${body} Nil}`);
 assert.equal(actual.status,0);assert.equal(actual.stderr,'');
 assert.equal(actual.stdout,cases.map(bytes=>valid(new BitArray(Uint8Array.from(bytes)))?'True':'False').join('\n')+'\n');
});
