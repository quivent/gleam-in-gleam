import {test} from 'node:test';
import assert from 'node:assert/strict';
import {BitArray,toList} from '../build/dev/javascript/gleam_native/gleam.mjs';
import {Source,link_with_context} from '../build/dev/javascript/gleam_native/native/project.mjs';
import {module_with_context,ParameterNode,VariableNode,ClosureNode} from '../build/dev/javascript/gleam_native/native/check.mjs';
import {plan,ReadParameter,ReadLocal} from '../build/dev/javascript/gleam_native/native/registers.mjs';
const unwrap=r=>{assert.equal(r.isOk(),true,r[0]);return r[0]};
function typed(source){const [ast,ctx]=unwrap(link_with_context('main',toList([new Source('main',new BitArray(Buffer.from(source)))])));return unwrap(module_with_context(ast,ctx)).toArray()}
function all(value,cls,out=[]){if(!value||typeof value!=='object')return out;if(value instanceof cls)out.push(value);if(value instanceof BitArray)return out;if(typeof value.toArray==='function')for(const v of value.toArray())all(v,cls,out);else for(const v of Object.values(value))all(v,cls,out);return out}
test('four incoming parameters retain direct locations and no variable-name reads',()=>{
 const f=typed('fn f(a:Int,b:Int,c:Int,d:Int)->Int {a+10*b+100*c+1000*d} pub fn main()->Nil {echo f(1,2,3,4) Nil}').find(f=>f.name==='f');
 assert.deepEqual(all(f.body,ParameterNode).map(x=>x.offset),[40,32,24,16]);assert.equal(all(f.body,VariableNode).length,0);
 const value=f.body.toArray()[0][0],code=unwrap(plan(value)).toArray();assert.deepEqual(code.filter(x=>x instanceof ReadParameter).map(x=>x.offset),[40,32,24,16]);assert.equal(code.filter(x=>x instanceof ReadLocal).length,0);
});
test('local shadowing changes the binding without mutating earlier parameter reads',()=>{
 const f=typed('fn f(x:Int)->Int {let old=x let x=x+1 old+x} pub fn main()->Nil {echo f(4) Nil}').find(f=>f.name==='f');
 assert.deepEqual(all(f.body,ParameterNode).map(x=>x.offset),[16,16]);assert.deepEqual(all(f.body,VariableNode).map(x=>x[0]),['old','x']);
});
test('nested closures rebind captures to their own frame and retain outer capture locations',()=>{
 const f=typed('fn f(x:Int)->fn(Int)->fn(Int)->Int {fn(y:Int){fn(z:Int){x+y+z}}} pub fn main()->Nil {echo f(1)(2)(3) Nil}').find(f=>f.name==='f');
 const [outer,inner]=all(f.body,ClosureNode);assert.deepEqual(outer[2].toArray(),[['x',16]]);assert.deepEqual(inner[2].toArray(),[['x',0],['y',0]]);
 assert.deepEqual(all(inner[1],ParameterNode).map(x=>x.offset),[16]);assert.deepEqual(all(inner[1],VariableNode).map(x=>x[0]),['x','y','z']);
});
