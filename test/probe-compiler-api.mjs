// Development-only whole-source probe. Never part of compiler execution.
import {compile as compileSingle,compile_project} from '../build/dev/javascript/gleam_native/native/compiler.mjs';
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
function elfMetadata(data){
 const bytes=Buffer.from(data);
 if(!bytes.subarray(0,4).equals(Buffer.from([127,69,76,70])))throw new Error('Expected ELF');
 const offset=Number(bytes.readBigUInt64LE(32)),size=bytes.readUInt16LE(54),count=bytes.readUInt16LE(56),headers=[];
 for(let i=0;i<count;i++)headers.push({kind:bytes.readUInt32LE(offset+i*size),flags:bytes.readUInt32LE(offset+i*size+4)});
 return {dynamicLoader:headers.some(h=>h.kind===3),dynamicSegment:headers.some(h=>h.kind===2),
  nonExecutableStack:headers.some(h=>h.kind===0x6474e551&&h.flags===6)};
}

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
   const run=spawnSync(path,{encoding:'utf8',timeout:10000,maxBuffer:1048576});
   receipt.artifact={bytes:result[0].rawBuffer.length,sha256:sha(result[0].rawBuffer),...elfMetadata(result[0].rawBuffer)};
   receipt.execution={status:run.status,signal:run.signal,stdoutBytes:Buffer.byteLength(run.stdout??''),stdoutSHA256:sha(run.stdout??''),stderr:run.stderr,error:run.error?.message};
   const fixtures=[
    {source:'pub fn main() -> Nil { echo 7 Nil }',stdout:'7\n'},
    {source:'fn choose(n: Int) -> Int {case n {4294967296 -> 7 _ -> 0}} pub fn main() -> Nil {let #(x,y) as whole=#(3,4) echo choose(4294967296) echo x+y+whole.0 Nil}',stdout:'7\n10\n'}
   ];
   if(run.status===0&&run.stderr===''){
    const lines=run.stdout.trimEnd().split('\n');let cursor=0;receipt.nativePrograms=[];
    for(const [index,fixture] of fixtures.entries()){
     const sizeText=lines[cursor++],size=Number(sizeText);
     if(!/^\d+$/.test(sizeText)||!Number.isSafeInteger(size)||size<64||size>100000||cursor+size>lines.length)throw new Error('Invalid native compiler byte stream length');
     const values=lines.slice(cursor,cursor+size);cursor+=size;
     if(values.some(s=>!/^\d+$/.test(s)||Number(s)>255))throw new Error('Invalid native compiler byte');
     const bytes=Buffer.from(values.map(Number));
     const reference=compileSingle(new BitArray(Buffer.from(fixture.source)));
     if(!reference.isOk())throw new Error('Bootstrap comparison rejected fixture: '+reference[0]);
     const child=dir+'/child-'+index;writeFileSync(child,bytes,{mode:0o755});
     const actual=spawnSync(child,{encoding:'utf8',timeout:5000,maxBuffer:4096});
     receipt.nativePrograms.push({source:fixture.source,bytes:size,sha256:sha(bytes),
      bootstrapSHA256:sha(reference[0].rawBuffer),byteIdentical:bytes.equals(Buffer.from(reference[0].rawBuffer)),
      isELF:bytes.subarray(0,4).equals(Buffer.from([127,69,76,70])),...elfMetadata(bytes),
      status:actual.status,signal:actual.signal,stdout:actual.stdout,stderr:actual.stderr,error:actual.error?.message,
      expectedStdout:fixture.stdout});
    }
    if(cursor!==lines.length)throw new Error('Unexpected trailing native compiler output');
    receipt.nativeCompilationVerified=receipt.nativePrograms.every(p=>p.byteIdentical&&p.isELF&&p.status===0&&p.stdout===p.expectedStdout&&p.stderr===''&&!p.dynamicLoader&&!p.dynamicSegment&&p.nonExecutableStack);
   }
  } finally {rmSync(dir,{recursive:true,force:true});}
 }
} catch(error){receipt.bootstrapError={name:error.name,message:error.message,stack:error.stack?.split('\n').slice(0,12)};}
if(process.argv[2])writeFileSync(fileURLToPath(new URL(process.argv[2],root)),JSON.stringify(receipt,null,2)+'\n');
console.log(JSON.stringify({compiled:receipt.compiled,error:receipt.error,frontendFailures:receipt.frontendFailures,artifact:receipt.artifact,execution:receipt.execution,nativePrograms:receipt.nativePrograms,nativeCompilationVerified:receipt.nativeCompilationVerified,bootstrapError:receipt.bootstrapError},null,2));
