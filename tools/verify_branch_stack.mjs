#!/usr/bin/env node
// Development-only controlled stack comparison. Only owned children are run;
// neither Python nor the historical compiler becomes a delivered dependency.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdtempSync,rmSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
const [before,after,receiptPath]=process.argv.slice(2).map(p=>resolve(p));
assert.ok(before&&after&&receiptPath,'BEFORE_COMPILER AFTER_COMPILER RECEIPT required');
const sha=b=>createHash('sha256').update(b).digest('hex');
const arms=Array.from({length:8},(_,n)=>`${n}->{let a=n+1 let b=a+2 let c=b+3 c}`).join(' ');
const source=`fn f(n:Int)->Int {case n {${arms} _->n+f(n-1)}} pub fn main()->Nil {echo f(600) Nil}`;
const directory=mkdtempSync(join(tmpdir(),'gleam-branch-stack-'));
const launcher='import os,resource,sys; resource.setrlimit(resource.RLIMIT_CORE,(0,0)); resource.setrlimit(resource.RLIMIT_STACK,(65536,65536)); resource.setrlimit(resource.RLIMIT_CPU,(5,5)); os.execv(sys.argv[1],[sys.argv[1]])';
const observations=[];
try{
 writeFileSync(join(directory,'main.gleam'),source);
 for(const [label,compiler]of [['before',before],['after',after]]){
  const output=join(directory,label),compiled=spawnSync(compiler,['main.gleam',output,'--source-root',directory],{encoding:'utf8',timeout:10000,env:{PATH:''}});
  assert.ifError(compiled.error);assert.equal(compiled.status,0,compiled.stderr);assert.equal(compiled.signal,null);
  const image=readFileSync(output),prologue=image.indexOf(Buffer.from([85,72,137,229,72,129,236]));assert.ok(prologue>=176);
  const run=spawnSync('/usr/bin/python3',['-c',launcher,output],{encoding:'utf8',timeout:10000});assert.ifError(run.error);
  observations.push({label,compilerSHA256:sha(readFileSync(compiler)),programSHA256:sha(image),frameBytes:image.readUInt32LE(prologue+7),compileExit:compiled.status,runExit:run.status,signal:run.signal,stdout:run.stdout,stderr:run.stderr});
 }
 assert.equal(observations[0].signal,'SIGSEGV');assert.equal(observations[0].stdout,'');
 assert.equal(observations[1].runExit,0);assert.equal(observations[1].signal,null);assert.equal(observations[1].stdout,'180285\n');assert.equal(observations[1].stderr,'');
 assert.equal(observations[0].frameBytes,208);assert.equal(observations[1].frameBytes,32);
 const receipt={schema:'gleam-in-gleam.branch-stack-comparison/1',observedAt:new Date().toISOString(),source,sourceSHA256:sha(Buffer.from(source)),stackLimitBytes:65536,coreLimitBytes:0,cpuLimitSeconds:5,recursion:'non-tail n+f(n-1), start 600, terminal arm 7',observations,limitations:['One bounded non-tail recursion workload, not arbitrary-input reliability or a timing benchmark','Only sibling-local frame space is reused; no general register allocator']};
 writeFileSync(receiptPath,JSON.stringify(receipt,null,2)+'\n');console.log(JSON.stringify(receipt,null,2));
}finally{rmSync(directory,{recursive:true,force:true});}
