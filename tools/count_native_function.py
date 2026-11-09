#!/usr/bin/env python3
"""Dev-only ptrace instruction counts; not timing or hardware-cycle samples."""
import argparse
from pathlib import Path
import ctypes,datetime,hashlib,json,os,resource,signal,struct,tempfile
p=argparse.ArgumentParser(description='Count executed instructions through a bounded owned native function invocation')
p.add_argument('probes');p.add_argument('receipt');args=p.parse_args()
libc=ctypes.CDLL(None,use_errno=True);libc.ptrace.restype=ctypes.c_long;libc.ptrace.argtypes=[ctypes.c_ulong,ctypes.c_ulong,ctypes.c_void_p,ctypes.c_void_p]
fields='r15 r14 r13 r12 rbp rbx r11 r10 r9 r8 rax rcx rdx rsi rdi orig_rax rip cs eflags rsp ss fs_base gs_base ds es fs gs'.split()
class Regs(ctypes.Structure):_fields_=[(n,ctypes.c_ulonglong) for n in fields]
def ptrace(req,pid,addr=0,data=0):
 ctypes.set_errno(0);r=libc.ptrace(req,pid,ctypes.c_void_p(addr),ctypes.c_void_p(data))
 if r==-1 and ctypes.get_errno():raise OSError(ctypes.get_errno(),os.strerror(ctypes.get_errno()))
 return r
def regs(pid):
 r=Regs();ptrace(12,pid,0,ctypes.addressof(r));return r
report={'harnessSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'probesSHA256':hashlib.sha256(Path(args.probes).read_bytes()).hexdigest(),'schema':'gta.native-function-instructions/1','observedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'countScope':'actual x86-64 single-step entries through return, inclusive of any nested runtime calls; caller/request/printing excluded','timingIsBenchmark':False,'cases':[],'complete':False}
try:
 for case in json.loads(Path(args.probes).read_text())['cases']:
  assert hashlib.sha256(Path(case['binary']).read_bytes()).hexdigest()==case['binarySHA256'], 'Binary changed after probe build'
  pid=None
  with tempfile.TemporaryFile() as out,tempfile.TemporaryFile() as err:
   try:
    pid=os.fork()
    if pid==0:
     resource.setrlimit(resource.RLIMIT_CORE,(0,0));resource.setrlimit(resource.RLIMIT_CPU,(30,30));os.dup2(out.fileno(),1);os.dup2(err.fileno(),2);ptrace(0,0);os.kill(os.getpid(),signal.SIGSTOP);os.execve(case['binary'],[case['binary']],{'PATH':''})
    os.waitpid(pid,0);ptrace(7,pid);_,s=os.waitpid(pid,0);assert os.WIFSTOPPED(s) and os.WSTOPSIG(s)==signal.SIGTRAP,s
    address=case['targetAddress'];original=ptrace(1,pid,address)&((1<<64)-1);ptrace(4,pid,address,(original&~255)|0xcc);counts=[]
    while True:
     ptrace(7,pid);_,s=os.waitpid(pid,0)
     if os.WIFEXITED(s):assert os.WEXITSTATUS(s)==0;break
     assert os.WIFSTOPPED(s) and os.WSTOPSIG(s)==signal.SIGTRAP,s
     r=regs(pid);assert r.rip==address+1,(hex(r.rip),hex(address));ptrace(4,pid,address,original);r.rip=address;ptrace(13,pid,0,ctypes.addressof(r))
     with open(f'/proc/{pid}/mem','rb',buffering=0) as mem:returned=struct.unpack('<Q',os.pread(mem.fileno(),8,r.rsp))[0]
     count=0
     while regs(pid).rip!=returned:
      ptrace(9,pid);_,s=os.waitpid(pid,0);assert os.WIFSTOPPED(s) and os.WSTOPSIG(s)==signal.SIGTRAP,s
      count+=1;assert count<100000,'step cap'
     counts.append(count);ptrace(4,pid,address,(original&~255)|0xcc)
    pid=None;out.seek(0);err.seek(0);stdout=out.read().decode();stderr=err.read().decode();assert stdout==case['stdout'] and not stderr
    assert len(counts)==len(case['expected']),(case['name'],counts)
    report['cases'].append({'name':case['name'],'function':case['fn'],'instructions':counts,'sourceModuleSHA256':case['targetSourceSHA256'],'binarySHA256':case['binarySHA256'],'targetAddress':case['targetAddress'],'stdout':stdout});print(case['name'],counts,flush=True)
   finally:
    if pid:os.kill(pid,signal.SIGKILL);os.waitpid(pid,0)
 report['complete']=True
except BaseException as error:report['failure']=repr(error);raise
finally:Path(args.receipt).write_text(json.dumps(report,indent=2)+'\n')
