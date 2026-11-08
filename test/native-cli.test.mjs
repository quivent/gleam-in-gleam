import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,readdirSync,mkdtempSync,mkdirSync,rmSync,existsSync,statSync,symlinkSync,readlinkSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {source_capacity,arena_capacity} from '../build/dev/javascript/gleam_native/native/cli_limits.mjs';
import {fileURLToPath} from 'node:url';
import {compile_project} from '../build/dev/javascript/gleam_native/native/compiler.mjs';
import {link,Source} from '../build/dev/javascript/gleam_native/native/project.mjs';
import {BitArray,toList} from '../build/dev/javascript/gleam_native/gleam.mjs';
import {collect} from '../build/dev/javascript/gleam_native/native/definitions.mjs';
import {generate as runtimePlan} from '../build/dev/javascript/gleam_native/native/cli_runtime.mjs';
const root=fileURLToPath(new URL('../',import.meta.url)),workspace=mkdtempSync(join(tmpdir(),'gleam-native-cli-'));
const binary=process.env.NATIVE_CLI_TEST_BINARY||join(workspace,'compiler'),observations=[];
const sourceLimit=Number(process.env.NATIVE_CLI_TEST_SOURCE_LIMIT||source_capacity());
const diagnosticManifest=process.env.NATIVE_CLI_TEST_BUILD_MANIFEST?JSON.parse(readFileSync(process.env.NATIVE_CLI_TEST_BUILD_MANIFEST,'utf8')):null;
const sha=data=>createHash('sha256').update(data).digest('hex');
if(!process.env.NATIVE_CLI_TEST_BINARY){const built=spawnSync(process.execPath,[join(root,'build-native.mjs'),binary],{encoding:'utf8',timeout:60000});assert.equal(built.status,0,built.stderr);}
const artifact=readFileSync(binary);
if(diagnosticManifest){assert.equal(createHash("sha256").update(artifact).digest("hex"),diagnosticManifest.artifact.sha256);assert.equal(sourceLimit,diagnosticManifest.sourceCapBytes);for(const [p,h]of Object.entries(diagnosticManifest.sourceSHA256))assert.equal(createHash("sha256").update(readFileSync(join(root,p))).digest("hex"),h,p);}
function command(args,cwd,extra={}){
 const result=spawnSync(binary,args,{cwd,env:{...process.env,PATH:''},encoding:'utf8',timeout:15000,...extra});
 assert.ifError(result.error);return result;
}
function fixture(files={main:'pub fn main() -> Nil {echo 7 Nil}'}){
 const dir=mkdtempSync(join(workspace,'case-'));for(const [name,source]of Object.entries(files)){
  const path=join(dir,name+'.gleam');mkdirSync(join(path,'..'),{recursive:true});writeFileSync(path,source);
 }return dir;
}
function reference(files,entry='main'){
 const result=compile_project(entry,toList(Object.entries(files).map(([name,source])=>new Source(name,new BitArray(Buffer.from(source))))));
 assert.equal(result.isOk(),true,result[0]);return Buffer.from(result[0].rawBuffer);
}
function success(result,output,expected,stdout){
 assert.equal(result.status,0,result.stderr);assert.equal(result.stdout,'');assert.equal(result.stderr,'');
 const bytes=readFileSync(output);assert.deepEqual(bytes,expected);assert.equal(statSync(output).mode&0o777,0o755);
 const run=spawnSync(output,{encoding:'utf8',timeout:5000,env:{PATH:''}});assert.equal(run.status,0);assert.equal(run.stdout,stdout);assert.equal(run.stderr,'');
 observations.push({kind:'compile-execute',bytes:bytes.length,sha256:sha(bytes),byteIdentical:true,stdout:run.stdout});
}
function noTemporary(dir){assert.equal(readdirSync(dir).some(n=>n.includes('.gleam-tmp-')),false);}
function failure(result,code=1){assert.equal(result.status,code,result.stderr);assert.notEqual(result.stderr,'');}

