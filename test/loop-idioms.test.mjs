import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdtempSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
import {BitArray,toList} from '../build/dev/javascript/gleam_native/gleam.mjs';
import {Source,link} from '../build/dev/javascript/gleam_native/native/project.mjs';
import {module as check} from '../build/dev/javascript/gleam_native/native/check.mjs';
import {collect} from '../build/dev/javascript/gleam_native/native/definitions.mjs';
import {recognize} from '../build/dev/javascript/gleam_native/native/loop_idioms.mjs';
import {plan_with} from '../build/dev/javascript/gleam_native/native/x64.mjs';
import {assemble,symbols} from '../build/dev/javascript/gleam_native/native/assembler.mjs';
import {compile} from '../build/dev/javascript/gleam_native/native/compiler.mjs';
const unwrap=r=>{assert.equal(r.isOk(),true,r[0]);return r[0];};
const fixtureData=JSON.parse(readFileSync(new URL('./length-idiom-fixtures.json',import.meta.url),'utf8'));
function typed(source){const ast=unwrap(link('main',toList([new Source('main',new BitArray(Buffer.from(source)))])));return {ast,functions:unwrap(check(ast))};}
test('byte-count recognition is structural and rejects changed semantics',()=>{
 for(const f of fixtureData){const {functions}=typed(f.files.main),walk=functions.toArray().find(f=>f.name==='walk');assert.equal(recognize(walk).isOk(),!f.name.includes('reject-'),f.name);}
});
test('generic byte counting emits a length load and checked add without allocation or looping',()=>{
 const {ast,functions}=typed(fixtureData[0].files.main),parts=unwrap(plan_with(functions,unwrap(collect(ast)))),table=new Map(unwrap(symbols(parts)).toArray()),bytes=Buffer.from(unwrap(assemble(parts)).rawBuffer),dir=mkdtempSync(join(tmpdir(),'gleam-length-asm-'));
 try{const path=join(dir,'code');writeFileSync(path,bytes);const r=spawnSync('objdump',['-D','--no-show-raw-insn','-b','binary','-m','i386:x86-64',path],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);const body=r.stdout.split('\n').filter(line=>{const m=line.match(/^\s*([a-f0-9]+):/);return m&&parseInt(m[1],16)>=table.get('fn:walk')&&parseInt(m[1],16)<table.get('fn:end:walk');}).join('\n');assert.match(body,/mov\s+0x10\(%rax\),%rax/);assert.match(body,/add\s+%rcx,%rax/);assert.match(body,/\bjo\b/);assert.doesNotMatch(body,/\bcall\b|\bjmp\b/);assert.equal(table.get('fn:end:walk')-table.get('fn:walk'),40);}
 finally{rmSync(dir,{recursive:true,force:true});}
});
test('collapsed counting preserves signed overflow at the accumulator boundary',()=>{
 const source='fn walk(b:BitArray,n:Int)->Int {case b {<<_,rest:bits>>->walk(rest,n+1) _->n}} pub fn main()->Nil {let max=9007199254740991*1024+1023 echo walk(<<1>>,max) Nil}',dir=mkdtempSync(join(tmpdir(),'gleam-length-overflow-'));
 try{const path=join(dir,'app');writeFileSync(path,unwrap(compile(new BitArray(Buffer.from(source)))).rawBuffer,{mode:0o755});const r=spawnSync(path,[],{encoding:'utf8'});assert.equal(r.status,70);assert.equal(r.stdout,'');assert.equal(r.signal,null);}
 finally{rmSync(dir,{recursive:true,force:true});}
});
