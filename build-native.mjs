#!/usr/bin/env node
// Stage-0 IO only: read compiler sources, call the owned Gleam CLI builder,
// and write a new native executable. No compiler policy is implemented here.
import {readFileSync,readdirSync,writeFileSync} from 'node:fs';
import {build} from './build/dev/javascript/gleam_native/native/cli_builder.mjs';
import {Source} from './build/dev/javascript/gleam_native/native/project.mjs';
import {BitArray,toList} from './build/dev/javascript/gleam_native/gleam.mjs';
const root=new URL('./',import.meta.url);
const [output,...extra]=process.argv.slice(2);
if(!output||extra.length){console.error('Usage: node build-native.mjs NEW_OUTPUT');process.exit(2);}
try{
 const names=readdirSync(new URL('src/native/',root)).filter(n=>n.endsWith('.gleam')).sort();
 const sources=names.map(name=>new Source('native/'+name.slice(0,-6),new BitArray(readFileSync(new URL('src/native/'+name,root)))));
 const result=build(toList(sources));
 if(!result.isOk())throw new Error(result[0]);
 writeFileSync(output,result[0].rawBuffer,{flag:'wx',mode:0o755});
 console.log('Native CLI: '+output+' ('+result[0].rawBuffer.length+' bytes)');
}catch(error){console.error(error.message);process.exitCode=1;}
