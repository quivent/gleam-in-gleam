#!/usr/bin/env python3
"""Dev-only phase allocation cursor trace of a newly owned native compiler.

Software breakpoints inspect R15; no compiler source/runtime instrumentation or
installed process is modified. Inclusive/exclusive amounts are allocation volume,
not live-object size. Kernel ptrace/ctypes are development tooling only.
"""
import argparse
import ctypes
import datetime
import hashlib
import json
import os
from pathlib import Path
import resource
import signal
import struct
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('symbols')
parser.add_argument('receipt')
parser.add_argument('compiler')
parser.add_argument('source_root')
parser.add_argument('new_output')
parser.add_argument('--expected-output-sha')
args = parser.parse_args()
symbols = json.loads(Path(args.symbols).read_text())
binary = Path(args.compiler).resolve()
assert hashlib.sha256(binary.read_bytes()).hexdigest() == symbols['artifact']['sha256']
assert not Path(args.new_output).exists()
selected = ['build@native/cli_builder', 'link@native/project', 'module@native/check',
            'collect@native/definitions', 'generate_cli@native/x64',
            'plan_cli@native/x64', 'assemble@native/assembler', 'executable@native/elf']
entries = {f['start']: f['name'] for f in symbols['functions'] if f['name'] in selected}
assert set(entries.values()) == set(selected), set(selected) - set(entries.values())
capacity = symbols['arenaCapacityBytes']
field_names = 'r15 r14 r13 r12 rbp rbx r11 r10 r9 r8 rax rcx rdx rsi rdi orig_rax rip cs eflags rsp ss fs_base gs_base ds es fs gs'.split()

class Registers(ctypes.Structure):
    _fields_ = [(name, ctypes.c_ulonglong) for name in field_names]

libc = ctypes.CDLL(None, use_errno=True)
libc.ptrace.restype = ctypes.c_long
libc.ptrace.argtypes = [ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p, ctypes.c_void_p]

def ptrace(request, pid, address=0, data=0):
    ctypes.set_errno(0)
    result = libc.ptrace(request, pid, ctypes.c_void_p(address), ctypes.c_void_p(data))
    if result == -1 and ctypes.get_errno():
        raise OSError(ctypes.get_errno(), os.strerror(ctypes.get_errno()))
    return result

def regs(pid):
    value = Registers()
    ptrace(12, pid, 0, ctypes.addressof(value))
    return value

def allocated(value):
    result = value.r15 - (value.r14 - capacity)
    assert 0 <= result <= capacity, result
    return result

pid = None
words, return_counts, frames, completed = {}, {}, [], []
next_id = 0
report = dict(schema='gleam-in-gleam.phase-allocations/1',
    observedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    artifact=symbols['artifact'], sourceRevision=symbols['sourceRevision'],
    inputSourceSHA256={'src/'+str(p.relative_to(Path(args.source_root))): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(Path(args.source_root).rglob('*.gleam'))},
    sourceSHA256=symbols['sourceSHA256'], arenaCapacityBytes=capacity,
    instrumentation='software entry/return breakpoints in one newly forked owned process; R15 cursor observations',
    limitations=['Allocation volume, not reachability or retained live-object size',
                'ptrace timings are not a performance benchmark',
                'Phase totals may nest; exclusive values exclude selected nested phases'],
    complete=False)

def needed(address):
    return address in entries or return_counts.get(address, 0) > 0

def patch(address, enabled):
    base = address & ~7
    if base not in words:
        words[base] = ptrace(1, pid, base) & ((1 << 64) - 1)
    original = words[base]
    for offset in range(8):
        at = base + offset
        active = enabled if at == address else needed(at)
        if active:
            original = original & ~(255 << (8 * offset)) | 0xcc << (8 * offset)
    ptrace(4, pid, base, original)

