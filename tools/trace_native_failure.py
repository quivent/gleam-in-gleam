#!/usr/bin/env python3
"""Development-only native fault/frame/arena trace of an owned compiler process."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import resource
import signal
import struct
import sys
import tempfile

if len(sys.argv) < 5:
    raise SystemExit('Usage: trace_native_failure.py SYMBOLS_JSON REPORT COMMAND [ARGS...]')
symbols_path, report_path = map(Path, sys.argv[1:3])
command = sys.argv[3:]
symbols = json.loads(symbols_path.read_text())
assert hashlib.sha256(Path(command[0]).read_bytes()).hexdigest() == symbols['artifact']['sha256']
fields = 'r15 r14 r13 r12 rbp rbx r11 r10 r9 r8 rax rcx rdx rsi rdi orig_rax rip cs eflags rsp ss fs_base gs_base ds es fs gs'.split()
class Registers(ctypes.Structure):
    _fields_ = [(name, ctypes.c_ulonglong) for name in fields]
libc = ctypes.CDLL(None, use_errno=True)
libc.ptrace.restype = ctypes.c_long
libc.ptrace.argtypes = [ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p, ctypes.c_void_p]
def ptrace(request, pid, address=0, data=0):
    value = libc.ptrace(request, pid, ctypes.c_void_p(address), ctypes.c_void_p(data))
    if value == -1:
        raise OSError(ctypes.get_errno(), os.strerror(ctypes.get_errno()))
    return value

def snapshot(pid):
    registers = Registers()
    ptrace(12, pid, 0, ctypes.addressof(registers))
    maps = Path(f'/proc/{pid}/maps').read_text()
    stack_line = next((line for line in maps.splitlines() if line.endswith('[stack]')), None)
    result = dict(registers={name:hex(getattr(registers,name)) for name in fields},stackMapping=stack_line,frames=[])
    capacity=symbols.get('arenaCapacityBytes',67108864)
    if registers.r14 >= capacity and registers.r15:
        used = registers.r15 - (registers.r14 - capacity)
        if 0 <= used <= capacity*2:
            result['arenaAllocatedOrAttemptedBytes'] = used
            result['arenaCapacityBytes'] = capacity
    if not stack_line:
        return result
    low,high = [int(s,16) for s in stack_line.split()[0].split('-')]
    result['mappedStackBytes'] = high-low
    result['stackUsedAtSnapshotBytes'] = high-registers.rsp
    pointer, pc = registers.rbp, registers.rip
    with open(f'/proc/{pid}/mem','rb',buffering=0) as memory:
        for index in range(256):
            owner = next((f for f in symbols['functions'] if f['start'] <= pc < f['end']), None)
            result['frames'].append(dict(index=index,pc=hex(pc),rbp=hex(pointer),function=owner['name'] if owner else None,frameBytes=owner['frameBytes'] if owner else None))
            if not low <= pointer <= high-16:
                break
            previous,returned = struct.unpack('<QQ',os.pread(memory.fileno(),16,pointer))
            if previous <= pointer or previous >= high:
                break
            pointer,pc = previous,returned-1
    counts={}
    for frame in result['frames']:
        name=frame['function'] or 'unmapped';counts[name]=counts.get(name,0)+1
    result['sampledFrameCounts']=counts
    return result

report=dict(schema='gleam-in-gleam.native-fault-trace/1',diagnostic=True,sourceRevision=symbols['sourceRevision'],sourceCapBytes=symbols['sourceCapBytes'],artifact=symbols['artifact'],stackLimitBytes=8388608,events=[])
pid=None
with tempfile.TemporaryFile() as stdout,tempfile.TemporaryFile() as stderr:
    try:
        pid=os.fork()
        if pid==0:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            resource.setrlimit(resource.RLIMIT_CPU,(15,15))
            resource.setrlimit(resource.RLIMIT_STACK,(8388608,8388608))
            os.dup2(stdout.fileno(),1);os.dup2(stderr.fileno(),2)
            ptrace(0,0);os.kill(os.getpid(),signal.SIGSTOP);os.execv(command[0],command)
        os.waitpid(pid,0)
        ptrace(0x4200,pid,0,0x10|0x40|0x100000)  # TRACEEXEC, TRACEEXIT, EXITKILL
        deliver=0
        while True:
            ptrace(7,pid,0,deliver);deliver=0
            _,status,usage=os.wait4(pid,0)
            if os.WIFEXITED(status) or os.WIFSIGNALED(status):
                report['exitCode']=os.WEXITSTATUS(status) if os.WIFEXITED(status) else None
                report['signal']=os.WTERMSIG(status) if os.WIFSIGNALED(status) else None
                report['peakRSSKiB']=usage.ru_maxrss;report['userCPUSeconds']=usage.ru_utime;report['systemCPUSeconds']=usage.ru_stime
                break
            event=status>>16;stopped=os.WSTOPSIG(status)
            if event==6:
                report['exitSnapshot']=snapshot(pid)
            elif stopped not in (signal.SIGTRAP,signal.SIGSTOP):
                report['events'].append(dict(signal=stopped,snapshot=snapshot(pid)))
                deliver=stopped
        pid=None;stdout.seek(0);stderr.seek(0)
        report['stdout']=stdout.read().decode('utf8',errors='replace');report['stderr']=stderr.read().decode('utf8',errors='replace')
        report_path.parent.mkdir(parents=True,exist_ok=True);report_path.write_text(json.dumps(report,indent=2)+'\n')
    finally:
        if pid:
            os.kill(pid,signal.SIGKILL);os.waitpid(pid,0)
print(json.dumps({k:v for k,v in report.items() if k not in ['exitSnapshot','events']},indent=2))
