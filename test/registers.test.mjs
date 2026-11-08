import {test} from 'node:test';
import assert from 'node:assert/strict';
import {writeFileSync,mkdtempSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
import {BitArray,toList} from '../build/dev/javascript/gleam_native/gleam.mjs';
import {compile} from '../build/dev/javascript/gleam_native/native/compiler.mjs';
import {link,Source} from '../build/dev/javascript/gleam_native/native/project.mjs';
import {module as check} from '../build/dev/javascript/gleam_native/native/check.mjs';
import {collect} from '../build/dev/javascript/gleam_native/native/definitions.mjs';
import {plan_with} from '../build/dev/javascript/gleam_native/native/x64.mjs';
import {assemble,symbols} from '../build/dev/javascript/gleam_native/native/assembler.mjs';
const unwrap=r=>{assert.equal(r.isOk(),true,r[0]);return r[0];};
function body(source,name){
 const ast=unwrap(link('main',toList([new Source('main',new BitArray(Buffer.from(source)))]))),typed=unwrap(check(ast)),parts=unwrap(plan_with(typed,unwrap(collect(ast)))),table=new Map(unwrap(symbols(parts)).toArray()),bytes=Buffer.from(unwrap(assemble(parts)).rawBuffer);
 const dir=mkdtempSync(join(tmpdir(),'gleam-register-asm-'));
 try{const path=join(dir,'code');writeFileSync(path,bytes);const r=spawnSync('objdump',['-D','--no-show-raw-insn','-b','binary','-m','i386:x86-64',path],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);
 return r.stdout.split('\n').filter(line=>{const m=line.match(/^\s*([a-f0-9]+):/);return m&&parseInt(m[1],16)>=table.get('fn:'+name)&&parseInt(m[1],16)<table.get('fn:end:'+name);}).join('\n');
 }finally{rmSync(dir,{recursive:true,force:true});}
}
test('leaf operands use RCX and RAX without a temporary stack spill',()=>{
 const asm=body('fn f(a:Int,b:Int)->Int {a-b} pub fn main()->Nil {echo f(9,4) Nil}','f');
 assert.match(asm,/mov\s+0x18\(%rbp\),%rcx/);assert.match(asm,/mov\s+0x10\(%rbp\),%rax/);
 assert.doesNotMatch(asm,/push\s+%rax|pop\s+%rcx/);assert.match(asm,/sub\s+%rax,%rcx/);
});
test('compound left result is retained only after its call before a leaf RHS',()=>{
 const asm=body('fn g()->Int {7} fn f(a:Int)->Int {g()+a} pub fn main()->Nil {echo f(4) Nil}','f');
 assert.match(asm,/call/);assert.match(asm,/mov\s+%rax,%rcx/);assert.doesNotMatch(asm,/push\s+%rax|pop\s+%rcx/);
});
test('a right-hand call keeps the spill across scratch-register clobbers',()=>{
 const asm=body('fn g()->Int {case 3 {x->x*7}} fn f(a:Int)->Int {a+g()} pub fn main()->Nil {echo f(4) Nil}','f');
 assert.match(asm,/push\s+%rax[\s\S]*call[\s\S]*pop\s+%rcx[\s\S]*add\s+%rcx,%rax/);
});
test('register retention preserves checked overflow before any echo',()=>{
 const source='pub fn main()->Nil {let max=9007199254740991*1024+1023 echo max+1 Nil}',dir=mkdtempSync(join(tmpdir(),'gleam-register-overflow-'));
 try{const path=join(dir,'app');writeFileSync(path,unwrap(compile(new BitArray(Buffer.from(source)))).rawBuffer,{mode:0o755});const r=spawnSync(path,[],{encoding:'utf8'});assert.equal(r.status,70);assert.equal(r.signal,null);assert.equal(r.stdout,'');}
 finally{rmSync(dir,{recursive:true,force:true});}
});
