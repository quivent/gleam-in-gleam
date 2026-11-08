import {test} from 'node:test';
import assert from 'node:assert/strict';
import {writeFileSync,mkdtempSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
import * as registers from '../build/dev/javascript/gleam_native/native/registers.mjs';
import {BitArray,toList} from '../build/dev/javascript/gleam_native/gleam.mjs';
import {compile} from '../build/dev/javascript/gleam_native/native/compiler.mjs';
import {link,Source} from '../build/dev/javascript/gleam_native/native/project.mjs';
import {module as check} from '../build/dev/javascript/gleam_native/native/check.mjs';
import {collect} from '../build/dev/javascript/gleam_native/native/definitions.mjs';
import {plan_with} from '../build/dev/javascript/gleam_native/native/x64.mjs';
import {assemble,symbols} from '../build/dev/javascript/gleam_native/native/assembler.mjs';
const unwrap=r=>{assert.equal(r.isOk(),true,r[0]);return r[0];};
function body(source,name){
 const ast=unwrap(link('main',toList([new Source('main',new BitArray(Buffer.from(source)))]))),typed=unwrap(check(ast)),parts=unwrap(plan_with(typed,unwrap(collect(ast)))),table=new Map(unwrap(symbols(parts)).toArray()),bytes=Buffer.from(unwrap(assemble(parts)).rawBuffer);
 const dir=mkdtempSync(join(tmpdir(),'gleam-register-asm-'));
 try{const path=join(dir,'code');writeFileSync(path,bytes);const r=spawnSync('objdump',['-D','--no-show-raw-insn','-b','binary','-m','i386:x86-64',path],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);
 return r.stdout.split('\n').filter(line=>{const m=line.match(/^\s*([a-f0-9]+):/);return m&&parseInt(m[1],16)>=table.get('fn:'+name)&&parseInt(m[1],16)<table.get('fn:end:'+name);}).join('\n');
 }finally{rmSync(dir,{recursive:true,force:true});}
}
test('leaf integer operands allocate RAX and RCX without a temporary stack spill',()=>{
 const asm=body('fn f(a:Int,b:Int)->Int {a-b} pub fn main()->Nil {echo f(9,4) Nil}','f');
 assert.match(asm,/mov\s+0x18\(%rbp\),%rax/);assert.match(asm,/mov\s+0x10\(%rbp\),%rcx/);
 assert.doesNotMatch(asm,/push\s+%rax|pop\s+%rcx/);assert.match(asm,/sub\s+%rcx,%rax/);
});
test('a root call result stays in RAX while the leaf RHS uses RCX',()=>{
 const asm=body('fn g()->Int {7} fn f(a:Int)->Int {g()+a} pub fn main()->Nil {echo f(4) Nil}','f');
 assert.match(asm,/call[\s\S]*mov\s+0x10\(%rbp\),%rcx[\s\S]*add\s+%rcx,%rax/);assert.doesNotMatch(asm,/push\s+%rax|pop\s+%rcx/);
});
test('a right-hand call restores its saved outer operand after copying the return value',()=>{
 const asm=body('fn g()->Int {case 3 {x->x*7}} fn f(a:Int)->Int {a+g()} pub fn main()->Nil {echo f(4) Nil}','f');
 assert.match(asm,/push\s+%rax[\s\S]*call[\s\S]*mov\s+%rax,%rcx[\s\S]*pop\s+%rax[\s\S]*add\s+%rcx,%rax/);
});
test('register retention preserves checked overflow before any echo',()=>{
 const source='pub fn main()->Nil {let max=9007199254740991*1024+1023 echo max+1 Nil}',dir=mkdtempSync(join(tmpdir(),'gleam-register-overflow-'));
 try{const path=join(dir,'app');writeFileSync(path,unwrap(compile(new BitArray(Buffer.from(source)))).rawBuffer,{mode:0o755});const r=spawnSync(path,[],{encoding:'utf8'});assert.equal(r.status,70);assert.equal(r.signal,null);assert.equal(r.stdout,'');}
 finally{rmSync(dir,{recursive:true,force:true});}
});

test('single-case siblings reserve their maximum local frame, not their sum',()=>{
 const asm=body('fn f(n:Int)->Int {case n {0->{let a=n+1 let b=a+2 b} 1->{let a=n+2 let b=a+3 b} _->{let a=n+4 let b=a+5 b}}} pub fn main()->Nil {echo f(0) Nil}','f');
 assert.match(asm,/sub\s+\$0x20,%rsp/);
});
test('multi-case siblings share local space without overwriting saved subjects',()=>{
 const asm=body('fn f(a:Int,b:Int)->Int {case a,b {0,y->{let x=y+1 let z=x+2 z} x,0->{let y=x+2 let z=y+3 z} x,y->{let z=x*y let v=z+3 v}}} pub fn main()->Nil {echo f(0,4) Nil}','f');
 assert.match(asm,/sub\s+\$0x30,%rsp/);
});

function integerPlan(expression){
 const source='fn f(a:Int,b:Int,c:Int,d:Int,e:Int)->Int {'+expression+'} pub fn main()->Nil {echo f(1,2,3,4,5) Nil}';
 const ast=unwrap(link('main',toList([new Source('main',new BitArray(Buffer.from(source)))]))),typed=unwrap(check(ast));
 return registers.plan(typed.toArray().find(f=>f.name==='f').body.toArray()[0][0]);
}
test('three registers retain a nested arithmetic region without a spill',()=>{
 const code=unwrap(integerPlan('a+b*c')).toArray();assert.equal(code.some(i=>i instanceof registers.Push||i instanceof registers.Pop),false);
 const asm=body('fn f(a:Int,b:Int,c:Int)->Int {a+b*c} pub fn main()->Nil {echo f(1,2,3) Nil}','f');
 assert.match(asm,/mov\s+0x10\(%rbp\),%rdx/);assert.doesNotMatch(asm,/push\s+%(rax|rcx|rdx)|pop\s+%(rax|rcx|rdx|rdi)/);
});
test('four-value pressure spills and restores the innermost left value',()=>{
 const code=unwrap(integerPlan('a+{b+{c+{d+e}}}')).toArray();assert.equal(code.filter(i=>i instanceof registers.Push).length,2);assert.equal(code.filter(i=>i instanceof registers.Pop).length,2);
 const asm=body('fn f(a:Int,b:Int,c:Int,d:Int,e:Int)->Int {a+{b+{c+{d+e}}}} pub fn main()->Nil {echo f(1,2,3,4,5) Nil}','f');assert.match(asm,/push\s+%rdx/);assert.match(asm,/pop\s+%rdi/);
});

test('backward liveness removes dead materializations but retains overflow checks',()=>{
 const r=new registers.Rax(),c=new registers.Rcx(),flags=new registers.Flags();
 const input=toList([new registers.Constant(c,99),new registers.Constant(r,7),new registers.Copy(r,r)]),output=registers.eliminate_dead_moves(input).toArray();assert.equal(output.length,1);assert.equal(output[0].value,7);
 const operation=new registers.Calculate(new registers.Add(),c,r),live=registers.live_before(operation,toList([r,flags])).toArray().map(r=>r.constructor.name).sort();assert.deepEqual(live,['Rax','Rcx']);
 const checked=toList([new registers.Constant(r,1),new registers.Constant(c,2),operation,new registers.OverflowGuard(),new registers.Constant(r,3)]),kept=registers.eliminate_dead_moves(checked).toArray();assert.ok(kept.some(i=>i instanceof registers.Calculate));assert.ok(kept.some(i=>i instanceof registers.OverflowGuard));
});
test('non-call effects, branches and division remain explicit allocation boundaries',()=>{
 assert.equal(integerPlan('a+f(1,2,3,4,5)').isOk(),true);
 assert.equal(integerPlan('a+{echo b b}').isOk(),false);
 assert.equal(integerPlan('a+case b {0->c _->d}').isOk(),false);
 assert.equal(integerPlan('a+b/c').isOk(),false);
});

test('allocated regions preserve overflow even when a later multiply yields zero',()=>{
 const source='pub fn main()->Nil {echo {9007199254740991*1024+1023+1}*0 Nil}',dir=mkdtempSync(join(tmpdir(),'gleam-region-overflow-'));
 try{const path=join(dir,'app');writeFileSync(path,unwrap(compile(new BitArray(Buffer.from(source)))).rawBuffer,{mode:0o755});const result=spawnSync(path,[],{encoding:'utf8'});assert.equal(result.status,70);assert.equal(result.stdout,'');assert.equal(result.signal,null);}
 finally{rmSync(dir,{recursive:true,force:true});}
 const asm=body('fn f(a:Int,b:Int,c:Int)->Int {{a+b}*c} pub fn main()->Nil {echo f(1,2,3) Nil}','f');assert.match(asm,/add\s+%rcx,%rax[\s\S]*jo[\s\S]*imul/);
});

test('named calls declare every allocatable register and flags clobbered',()=>{
 const call=new registers.NamedCall('g',2),names=values=>values.toArray().map(v=>v.constructor.name).sort();
 assert.deepEqual(names(registers.clobbers(call)),['Flags','Rax','Rcx','Rdi','Rdx']);assert.deepEqual(names(registers.definitions(call)),names(registers.clobbers(call)));assert.deepEqual(registers.uses(call).toArray(),[]);
 assert.deepEqual(registers.live_before(call,toList([new registers.Rax(),new registers.Rcx()])).toArray(),[]);
 const kept=registers.eliminate_dead_moves(toList([new registers.Constant(new registers.Rcx(),99),call,new registers.Constant(new registers.Rax(),7)])).toArray();assert.ok(kept.some(i=>i instanceof registers.NamedCall));assert.equal(kept.some(i=>i instanceof registers.Constant&&i.value===99),false);
});
test('nested calls copy their result before restoring two live pool values',()=>{
 const code=unwrap(integerPlan('a+{b*f(1,2,3,4,5)}')).toArray(),index=code.findIndex(i=>i instanceof registers.NamedCall);assert.equal(code[index].argument_count,5);
 assert.ok(code[index+1] instanceof registers.Copy);assert.ok(code[index+1].target instanceof registers.Rdx);assert.ok(code[index+2] instanceof registers.Pop);assert.ok(code[index+2][0] instanceof registers.Rcx);assert.ok(code[index+3][0] instanceof registers.Rax);
});
test('overflow in an earlier call argument stops later argument effects',()=>{
 const source='fn mark(n:Int)->Int {echo n n} fn g(a:Int,b:Int)->Int {a+b} pub fn main()->Nil {let max=9007199254740991*1024+1023 echo g(max+1,mark(9)) Nil}',dir=mkdtempSync(join(tmpdir(),'gleam-call-argument-trap-'));
 try{const path=join(dir,'app');writeFileSync(path,unwrap(compile(new BitArray(Buffer.from(source)))).rawBuffer,{mode:0o755});const result=spawnSync(path,[],{encoding:'utf8'});assert.equal(result.status,70);assert.equal(result.signal,null);assert.equal(result.stdout,'');}finally{rmSync(dir,{recursive:true,force:true});}
});