after(()=>{
 if(process.env.NATIVE_CLI_RECEIPT){
  const offset=Number(artifact.readBigUInt64LE(32)),size=artifact.readUInt16LE(54),count=artifact.readUInt16LE(56),headers=[];
  for(let i=0;i<count;i++)headers.push({kind:artifact.readUInt32LE(offset+i*size),flags:artifact.readUInt32LE(offset+i*size+4)});
  let disassembly;
  if(process.env.NATIVE_CLI_ASM){
   const base=Number(artifact.readBigUInt64LE(offset+16)),entry=Number(artifact.readBigUInt64LE(24));
   const sections=[{name:'entry/dispatch prefix',start:entry-base,length:640},
    {name:'owned read syscall helper prefix',signature:'554889e54881ec100100004889bdb8ffffff',length:640},
    {name:'owned write syscall helper prefix',signature:'554889e54881ec500000004889bdc8ffffff',length:640}];
   let listing='Actual native CLI instruction windows; includes trailing instructions after selected prefixes.\n';
   for(const [index,section]of sections.entries()){
    const start=section.start??artifact.indexOf(Buffer.from(section.signature,'hex'));assert.ok(start>=0);
    if(section.signature)assert.equal(artifact.indexOf(Buffer.from(section.signature,'hex'),start+1),-1);
    const file=join(workspace,'window-'+index+'.bin');writeFileSync(file,artifact.subarray(start,start+section.length));
    const dumped=spawnSync('/usr/bin/objdump',['-D','-b','binary','-m','i386:x86-64','--adjust-vma='+String(base+start),file],{encoding:'utf8'});assert.equal(dumped.status,0,dumped.stderr);
    listing+='\n'+section.name+'\n'+dumped.stdout.replaceAll(file,'native-cli-window-'+index+'.bin');
   }
   listing=listing.split('\n').map(line=>line.trimEnd()).join('\n');
   writeFileSync(process.env.NATIVE_CLI_ASM,listing);disassembly={path:'evidence/native-cli-disassembly.txt',sha256:sha(listing),kind:'selected actual instruction windows'};
  }
  const sources=Object.fromEntries(readdirSync(join(root,'src/native')).filter(n=>n.endsWith('.gleam')).sort().map(n=>['src/native/'+n,sha(readFileSync(join(root,'src/native',n)))]));
  writeFileSync(process.env.NATIVE_CLI_RECEIPT,JSON.stringify({schema:'gleam-in-gleam.native-cli/1',observedAt:new Date().toISOString(),sourceSHA256:sources,buildBridgeSHA256:sha(readFileSync(join(root,'build-native.mjs'))),testSHA256:sha(readFileSync(fileURLToPath(import.meta.url))),shortIOHarnessSHA256:sha(readFileSync(join(root,'test/short-io-trace.py'))),artifact:{bytes:artifact.length,sha256:sha(artifact),dynamicLoader:headers.some(h=>h.kind===3),dynamicSegment:headers.some(h=>h.kind===2),nonExecutableStack:headers.some(h=>h.kind===0x6474e551&&h.flags===6)},observations,disassembly,limits:{sourceBytes:sourceLimit,arenaBytes:diagnosticManifest?.arenaCapacityBytes??arena_capacity()},diagnostic:Boolean(diagnosticManifest),selfHosting:false},null,2)+'\n');
 }
 rmSync(workspace,{recursive:true,force:true});
});

