#!/usr/bin/env node
// Development-only instrumentation of the real expression emitter.
// Both snapshots retain their actual compiler functions; append only a driver
// for resolve's second incoming parameter and verify the identical load bytes.
import {readFileSync,readdirSync,writeFileSync,mkdirSync} from 'node:fs';
import {resolve} from 'node:path';import {spawnSync} from 'node:child_process';import {createHash} from 'node:crypto';
import {link_with_context,Source} from '../build/dev/javascript/gleam_native/native/project.mjs';
import {module_with_context} from '../build/dev/javascript/gleam_native/native/check.mjs';
import {plan_with} from '../build/dev/javascript/gleam_native/native/x64.mjs';
import {assemble,symbols} from '../build/dev/javascript/gleam_native/native/assembler.mjs';
import {executable} from '../build/dev/javascript/gleam_native/native/elf.mjs';
import {BitArray,toList} from '../build/dev/javascript/gleam_native/gleam.mjs';
const [oldSource,oldCompiler,newCompiler,destination]=process.argv.slice(2);
if(!destination)throw Error('Usage: build_parameter_read_probes.mjs OLD_SRC OLD_COMPILER NEW_COMPILER NEW_DIRECTORY');
const directory=resolve(destination),sha=b=>createHash('sha256').update(b).digest('hex'),unwrap=r=>{if(!r.isOk())throw Error(r[0]);return r[0]};mkdirSync(directory);
const cases=[];
for(const name of ['before','after']){
 const sourceRoot=resolve(name==='before'?oldSource:'src'),folder=directory+'/'+name;mkdirSync(folder);mkdirSync(folder+'/src/native',{recursive:true});
 const env=name==='before'?'parameter_offsets([#("chunks",a.Unit),#("labels",a.Unit),#("forward",a.Unit),#("failure",a.Unit)],4,0)':'[]';
 const node=name==='before'?'t.VariableNode("labels")':'t.ParameterNode(32)';
 const driver=`\npub fn main()->Nil {\nlet state=State(0,0,${env},[],False,[],[],d.Context([],[],[],[],""),[])\nlet value=t.Typed(${node},a.NamedType("Index@native/assembler"),0)\necho case expression(value,state) {Ok(#([asm.Bytes(bits)],_))->bits==<<72,139,133,32,0,0,0>> _->False}\nNil}\n`;
 const inputHashes={},sources=readdirSync(sourceRoot+'/native').filter(n=>n.endsWith('.gleam')).sort().map(n=>{
  const raw=readFileSync(sourceRoot+'/native/'+n);inputHashes['native/'+n]=sha(raw);const text=Buffer.concat([raw,Buffer.from(n==='x64.gleam'?driver:'')]);writeFileSync(folder+'/src/native/'+n,text);return new Source('native/'+n.slice(0,-6),new BitArray(text));
 });
 const [ast,ctx]=unwrap(link_with_context('native/x64',toList(sources))),typed=unwrap(module_with_context(ast,ctx)),parts=unwrap(plan_with(typed,ctx)),table=new Map(unwrap(symbols(parts)).toArray()),image=Buffer.from(executable(unwrap(assemble(parts))).rawBuffer),entry=Number(image.readBigUInt64LE(24));
 const binary=folder+'/probe';writeFileSync(binary,image,{mode:0o755});
 const compiler=resolve(name==='before'?oldCompiler:newCompiler),compiled=spawnSync(compiler,['native/x64.gleam',folder+'/native-probe','--source-root',folder+'/src'],{encoding:'utf8'});if(compiled.status!==0||!image.equals(readFileSync(folder+'/native-probe')))throw Error(compiled.stderr||'Bootstrap/native mismatch');
 const ran=spawnSync(binary,[],{encoding:'utf8'});if(ran.status||ran.stdout!=='True\n'||ran.stderr)throw Error(ran.stdout+ran.stderr);
 cases.push({name,fn:'expression',binary,binarySHA256:sha(image),targetAddress:entry+table.get('fn:expression'),targetEnd:entry+table.get('fn:end:expression'),expected:[true],stdout:'True\n',sourceModuleSHA256:inputHashes['native/x64.gleam'],targetSourceSHA256:inputHashes['native/x64.gleam'],inputSourceSHA256:inputHashes,driver,compilerSHA256:sha(readFileSync(compiler)),bootstrapNativeByteIdentical:true});
}
writeFileSync(directory+'/probes.json',JSON.stringify({schema:'gta.static-parameter-read-probes/1',scope:'one complete real compiler emitter invocation; setup/driver excluded from instruction count',cases},null,2)+'\n');console.log('Before/after real emitter probes produce identical rbp+32 load bytes');
