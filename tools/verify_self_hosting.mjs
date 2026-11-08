#!/usr/bin/env node
// Development-only orchestration: create one bootstrap-native seed, freeze its
// actual Gleam inputs, run TWO independent native rebuilds, then qualify the
// rebuilt compiler. Native rebuilds never invoke Node or the upstream compiler.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,readdirSync,mkdirSync,mkdtempSync,rmSync,existsSync} from 'node:fs';
import {join,dirname} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {build} from '../build/dev/javascript/gleam_native/native/cli_builder.mjs';
import {compile_project} from '../build/dev/javascript/gleam_native/native/compiler.mjs';
import {Source} from '../build/dev/javascript/gleam_native/native/project.mjs';
import {BitArray,toList} from '../build/dev/javascript/gleam_native/gleam.mjs';
import {source_capacity,arena_capacity} from '../build/dev/javascript/gleam_native/native/cli_limits.mjs';
const root=fileURLToPath(new URL('../',import.meta.url));
const sha=b=>createHash('sha256').update(b).digest('hex');
const dir=mkdtempSync(join(tmpdir(),'gleam-self-host-')),sourceRoot=join(dir,'source'),observations=[];
const unwrap=r=>{assert.equal(r.isOk(),true,r[0]);return r[0];};
function run(binary,args=[],cwd=dir,timeout=30000){const r=spawnSync(binary,args,{cwd,env:{PATH:''},encoding:'utf8',timeout,maxBuffer:1048576});assert.ifError(r.error);return r;}
function elf(bytes){const offset=Number(bytes.readBigUInt64LE(32)),size=bytes.readUInt16LE(54),count=bytes.readUInt16LE(56),headers=[];for(let i=0;i<count;i++)headers.push({kind:bytes.readUInt32LE(offset+i*size),flags:bytes.readUInt32LE(offset+i*size+4)});assert.deepEqual([...bytes.subarray(0,4)],[127,69,76,70]);return {dynamicLoader:headers.some(h=>h.kind===3),dynamicSegment:headers.some(h=>h.kind===2),nonExecutableStack:headers.some(h=>h.kind===0x6474e551&&h.flags===6)};}
const files=readdirSync(join(root,'src/native')).filter(n=>n.endsWith('.gleam')).sort().map(name=>({name:'native/'+name.slice(0,-6),path:'src/native/'+name,bytes:readFileSync(join(root,'src/native',name))}));
const originalHashes=Object.fromEntries(files.map(f=>[f.path,sha(f.bytes)]));
const receipt={schema:'gleam-in-gleam.self-hosting-verification/1',observedAt:new Date().toISOString(),sourceSHA256:originalHashes,sourceModules:files.length,sourceBytes:files.reduce((n,f)=>n+f.bytes.length,0),frozenInputs:true,limits:{sourceBytes:source_capacity(),compilerArenaBytes:arena_capacity(),ordinaryProgramArenaBytes:67108864},bootstrap:{sourceLanguage:'Gleam',runtime:'upstream Gleam-generated JavaScript, used only to emit the first native seed'},stages:[],nativeCorpus:[],selfHosting:false,fullGleamCompatibility:false};
try{
 for(const f of files){const path=join(sourceRoot,f.name+'.gleam');mkdirSync(dirname(path),{recursive:true});writeFileSync(path,f.bytes,{flag:'wx'});}
 const seed=Buffer.from(unwrap(build(toList(files.map(f=>new Source(f.name,new BitArray(f.bytes)))))).rawBuffer);
 const first=join(dir,'stage1');writeFileSync(first,seed,{flag:'wx',mode:0o755});
 receipt.stages.push({stage:1,producer:'bootstrap implementation emits native CLI',bytes:seed.length,sha256:sha(seed),...elf(seed)});
 let previous=first;
 for(const stage of [2,3]){
  const output=join(dir,'stage'+stage),args=['--build-compiler',output,'--source-root',sourceRoot],result=run(previous,args);
  assert.equal(result.status,0,result.stderr+' '+result.signal);assert.equal(result.stdout,'');assert.equal(result.stderr,'');
  const bytes=readFileSync(output);assert.deepEqual(bytes,seed,'Native rebuild differs at stage '+stage);
  const version=run(output,['--version']);assert.equal(version.status,0);assert.match(version.stdout,/gleam-native 0\.1\.0/);assert.equal(version.stderr,'');
  receipt.stages.push({stage,producer:'native stage '+(stage-1),operation:'--build-compiler NEW_OUTPUT --source-root FROZEN_SOURCE',exitCode:result.status,bytes:bytes.length,sha256:sha(bytes),byteIdenticalToSeed:true,versionStdout:version.stdout,...elf(bytes)});
  previous=output;
 }
 // Source-sensitivity control: compile an intentionally different, isolated
 // version literal. The repository and identical-input rebuild chain stay intact.
 const changed=files.map(f=>({...f,bytes:f.name==='native/cli'?Buffer.from(f.bytes.toString().replace('gleam-native 0.1.0','gleam-native 0.1.1')):f.bytes}));
 assert.notEqual(sha(changed.find(f=>f.name==='native/cli').bytes),originalHashes['src/native/cli.gleam']);
 for(const f of changed)writeFileSync(join(sourceRoot,f.name+'.gleam'),f.bytes);
 const variant=join(dir,'source-sensitivity'),variantRun=run(previous,['--build-compiler',variant,'--source-root',sourceRoot]);
 assert.equal(variantRun.status,0,variantRun.stderr);assert.equal(variantRun.signal,null);
 const variantBytes=readFileSync(variant),variantReference=Buffer.from(unwrap(build(toList(changed.map(f=>new Source(f.name,new BitArray(f.bytes)))))).rawBuffer);
 assert.notEqual(sha(variantBytes),sha(seed));assert.deepEqual(variantBytes,variantReference);
 const variantVersion=run(variant,['--version']);assert.equal(variantVersion.status,0);assert.match(variantVersion.stdout,/gleam-native 0\.1\.1/);
 receipt.sourceSensitivity={isolatedChange:'native/cli version literal 0.1.0 -> 0.1.1',compilerStage:3,compileExit:variantRun.status,bytes:variantBytes.length,sha256:sha(variantBytes),differsFromSeed:true,byteIdenticalToBootstrap:true,versionStdout:variantVersion.stdout};
 const fixturePaths=['test/modules-fixtures.json','test/aliases-guards-fixtures.json','test/strings-prelude-fixtures.json','test/multi-pattern-fixtures.json','test/equality-fixtures.json','test/pattern-alias-fixtures.json','test/integer-coverage-fixtures.json','test/tail-calls-fixtures.json','test/register-fixtures.json','test/branch-slots-fixtures.json','test/allocated-expression-fixtures.json','test/allocated-call-fixtures.json'];
 const fixtures=fixturePaths.flatMap(p=>JSON.parse(readFileSync(join(root,p),'utf8')));
 const grammar=JSON.parse(readFileSync(join(root,'test/grammar-fixtures.json'),'utf8')).map(f=>({...f,entry:'main',files:{main:f.source}}));
 receipt.fixtureSHA256=Object.fromEntries([...fixturePaths,'test/grammar-fixtures.json'].map(p=>[p,sha(readFileSync(join(root,p)))]));
 for(const [index,f]of [...fixtures,...grammar].entries()){
  const cwd=join(dir,'case-'+index),output=join(cwd,'program');mkdirSync(cwd);
  for(const [name,source]of Object.entries(f.files)){const path=join(cwd,name+'.gleam');mkdirSync(dirname(path),{recursive:true});writeFileSync(path,source);}
  const actual=run(previous,[f.entry+'.gleam',output],cwd,10000);assert.equal(actual.signal,null,f.name);assert.equal(actual.status===0,f.accepted,f.name+': '+actual.stderr);
  const observation={name:f.name,accepted:f.accepted,compilerStage:3,compileExit:actual.status};
  if(f.accepted){assert.equal(actual.stdout,'');assert.equal(actual.stderr,'');const bytes=readFileSync(output),reference=Buffer.from(unwrap(compile_project(f.entry,toList(Object.entries(f.files).map(([n,s])=>new Source(n,new BitArray(Buffer.from(s))))))).rawBuffer);assert.deepEqual(bytes,reference,f.name+' bootstrap/native byte mismatch');const result=run(output,[],cwd,5000);assert.equal(result.status,0,f.name+': '+result.stderr);assert.equal(result.stdout,f.stdout,f.name);assert.equal(result.stderr,'');Object.assign(observation,{bytes:bytes.length,sha256:sha(bytes),byteIdenticalToBootstrap:true,runExit:result.status,stdout:result.stdout});}
  else{assert.ok([1,2].includes(actual.status),f.name+' crashed instead of rejecting');assert.equal(existsSync(output),false,f.name);Object.assign(observation,{diagnostic:actual.stderr,noOutput:true});}
  receipt.nativeCorpus.push(observation);
 }
 receipt.nativeCorpusSummary={total:receipt.nativeCorpus.length,accepted:receipt.nativeCorpus.filter(f=>f.accepted).length,rejected:receipt.nativeCorpus.filter(f=>!f.accepted).length,allAcceptedOutputsByteIdentical:true,compilerStage:3};
 receipt.selfHosting=true;
 for(const f of files)assert.equal(sha(readFileSync(join(root,f.path))),originalHashes[f.path],'Source changed during verification: '+f.path);
 for(const image of receipt.stages){assert.equal(image.dynamicLoader,false);assert.equal(image.dynamicSegment,false);assert.equal(image.nonExecutableStack,true);}
 if(process.argv[2])writeFileSync(join(root,process.argv[2]),JSON.stringify(receipt,null,2)+'\n');
 console.log(JSON.stringify({selfHosting:receipt.selfHosting,stages:receipt.stages.map(s=>({stage:s.stage,bytes:s.bytes,sha256:s.sha256})),nativeCorpus:receipt.nativeCorpusSummary},null,2));
}finally{rmSync(dir,{recursive:true,force:true});}