test('native CLI help, version and usage use correct channels and status',()=>{
 const help=command(['--help'],workspace);assert.equal(help.status,0);assert.match(help.stdout,/Usage:/);assert.equal(help.stderr,'');
 const version=command(['--version'],workspace);assert.equal(version.status,0);assert.match(version.stdout,/0\.1\.0/);assert.equal(version.stderr,'');
 for(const args of [[],['--unknown'],['main.gleam','app','--bad','root'],['main.gleam','app','--source-root','']])failure(command(args,workspace),2);
 observations.push({kind:'help-version-usage',verified:true});
});
for(const [entry,stdout]of [['fibonacci','55\n'],['control','14\nfourteen\nFalse\nTrue\n-12345\n0\n-2\n'],['collections','6\n3\n6\n6\n'],['custom_types','5\n23\n0\n'],['generics_records','21\n2\n21\n2\n'],['functions','22\n3\n4\n'],['closures','12\n22\n6\n'],['record_updates','3\n7\nTrue\n'],['bit_arrays','5\n9\n-2\n4660\n'],['modules','14\n8\n3\n'],['aliases_guards','7\n5\nTrue\nFalse\n'],['strings_prelude','True\nTrue\nλ😀\n206\n187\n'],['multi_patterns','7\n9\n3\n'],['structural_equality','True\nFalse\nTrue\nTrue\n'],['pattern_aliases','14\n10\n'],['wide_patterns','True\nFalse\n9007199254740991\n-2147483648\n']]){
 test('native CLI compiles and executes example '+entry,()=>{
  const output=join(workspace,'example-'+entry),files={[entry]:readFileSync(join(root,'examples',entry+'.gleam'),'utf8')};
  if(entry==='modules')for(const n of ['module_demo/box','module_demo/numbers'])files[n]=readFileSync(join(root,'examples',n+'.gleam'),'utf8');
  success(command([entry+'.gleam',output,'--source-root',join(root,'examples')],workspace),output,reference(files,entry),stdout);
 });
}
for(const [name,files,pattern] of [
 ['syntax',{main:'pub fn main() -> Nil {@}'},/./],
 ['types',{main:'pub fn main() -> Int {True}'},/Type mismatch/],
 ['missing import',{main:'import missing pub fn main() -> Nil {Nil}'},/Cannot read missing/],
 ['cycle',{main:'import other pub fn main() -> Nil {other.f() Nil}',other:'import main pub fn f() -> Nil {Nil}'},/cycle/],
 ['invalid UTF8',{main:Buffer.from([255])},/UTF-8/],
])test('native CLI rejects '+name+' without output',()=>{
 const dir=fixture(files),output=join(dir,'app'),result=command(['main.gleam',output],dir);failure(result);assert.match(result.stderr,pattern);assert.equal(existsSync(output),false);noTemporary(dir);
 observations.push({kind:'rejection',case:name,status:result.status,diagnostic:result.stderr});
});
for(const source of ['../main.gleam','/tmp/main.gleam','./main.gleam','bad-name.gleam','main.txt'])test('native CLI rejects invalid module path '+source,()=>{
 const dir=fixture(),output=join(dir,'app');failure(command([source,output],dir),2);assert.equal(existsSync(output),false);
});
for(const kind of ['file','directory','symlink','dangling-symlink'])test('native CLI never replaces an existing '+kind+' output',()=>{
 const dir=fixture(),output=join(dir,'app'),target=join(dir,'protected');writeFileSync(target,'protected');
 if(kind==='file')writeFileSync(output,'original',{mode:0o640});
 if(kind==='directory')mkdirSync(output);
 if(kind.includes('symlink'))symlinkSync(kind==='symlink'?target:join(dir,'absent'),output);
 failure(command(['main.gleam',output],dir));noTemporary(dir);assert.equal(readFileSync(target,'utf8'),'protected');
 if(kind==='file'){assert.equal(readFileSync(output,'utf8'),'original');assert.equal(statSync(output).mode&0o777,0o640);}
 if(kind==='directory')assert.equal(statSync(output).isDirectory(),true);
 if(kind.includes('symlink'))assert.equal(readlinkSync(output),kind==='symlink'?target:join(dir,'absent'));
 observations.push({kind:'output-preserved',case:kind});
});
test('native CLI accepts Unicode root/output paths and reads multiple chunks',()=>{
 const parent=fixture({}),dir=join(parent,'λ😀');mkdirSync(dir);
 const source='//'+('a'.repeat(200)+'\n//').repeat(40)+'\npub fn main() -> Nil {echo 7 Nil}';writeFileSync(join(dir,'main.gleam'),source);
 const output=join(parent,'é-output');success(command(['main.gleam',output,'--source-root',dir],parent),output,reference({main:source}),'7\n');noTemporary(parent);
});
for(const kind of ['symlink-file','symlink-directory','directory','fifo','oversized','missing-root','missing-source'])test('native CLI refuses '+kind+' input',()=>{
 const dir=fixture(),output=join(dir,'app');let source='main.gleam',sourceRoot=dir;
 if(kind==='symlink-file'){symlinkSync(join(dir,'main.gleam'),join(dir,'link.gleam'));source='link.gleam';}
 if(kind==='symlink-directory'){symlinkSync(dir,join(dir,'link'));source='link/main.gleam';}
 if(kind==='directory'){mkdirSync(join(dir,'folder.gleam'));source='folder.gleam';}
 if(kind==='fifo'){assert.equal(spawnSync('/usr/bin/mkfifo',[join(dir,'pipe.gleam')]).status,0);source='pipe.gleam';}
 if(kind==='oversized')writeFileSync(join(dir,'main.gleam'),Buffer.alloc(sourceLimit+1,32));
 if(kind==='missing-root')sourceRoot=join(dir,'missing');
 if(kind==='missing-source')source='missing.gleam';
 const result=command([source,output,'--source-root',sourceRoot],dir);failure(result);assert.equal(existsSync(output),false);noTemporary(dir);
 observations.push({kind:'input-refusal',case:kind,status:result.status});
});
test('native CLI validates argument UTF8, length and count',()=>{
 const dir=fixture();failure(command(['x'.repeat(4096)],dir),2);failure(command(Array(257).fill('x'),dir),2);
 const bad=spawnSync('/usr/bin/python3',['-c','import os,sys; os.execv(os.fsencode(sys.argv[1]),[os.fsencode(sys.argv[1]),b"\\xff"])',binary],{encoding:'utf8',timeout:5000});failure(bad,2);assert.match(bad.stderr,/UTF-8/);
 observations.push({kind:'argument-bounds',invalidUTF8:true,oversized:true,tooMany:true});
});
for(const syscall of ['read','write','openat','openat2','fstat','fchmod','fsync','renameat2'])test('native CLI retries injected EINTR at '+syscall,()=>{
 const files={main:'pub fn main() -> Nil {echo 7 Nil}'},dir=fixture(files),output=join(dir,'app'),trace=join(dir,'trace');
 const result=spawnSync('/usr/bin/strace',['-qq','-o',trace,'-e','inject='+syscall+':error=EINTR:when=1',binary,'main.gleam',output],{cwd:dir,env:{...process.env,PATH:''},encoding:'utf8',timeout:15000});
 assert.ifError(result.error);success(result,output,reference(files),'7\n');assert.match(readFileSync(trace,'utf8'),/INJECTED/);noTemporary(dir);
 observations.push({kind:'EINTR-injection',syscall,verified:true});
});
for(const syscall of ['write','fchmod','fsync','renameat2'])test('native CLI cleans temporary output after injected '+syscall+' failure',()=>{
 const dir=fixture(),output=join(dir,'app'),trace=join(dir,'trace');
 const result=spawnSync('/usr/bin/strace',['-qq','-o',trace,'-e','inject='+syscall+':error=EIO:when=1',binary,'main.gleam',output],{cwd:dir,encoding:'utf8',timeout:15000});
 failure(result);assert.equal(existsSync(output),false);noTemporary(dir);assert.match(readFileSync(trace,'utf8'),/INJECTED/);
 observations.push({kind:'failure-injection',syscall,noOutput:true,temporaryClean:true});
});
test('native CLI handles REAL shortened kernel reads and writes without spawning another program',()=>{
 const files={main:'pub fn main() -> Nil {echo 7 Nil}'},dir=fixture(files),output=join(dir,'app'),report=join(dir,'short.json');
 const traced=spawnSync('/usr/bin/python3',[join(root,'test/short-io-trace.py'),report,binary,'main.gleam',output],{cwd:dir,env:{...process.env,PATH:''},encoding:'utf8',timeout:20000});
 assert.equal(traced.status,0,traced.stderr);const observed=JSON.parse(readFileSync(report,'utf8'));
 assert.equal(observed.exitCode,0,observed.stderr);assert.ok(observed.positiveShortReads>0);assert.ok(observed.positiveShortWrites>0);
 assert.equal(observed.syscalls['59'],1);for(const n of ['56','57','58','322','435'])assert.equal(observed.syscalls[n]??0,0);
 success({status:observed.exitCode,stdout:observed.stdout,stderr:observed.stderr},output,reference(files),'7\n');
 observations.push({kind:'actual-short-io',...observed});
});

