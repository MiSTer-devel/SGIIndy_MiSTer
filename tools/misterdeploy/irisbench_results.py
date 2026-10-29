#!/usr/bin/env python3
"""Read the IRIS benchmark suite's results out of guest RAM on the board.

The suite (../iris/bench, a bare-metal MIPS binary booted through the PROM
with `boot -f dksc(0,1,8)irisbnch`) prints over the SCC, which on this core
goes to the MiSTer's UART pins and nowhere a host can read. Its results table
is ordinary memory though: `static struct result results[]` in the harness,
and ddr3_peek.py reads guest RAM from the ARM (main memory at 0x38000000).

    # on the board (addresses from `readelf -s irisbench.elf`: results, n_results)
    python3 ddr3_peek.py 0x3820ddf0 0x10 -o n.bin; python3 ddr3_peek.py 0x3820ddf8 0xe00 -o results.bin
    # here
    python3 irisbench_results.py irisbench.elf results.bin [--count-hz 25000000]

The DDR3 image holds each 64-bit word little-endian, the MIPS layout inside it
is big-endian: a record's two 32-bit fields share one word, the first in the
high half. Names come from the ELF's .rodata through the record's `bench`
pointer. Rates are per second of CP0 Count at --count-hz (this core: 25 MHz,
PClock/2; the harness assumed 100 MHz when it had no host clock, so its own
printed rates would be 4x high).
"""
import argparse
import struct
import sys

REC = 64            # sizeof(struct result), 8-aligned
R_STATUS = {0: "ok", 1: "MISMATCH", 2: "unchecked", 3: "skip"}


def load_elf_sections(path):
    with open(path, "rb") as fh:
        data = fh.read()
    assert data[:4] == b"\x7fELF", "not an ELF"
    be = data[5] == 2
    E = ">" if be else "<"
    (e_shoff,) = struct.unpack_from(E + "I", data, 0x20)
    e_shentsize, e_shnum = struct.unpack_from(E + "HH", data, 0x2E)
    secs = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        sh_type, sh_flags, sh_addr, sh_offset, sh_size = struct.unpack_from(E + "IIIII", data, off + 4)
        if sh_type != 8 and sh_size:          # not NOBITS
            secs.append((sh_addr, sh_size, data[sh_offset:sh_offset + sh_size]))
    return secs


def elf_read(secs, addr, n):
    for base, size, blob in secs:
        if base <= addr < base + size:
            return blob[addr - base:addr - base + n]
    raise KeyError(hex(addr))


def elf_cstr(secs, addr):
    out = bytearray()
    while True:
        c = elf_read(secs, addr, 1)
        if not c or c == b"\0":
            return out.decode("ascii", "replace")
        out += c
        addr += 1


def words(blob):
    """The record as MIPS big-endian bytes."""
    out = bytearray()
    for i in range(0, len(blob), 8):
        out += blob[i:i + 8][::-1]
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("elf")
    ap.add_argument("results_bin")
    ap.add_argument("--count-hz", type=float, default=25e6)
    ap.add_argument("--max", type=int, default=56)
    a = ap.parse_args()
    secs = load_elf_sections(a.elf)
    raw = open(a.results_bin, "rb").read()
    print(f"{'benchmark':<26} {'unit':<5} {'work':>12} {'ticks':>11} {'rate/s':>14}  acc")
    n = 0
    for i in range(min(a.max, len(raw) // REC)):
        rec = words(raw[i * REC:(i + 1) * REC])
        b, iters, work, ns, icount, ticks, exc, ssum, gold, status = struct.unpack_from(">IIQQQIIQQi", rec, 0)
        if b == 0:
            break
        name_p, unit_p = struct.unpack(">II", elf_read(secs, b, 8))
        name, unit = elf_cstr(secs, name_p), elf_cstr(secs, unit_p)
        rate = work * a.count_hz / ticks if ticks else 0.0
        print(f"{name:<26} {unit:<5} {work:>12} {ticks:>11} {rate:>14.0f}  {R_STATUS.get(status, status)}"
              + (f"  exc={exc}" if exc else ""))
        n += 1
    print(f"\n{n} records; rates per second of CP0 Count at {a.count_hz/1e6:.1f} MHz")
    return 0


if __name__ == "__main__":
    sys.exit(main())
