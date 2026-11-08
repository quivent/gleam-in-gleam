#!/usr/bin/env node
// Seeded development oracle, not a delivered compiler/runtime dependency.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync,mkdtempSync,rmSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {tmpdir,homedir} from 'node:os';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {compile_project} from '../build/dev/javascript/gleam_native/native/compiler.mjs';
import {Source,link} from '../build/dev/javascript/gleam_native/native/project.mjs';
import {module as check} from '../build/dev/javascript/gleam_native/native/check.mjs';
import * as registers from '../build/dev/javascript/gleam_native/native/registers.mjs';
import {BitArray,toList} from '../build/dev/javascript/gleam_native/gleam.mjs';
assert.equal(process.argv.length,4,'COMPILER RECEIPT required');
const compiler=resolve(process.argv[2]),receiptPath=resolve(process.argv[3]);
const gleam=process.env.GLEAM||join(homedir(),'.local/share/gleam-native/bootstrap/1.19.2/gleam');
const sha=b=>createHash('sha256').update(b).digest('hex'),unwrap=r=>{assert.equal(r.isOk(),true,r[0]);return r[0];};
const seed=0x6a09e667,limit=9007199254740991n,values=[2n,-3n,4n,-2n,1n],names=['a','b','c','d','e'];let random=seed;
function next(){random^=random<<13;random^=random>>>17;random^=random<<5;return random>>>0;}
function tree(depth){
 if(depth===0||next()%5===0){const index=next()%5;return {source:names[index],value:values[index],pressure:1};}
 const left=tree(depth-1),right=tree(depth-1),op=['+','-','*'][next()%3];if(!left||!right)return null;
 const value=op==='+'?left.value+right.value:op==='-'?left.value-right.value:left.value*right.value;if(value>limit||value< -limit)return null;
 return {source:`{${left.source} ${op} ${right.source}}`,value,pressure:Math.max(left.pressure,1+right.pressure)};
}
const cases=[];for(let i=0;i<100;i++){let value;do{value=tree(3+i%4);}while(!value);cases.push({name:'f_'+i,...value});}
const source=cases.map(c=>`fn ${c.name}(a:Int,b:Int,c:Int,d:Int,e:Int)->Int {${c.source}}`).join('\n')+'\npub fn main()->Nil {'+cases.map(c=>`echo ${c.name}(2,-3,4,-2,1)`).join('\n')+'\nNil}';
const expected=cases.map(c=>String(c.value)+'\n').join(''),dir=mkdtempSync(join(tmpdir(),'gleam-region-oracle-'));
function run(cmd,args,options={}){const r=spawnSync(cmd,args,{encoding:'utf8',timeout:30000,maxBuffer:2097152,...options});assert.ifError(r.error);assert.equal(r.status,0,r.stderr+' '+r.signal);return r;}
try{
 mkdirSync(join(dir,'src'));writeFileSync(join(dir,'src/main.gleam'),source);writeFileSync(join(dir,'gleam.toml'),'name="region_oracle"\nversion="0.1.0"\ntarget="javascript"\n');
 run(gleam,['build'],{cwd:dir});const reference=run(process.execPath,['--input-type=module','-e',`import {main} from ${JSON.stringify('file://'+join(dir,'build/dev/javascript/region_oracle/main.mjs'))};main();`]);
 const clean=reference.stderr.replace(/\x1b\[[0-9;]*m/g,''),upstream=clean.split('\n').filter(l=>/^-?\d+$/.test(l)).join('\n')+'\n';assert.equal(upstream,expected);
 const output=join(dir,'program');run(compiler,['main.gleam',output,'--source-root',join(dir,'src')],{env:{PATH:''}});
 const observed=run(output,[],{env:{PATH:''}});assert.equal(observed.stdout,expected);assert.equal(observed.stderr,'');
 const sources=toList([new Source('main',new BitArray(Buffer.from(source)))]),bootstrap=Buffer.from(unwrap(compile_project('main',sources)).rawBuffer);assert.deepEqual(readFileSync(output),bootstrap);
 const typed=unwrap(check(unwrap(link('main',sources)))).toArray();let spilling=0;
 const coverage=cases.map(c=>{const f=typed.find(f=>f.name===c.name),code=unwrap(registers.plan(f.body.toArray()[0][0])).toArray(),spills=code.filter(i=>i instanceof registers.Push).length;assert.equal(spills,code.filter(i=>i instanceof registers.Pop).length);if(spills)spilling++;return {name:c.name,expected:String(c.value),operandPressure:c.pressure,staticSpills:spills};});
 assert.ok(spilling>0);assert.ok(coverage.some(c=>c.operandPressure>=6));
 const receipt={schema:'gleam-in-gleam.seeded-register-regions/1',observedAt:new Date().toISOString(),seed,count:cases.length,source,sourceSHA256:sha(Buffer.from(source)),compilerSHA256:sha(readFileSync(compiler)),programSHA256:sha(bootstrap),bytes:bootstrap.length,upstreamCompiler:run(gleam,['--version']).stdout.trim(),independentBigIntExpected:true,upstreamStdoutMatches:true,nativeStdoutMatches:true,byteIdenticalToBootstrap:true,spillingRegions:spilling,coverage,limits:'Every intermediate value is within exact +/- (2^53-1); overflow tested separately, no speed claim'};
 writeFileSync(receiptPath,JSON.stringify(receipt,null,2)+'\n');console.log(JSON.stringify({count:cases.length,spillingRegions:spilling,maximumPressure:Math.max(...coverage.map(c=>c.operandPressure)),nativeAndUpstreamAgree:true},null,2));
}finally{rmSync(dir,{recursive:true,force:true});}
