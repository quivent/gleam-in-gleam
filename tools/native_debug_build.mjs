#!/usr/bin/env node
// Development-only frozen-source build and exact symbol map. Compiler stages
// and instruction selection remain in Gleam. An explicit emitted runtime bound
// is selected through the owned diagnostic build API; target sources stay frozen.
import {execFileSync} from 'node:child_process';
import {readFileSync,writeFileSync,existsSync,mkdirSync,readdirSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {link,Source} from '../build/dev/javascript/gleam_native/native/project.mjs';
import {module as check} from '../build/dev/javascript/gleam_native/native/check.mjs';
import {collect} from '../build/dev/javascript/gleam_native/native/definitions.mjs';
import {plan_cli_with_limit} from '../build/dev/javascript/gleam_native/native/x64.mjs';
import {assemble,symbols} from '../build/dev/javascript/gleam_native/native/assembler.mjs';
import {executable} from '../build/dev/javascript/gleam_native/native/elf.mjs';
import {BitArray,toList} from '../build/dev/javascript/gleam_native/gleam.mjs';
const root=fileURLToPath(new URL('../',import.meta.url));
const [revision,capString,output,arenaString]=process.argv.slice(2),cap=Number(capString),arena=Number(arenaString||67108864);
if(!revision||!output||!Number.isSafeInteger(cap)||cap<16384||cap>1048576||!Number.isSafeInteger(arena)||arena<67108864||arena>1073741824||arena%4096)throw new Error('Usage: native_debug_build.mjs REVISION SOURCE_CAP_BYTES NEW_DIRECTORY');
const directory=resolve(output);if(existsSync(directory))throw new Error('Output directory must be new');
const sha=b=>createHash('sha256').update(b).digest('hex');
const git=(...args)=>execFileSync('git',args,{cwd:root,maxBuffer:4194304});
const working=revision==='WORKING';
const commit=git('rev-parse','--verify',(working?'HEAD':revision)+'^{commit}').toString().trim();
const paths=working?readdirSync(join(root,'src/native')).filter(n=>n.endsWith('.gleam')).sort().map(n=>'src/native/'+n):git('ls-tree','-r','--name-only',commit,'src/native').toString().trim().split('\n').filter(n=>n.endsWith('.gleam'));
const original={};
const sources=paths.map(path=>{const bytes=working?readFileSync(join(root,path)):git('show',commit+':'+path);original[path]=sha(bytes);return new Source(path.slice(4,-6),new BitArray(bytes));});
const unwrap=r=>{if(!r.isOk())throw new Error(r[0]);return r[0];};
const ast=unwrap(link('native/cli',toList(sources))),typed=unwrap(check(ast)),globals=unwrap(collect(ast));
const parts=unwrap(plan_cli_with_limit(typed,globals,cap,arena)),code=unwrap(assemble(parts)),image=Buffer.from(executable(code).rawBuffer);
const table=unwrap(symbols(parts)).toArray();
const fileOffset=176,base=Number(image.readBigUInt64LE(24));
const functions=table.filter(([name])=>name.startsWith('fn:')&&!name.startsWith('fn:end:')&&!name.startsWith('fn:loop:')).map(([label,offset])=>{
 const name=label.slice(3),end=table.find(([label])=>label==='fn:end:'+name);
 if(!end)throw new Error('Missing function end: '+name);
 return {name,start:base+offset,end:base+end[1],frameBytes:image.readInt32LE(fileOffset+offset+7)};
}).sort((a,b)=>a.start-b.start);
mkdirSync(directory,{recursive:true});writeFileSync(join(directory,'compiler'),image,{flag:'wx',mode:0o755});
for(const source of sources){const path=join(directory,'source-snapshot','src',source.name+'.gleam');mkdirSync(resolve(path,'..'),{recursive:true});writeFileSync(path,source.content.rawBuffer,{flag:'wx'});}
const emitterPaths=['src/native/assembler.gleam','src/native/x64.gleam','src/native/cli_runtime.gleam'];
const receipt={schema:'gleam-in-gleam.native-debug-build/1',sourceRevision:commit,sourceKind:working?"working-tree-snapshot":"git-commit",diagnostic:true,sourceCapBytes:cap,arenaCapacityBytes:arena,sourceSHA256:original,targetSourceUnmodified:true,sourceSnapshot:"source-snapshot/src",emitterSHA256:Object.fromEntries(emitterPaths.map(p=>[p,sha(readFileSync(join(root,p)))])),artifact:{bytes:image.length,sha256:sha(image)},functions,symbols:table.map(([name,offset])=>({name,address:base+offset})),productionLimitUnchanged:true};
writeFileSync(join(directory,'symbols.json'),JSON.stringify(receipt,null,2)+'\n');console.log(JSON.stringify({directory,bytes:image.length,sha256:sha(image),functions:functions.length,cap},null,2));
