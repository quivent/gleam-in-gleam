#!/usr/bin/env python3
"""Development-only ptrace harness: shorten REAL read/write syscall requests.
The compiled program does not load this harness or libc. No fake read payloads
or fake successful writes: the kernel performs every shortened operation.
"""
import ctypes
import json
import os
import signal
import sys
import tempfile
from pathlib import Path

fields = 'r15 r14 r13 r12 rbp rbx r11 r10 r9 r8 rax rcx rdx rsi rdi orig_rax rip cs eflags rsp ss fs_base gs_base ds es fs gs'.split()
class Registers(ctypes.Structure):
    _fields_ = [(name, ctypes.c_ulonglong) for name in fields]
libc = ctypes.CDLL(None, use_errno=True)
libc.ptrace.restype = ctypes.c_long
libc.ptrace.argtypes = [ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p, ctypes.c_void_p]
def ptrace(request, pid, address=0, data=0):
    result = libc.ptrace(request, pid, ctypes.c_void_p(address), ctypes.c_void_p(data))
    if result == -1:
        raise OSError(ctypes.get_errno(), os.strerror(ctypes.get_errno()))
    return result

if len(sys.argv) < 3:
    raise SystemExit('Usage: short-io-trace.py REPORT COMMAND [ARGS...]')
report_path, command = Path(sys.argv[1]), sys.argv[2:]
report = dict(schema='gleam-in-gleam.short-io/1', limit=7, syscalls={}, shortenedReadRequests=0,
              shortenedWriteRequests=0, positiveShortReads=0, positiveShortWrites=0)
pid = None
with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
    try:
        pid = os.fork()
        if pid == 0:
            os.dup2(stdout.fileno(), 1)
            os.dup2(stderr.fileno(), 2)
            ptrace(0, 0)
            os.kill(os.getpid(), signal.SIGSTOP)
            os.execv(command[0], command)
        os.waitpid(pid, 0)
        ptrace(0x4200, pid, 0, 0x1 | 0x10 | 0x100000)  # TRACESYSGOOD, TRACEEXEC, EXITKILL
        active = None
        while True:
            ptrace(24, pid)  # PTRACE_SYSCALL
            _, status = os.waitpid(pid, 0)
            if os.WIFEXITED(status):
                report['exitCode'] = os.WEXITSTATUS(status)
                break
            if os.WIFSIGNALED(status):
                report['signal'] = os.WTERMSIG(status)
                break
            if os.WSTOPSIG(status) != signal.SIGTRAP | 0x80:
                if os.WSTOPSIG(status) != signal.SIGTRAP:
                    raise RuntimeError('Unexpected traced signal: ' + str(os.WSTOPSIG(status)))
                continue
            info = ctypes.create_string_buffer(128)
            ptrace(0x420E, pid, ctypes.sizeof(info), ctypes.addressof(info))
            operation = info.raw[0]
            registers = Registers()
            ptrace(12, pid, 0, ctypes.addressof(registers))
            if operation == 1:
                number = registers.orig_rax
                key = str(number)
                report['syscalls'][key] = report['syscalls'].get(key, 0) + 1
                active = None
                if number in (0, 1) and registers.rdi > 2 and registers.rdx > 7:
                    active = (number, registers.rdx)
                    registers.rdx = 7
                    ptrace(13, pid, 0, ctypes.addressof(registers))
                    key = 'shortenedReadRequests' if number == 0 else 'shortenedWriteRequests'
                    report[key] += 1
            elif operation == 2 and active:
                number, original_size = active
                result = ctypes.c_longlong(registers.rax).value
                if 0 < result < original_size:
                    key = 'positiveShortReads' if number == 0 else 'positiveShortWrites'
                    report[key] += 1
                active = None
        pid = None
        stdout.seek(0)
        stderr.seek(0)
        report['stdout'] = stdout.read().decode('utf8', errors='replace')
        report['stderr'] = stderr.read().decode('utf8', errors='replace')
        report_path.write_text(json.dumps(report, indent=2) + '\n')
    finally:
        if pid:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
print(json.dumps(report))