with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
    try:
        pid = os.fork()
        if pid == 0:
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
            resource.setrlimit(resource.RLIMIT_CPU, (60, 60))
            os.dup2(stdout.fileno(), 1)
            os.dup2(stderr.fileno(), 2)
            ptrace(0, 0)
            os.kill(os.getpid(), signal.SIGSTOP)
            os.execve(str(binary), [str(binary), '--build-compiler', str(Path(args.new_output).resolve()),
                      '--source-root', str(Path(args.source_root).resolve())], {'PATH': ''})
        os.waitpid(pid, 0)
        ptrace(0x4200, pid, 0, 0x10 | 0x40 | 0x100000)
        while True:
            ptrace(7, pid)
            _, status, usage = os.wait4(pid, 0)
            if os.WIFEXITED(status) or os.WIFSIGNALED(status):
                report.update(exitCode=os.waitstatus_to_exitcode(status), peakRSSKiB=usage.ru_maxrss)
                break
            event = status >> 16
            if event == 4:  # exec completed; exact native image now mapped
                for address in entries:
                    patch(address, True)
                continue
            if event == 6:
                report['finalAllocatedBytes'] = allocated(regs(pid))
                continue
            assert os.WSTOPSIG(status) == signal.SIGTRAP, status
            value = regs(pid)
            address = value.rip - 1
            assert needed(address), hex(address)
            used = allocated(value)
            if frames and frames[-1]['returnAddress'] == address:
                frame = frames.pop()
                frame['exitAllocatedBytes'] = used
                frame['inclusiveAllocatedBytes'] = used - frame['entryAllocatedBytes']
                frame['exclusiveAllocatedBytes'] = frame['inclusiveAllocatedBytes'] - frame.pop('childrenBytes')
                return_counts[address] -= 1
                if frames:
                    frames[-1]['childrenBytes'] += frame['inclusiveAllocatedBytes']
                completed.append(frame)
                print(json.dumps({k: frame[k] for k in ['function', 'inclusiveAllocatedBytes', 'exclusiveAllocatedBytes']}), flush=True)
            if address in entries:
                with open(f'/proc/{pid}/mem', 'rb', buffering=0) as memory:
                    returned, = struct.unpack('<Q', os.pread(memory.fileno(), 8, value.rsp))
                frame = dict(id=next_id, parent=frames[-1]['id'] if frames else None,
                    function=entries[address], entryAllocatedBytes=used,
                    returnAddress=returned, childrenBytes=0)
                next_id += 1
                frames.append(frame)
                return_counts[returned] = return_counts.get(returned, 0) + 1
                patch(returned, True)
            patch(address, False)
            value.rip = address
            ptrace(13, pid, 0, ctypes.addressof(value))
            ptrace(9, pid)
            _, stepped = os.waitpid(pid, 0)
            assert os.WIFSTOPPED(stepped) and os.WSTOPSIG(stepped) == signal.SIGTRAP, stepped
            patch(address, needed(address))
        pid = None
        stdout.seek(0)
        stderr.seek(0)
        report['stdout'], report['stderr'] = stdout.read().decode(), stderr.read().decode()
        report['phases'] = sorted(completed, key=lambda f: f['id'])
        assert report['exitCode'] == 0 and not frames, report
        output = Path(args.new_output).read_bytes()
        report['output'] = dict(bytes=len(output), sha256=hashlib.sha256(output).hexdigest())
        expected = args.expected_output_sha or report['artifact']['sha256']
        assert report['output']['sha256'] == expected, 'Unexpected compiler output'
        report['expectedOutputSHA256'] = expected
        root = next(f for f in completed if f['function'] == 'build@native/cli_builder')
        report['beforeBuildAllocatedBytes'] = root['entryAllocatedBytes']
        report['afterBuildAllocatedBytes'] = report['finalAllocatedBytes'] - root['exitAllocatedBytes']
        report['complete'] = True
    except BaseException as error:
        report['failure'] = repr(error)
        raise
    finally:
        if pid:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        Path(args.receipt).write_text(json.dumps(report, indent=2) + '\n')
