"""Measure shipped decoder latency and Windows peak working set on a real APK."""
import argparse
import ctypes
from ctypes import wintypes
import json
import subprocess
import time
from pathlib import Path
import release as r


class MemoryCounters(ctypes.Structure):
    _fields_ = [('cb', wintypes.DWORD), ('PageFaultCount', wintypes.DWORD)] + [
        (name, ctypes.c_size_t) for name in ['PeakWorkingSetSize', 'WorkingSetSize', 'QuotaPeakPagedPoolUsage',
            'QuotaPagedPoolUsage', 'QuotaPeakNonPagedPoolUsage', 'QuotaNonPagedPoolUsage', 'PagefileUsage', 'PeakPagefileUsage']]


def main():
    p = argparse.ArgumentParser()
    for name in ['decoder', 'source', 'patch', 'target', 'output']: p.add_argument('--'+name, type=Path, required=True)
    args = p.parse_args()
    kernel = ctypes.WinDLL('kernel32'); api = ctypes.WinDLL('psapi')
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    api.GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD]
    started = time.monotonic()
    process = subprocess.Popen([str(args.decoder), str(args.source), str(args.patch), str(args.output), str(args.target.stat().st_size)])
    handle = kernel.OpenProcess(0x410, False, process.pid)
    counters = MemoryCounters(); counters.cb = ctypes.sizeof(counters); peak = 0
    try:
        while process.poll() is None:
            if api.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb): peak = max(peak, counters.PeakWorkingSetSize)
            time.sleep(.005)
    finally: kernel.CloseHandle(handle)
    if process.returncode or r.sha(args.output) != r.sha(args.target): raise ValueError('Decoder failed canonical reconstruction')
    print(json.dumps(dict(seconds=round(time.monotonic()-started, 3), peakWorkingSetBytes=peak, exactReconstruction=True)))


if __name__ == '__main__': main()