test('effect runner rejects reordered same-type fields and changed callback signatures',()=>{
 const sources=toList(readdirSync(join(root,'src/native')).filter(n=>n.endsWith('.gleam')).map(n=>new Source('native/'+n.slice(0,-6),new BitArray(readFileSync(join(root,'src/native',n))))));
 const linked=link('native/cli',sources);assert.equal(linked.isOk(),true,linked[0]);const metadata=collect(linked[0]);assert.equal(metadata.isOk(),true,metadata[0]);const context=metadata[0];
 const wrongLabels={...context,constructors:toList(context.constructors.toArray().map(([n,c])=>[n,n==='ReadSource'?{...c,labels:toList(['path','root','state'])}:c]))};
 const labels=runtimePlan(wrongLabels);assert.equal(labels.isOk(),false);assert.match(labels[0],/constructor ABI mismatch/);
 const wrongSignature={...context,functions:toList(context.functions.toArray().map(([n,f])=>[n,n==='with_arguments'?{...f,parameters:toList([])}:f]))};
 const signature=runtimePlan(wrongSignature);assert.equal(signature.isOk(),false);assert.match(signature[0],/function ABI mismatch/);
 observations.push({kind:'ABI-refusal',sameTypeFieldOrder:true,callbackSignature:true});
});
test('native output close errors are not retried and leave no published output',()=>{
 const dir=fixture(),output=join(dir,'app'),trace=join(dir,'trace');
 const result=spawnSync('/usr/bin/strace',['-qq','-o',trace,'-e','trace=close','-e','inject=close:error=EIO:when=3',binary,'main.gleam',output],{cwd:dir,encoding:'utf8',timeout:15000});
 failure(result);assert.equal(existsSync(output),false);noTemporary(dir);
 const text=readFileSync(trace,'utf8');assert.equal((text.match(/close\(/g)??[]).length,3);assert.match(text,/INJECTED/);
 observations.push({kind:'close-error-injection',calls:3,retried:false,temporaryClean:true});
});
test('required syscall unavailability fails explicitly without a fallback or output',()=>{
 for(const syscall of ['openat2','renameat2']){
  const dir=fixture(),output=join(dir,'app');
  const result=spawnSync('/usr/bin/strace',['-qq','-o',join(dir,'trace'),'-e','inject='+syscall+':error=ENOSYS:when=1',binary,'main.gleam',output],{cwd:dir,encoding:'utf8',timeout:15000});
  failure(result);assert.equal(existsSync(output),false);noTemporary(dir);observations.push({kind:'syscall-unavailable',syscall,status:result.status});
 }
});
test('a preexisting sibling temporary file is preserved',()=>{
 const dir=fixture(),output=join(dir,'app');
 const code='import os,sys; p=sys.argv[2]+".gleam-tmp-"+str(os.getpid()); open(p,"xb").write(b"preserved"); os.execv(sys.argv[1],[sys.argv[1],"main.gleam",sys.argv[2]])';
 const result=spawnSync('/usr/bin/python3',['-c',code,binary,output],{cwd:dir,encoding:'utf8',timeout:15000});
 failure(result);assert.equal(existsSync(output),false);const names=readdirSync(dir).filter(n=>n.includes('.gleam-tmp-'));assert.equal(names.length,1);assert.equal(readFileSync(join(dir,names[0]),'utf8'),'preserved');
 observations.push({kind:'preexisting-temporary-preserved',verified:true});
});
test('concurrent publishers produce one complete executable and preserve no-replace behavior',()=>{
 const files={main:'pub fn main() -> Nil {echo 7 Nil}'},dir=fixture(files),output=join(dir,'app');
 const code='import subprocess,sys,json; p=[subprocess.Popen([sys.argv[1],"main.gleam",sys.argv[2]],stdout=subprocess.PIPE,stderr=subprocess.PIPE) for _ in range(2)]; r=[(v.communicate(),v.returncode) for v in p]; print(json.dumps(sorted(v[1] for v in r)))';
 const result=spawnSync('/usr/bin/python3',['-c',code,binary,output],{cwd:dir,encoding:'utf8',timeout:15000});
 assert.equal(result.status,0,result.stderr);assert.deepEqual(JSON.parse(result.stdout),[0,1]);assert.deepEqual(readFileSync(output),reference(files));noTemporary(dir);
 observations.push({kind:'concurrent-publish',statuses:[0,1],byteIdentical:true});
});

test('native CLI compiles its declared whitespace-heavy source limit and rejects the next byte',()=>{
 const program='pub fn main() -> Nil {echo 7 Nil}',source=' '.repeat(sourceLimit-program.length)+program;
 const files={main:source},dir=fixture(files),output=join(dir,'app');success(command(['main.gleam',output],dir),output,reference(files),'7\n');
 writeFileSync(join(dir,'main.gleam'),source+' ');const refused=command(['main.gleam',join(dir,'too-large')],dir);failure(refused);assert.match(refused.stderr,/limit/);assert.equal(existsSync(join(dir,'too-large')),false);
 observations.push({kind:'source-byte-boundary',acceptedBytes:sourceLimit,rejectedBytes:sourceLimit+1});
});
