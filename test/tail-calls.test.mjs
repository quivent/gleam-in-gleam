import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdtempSync,rmSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {BitArray,toList} from '../build/dev/javascript/gleam_native/gleam.mjs';
import {compile} from '../build/dev/javascript/gleam_native/native/compiler.mjs';
import {link,Source} from '../build/dev/javascript/gleam_native/native/project.mjs';
import {module as check} from '../build/dev/javascript/gleam_native/native/check.mjs';
import {collect} from '../build/dev/javascript/gleam_native/native/definitions.mjs';
import {plan_with} from '../build/dev/javascript/gleam_native/native/x64.mjs';
import {assemble,symbols} from '../build/dev/javascript/gleam_native/native/assembler.mjs';
const unwrap=r=>{assert.equal(r.isOk(),true,r[0]);return r[0];};
function lowStack(source,expected){
 const dir=mkdtempSync(join(tmpdir(),'gleam-tail-'));
 try{
  const bytes=unwrap(compile(new BitArray(Buffer.from(source)))).rawBuffer,path=join(dir,'app');writeFileSync(path,bytes,{mode:0o755});
  const code='import os,resource,sys; resource.setrlimit(resource.RLIMIT_CORE,(0,0)); resource.setrlimit(resource.RLIMIT_STACK,(65536,65536)); os.execv(sys.argv[1],[sys.argv[1]])';
  const actual=spawnSync('/usr/bin/python3',['-c',code,path],{encoding:'utf8',timeout:5000});assert.ifError(actual.error);assert.equal(actual.status,0,actual.stderr+' '+actual.signal);assert.equal(actual.stdout,expected);assert.equal(actual.stderr,'');
 }finally{rmSync(dir,{recursive:true,force:true});}
}
test('one million direct self-tail calls finish under a 64 KiB stack',()=>{
 lowStack('fn count(n:Int,a:Int)->Int {case n {0->a _->count(n-1,a+1)}} pub fn main()->Nil {echo count(1000000,0) Nil}','1000000\n');
});
test('tail argument swaps and dependencies remain correct with a small stack',()=>{
 lowStack('fn swap(n:Int,a:Int,b:Int)->Int {case n {0->a*10+b _->swap(n-1,b,a)}} pub fn main()->Nil {echo swap(100001,3,7) Nil}','73\n');
});
test('tail loops entered via named descriptors preserve the hidden caller word',()=>{
 lowStack('fn count(n:Int,a:Int)->Int {case n {0->a _->count(n-1,a+1)}} pub fn main()->Nil {let callback=count echo callback(1000000,0) Nil}','1000000\n');
});
test('emitted self-tail code jumps past the prologue while ordinary recursion keeps its call',()=>{
 const source='fn count(n:Int,a:Int)->Int {case n {0->a _->count(n-1,a+1)}} fn sum(n:Int)->Int {case n {0->0 _->n+sum(n-1)}} pub fn main()->Nil {echo count(3,0) echo sum(3) Nil}';
 const ast=unwrap(link('main',toList([new Source('main',new BitArray(Buffer.from(source)))]))),typed=unwrap(check(ast)),metadata=unwrap(collect(ast)),parts=unwrap(plan_with(typed,metadata)),table=new Map(unwrap(symbols(parts)).toArray()),bytes=Buffer.from(unwrap(assemble(parts)).rawBuffer);
 const start=table.get('fn:count'),loop=table.get('fn:loop:count'),end=table.get('fn:end:count'),sum=table.get('fn:sum'),sumEnd=table.get('fn:end:sum');assert.equal(loop,start+11);
 const dir=mkdtempSync(join(tmpdir(),'gleam-tail-asm-'));
 try{const path=join(dir,'code.bin');writeFileSync(path,bytes);const result=spawnSync('/usr/bin/objdump',['-D','-b','binary','-m','i386:x86-64',path],{encoding:'utf8'});assert.equal(result.status,0,result.stderr);
  const instructions=result.stdout.split('\n').filter(line=>/^\s*[0-9a-f]+:/.test(line));
  const body=(a,b)=>instructions.filter(line=>{const at=parseInt(line.trim().split(':')[0],16);return at>=a&&at<b;}).join('\n');
  assert.match(body(start,end),new RegExp('jmp\\s+0x'+loop.toString(16)+'(?:\\s|$)'));assert.doesNotMatch(body(start,end),new RegExp('call\\s+0x'+start.toString(16)+'(?:\\s|$)'));
  assert.match(body(sum,sumEnd),new RegExp('call\\s+0x'+sum.toString(16)+'(?:\\s|$)'));
  assert.match(body(start,end),/pop\s+%rax/);assert.match(body(start,end),/0x10\(%rbp\)/);assert.match(body(start,end),/0x18\(%rbp\)/);
 }finally{rmSync(dir,{recursive:true,force:true});}
});

test('balanced owned byte concatenation preserves empty, odd and varied chunks',()=>{
 const core=readFileSync(new URL('../src/native/core.gleam',import.meta.url),'utf8');
 lowStack(core+'\npub fn main()->Nil {echo concat([<<>>,<<1>>,<<>>,<<2,3>>,<<>>])==<<1,2,3>> Nil}','True\n');
});
test('balanced concatenation handles 10000 ordered chunks within the ordinary 64 MiB arena',()=>{
 const core=readFileSync(new URL('../src/native/core.gleam',import.meta.url),'utf8');
 const driver=`fn chunks(n:Int,acc:List(BitArray))->List(BitArray) {case n {0->acc _->chunks(n-1,[<<n:32-little,{n+1}:32-little>>,..acc])}}
 fn verify_bytes(bytes:BitArray,n:Int)->Bool {case bytes {<<>> -> n==10001 <<a:32-little,b:32-little,rest:bits>> -> case a==n && b==n+1 {True->verify_bytes(rest,n+1) False->False} _->False}}
 pub fn main()->Nil {let result=concat(chunks(10000,[])) echo byte_length(result) echo verify_bytes(result,1) Nil}`;
 lowStack(core+'\n'+driver,'80000\nTrue\n');
});
