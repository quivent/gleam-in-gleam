// Development-only whole-source probe. Never part of compiler execution.
import {compile_project} from '../build/dev/javascript/gleam_native/native/compiler.mjs';
import {lex} from '../build/dev/javascript/gleam_native/native/lexer.mjs';
import {parse} from '../build/dev/javascript/gleam_native/native/parser.mjs';
import {Source} from '../build/dev/javascript/gleam_native/native/project.mjs';
import {BitArray,toList} from '../build/dev/javascript/gleam_native/gleam.mjs';
import {readFileSync,readdirSync,mkdtempSync,writeFileSync,rmSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root=new URL('../',import.meta.url);
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const driver=readFileSync(new URL('test/owned-compiler-api-driver.source',root));
const files=readdirSync(new URL('src/native/',root)).filter(n=>n.endsWith('.gleam')).sort().map(name=>{
 const path='src/native/'+name,bytes=readFileSync(new URL(path,root));
 return {path,name:'native/'+name.slice(0,-6),bytes};
});
const receipt={schema:'gleam-in-gleam.complete-api-probe/1',observedAt:new Date().toISOString(),
 sourceSHA256:Object.fromEntries(files.map(f=>[f.path,sha(f.bytes)])),
 driverPath:'test/owned-compiler-api-driver.source',driverSHA256:sha(driver),
 entry:'native/compiler',selfHosting:false,frontendFailures:[]};
for(const f of files){
 const tokens=lex(new BitArray(f.bytes)),parsed=tokens.isOk()?parse(tokens[0]):tokens;
 if(!parsed.isOk())receipt.frontendFailures.push({path:f.path,error:parsed[0]});
}
try {
 const result=compile_project(receipt.entry,toList(files.map(f=>new Source(f.name,new BitArray(
  f.name===receipt.entry?Buffer.concat([f.bytes,Buffer.from('\n'),driver]):f.bytes)))));
 receipt.compiled=result.isOk();
 if(!result.isOk()) receipt.error=result[0];
 else {
  const dir=mkdtempSync('/tmp/tamsin-owned-compiler-api-');
  try {
   const path=dir+'/app';writeFileSync(path,result[0].rawBuffer,{mode:0o755});
   const run=spawnSync(path,{encoding:'utf8',timeout:10000,maxBuffer:4096});
   receipt.artifact={bytes:result[0].rawBuffer.length,sha256:sha(result[0].rawBuffer)};
   receipt.execution={status:run.status,signal:run.signal,stdout:run.stdout,stderr:run.stderr,error:run.error?.message};
  } finally {rmSync(dir,{recursive:true,force:true});}
 }
} catch(error){receipt.bootstrapError={name:error.name,message:error.message};}
if(process.argv[2])writeFileSync(fileURLToPath(new URL(process.argv[2],root)),JSON.stringify(receipt,null,2)+'\n');
console.log(JSON.stringify({compiled:receipt.compiled,error:receipt.error,frontendFailures:receipt.frontendFailures,artifact:receipt.artifact,execution:receipt.execution,bootstrapError:receipt.bootstrapError},null,2));
