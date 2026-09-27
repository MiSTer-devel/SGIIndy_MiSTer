#!/usr/bin/env python3
"""The SCSI command log (build 47). RUNS ON THE DEVICE.

    python3 scsilog.py                          every logged command, oldest first
    python3 scsilog.py --writes                 only WRITE(6) / WRITE(10)
    python3 scsilog.py --tail 40                the last 40
    python3 scsilog.py --file IMG /usr/lib/libX11.so.1 [--part 0]
                                                only commands that touched that
                                                file's blocks, and a verdict

WHY. On 2026-09-27 (build 46) a file IRIX had read correctly was different on
the disk image after the session: a write landed on it that nothing had sent.
The question that splits the causes in two is whether IRIX ever SENT a
command that wrote to those blocks. If it did, the cause is above the SCSI
bus (the filesystem, or guest memory it trusted); if it never did, the write
came from below the command - the target, the block cache, the HPS side.

THE LOG. Every command a target takes is an entry {opcode:8, 0:5, target:3,
transfer length:16, LBA:32} (scsi.v dbg_cmdlog; the length and LBA are the
CDB's, in the target's own block size - the CD's are 2048-byte blocks), in a
16,384-entry ring of little-endian doublewords at ARM 0x35810000 (sgiindy.sv).
Beacon word 49 is {0xC10C:16, 0:2, next slot:14, entries ever logged:32}.
The ring is cleared only when the core is loaded, so it spans IRIX reboots,
and it holds the last 16,384 commands.
"""
import argparse
import importlib.util
import struct
import sys

spec = importlib.util.spec_from_file_location("p", "/media/fat/sgidbg/ddr3_peek.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

BCN = 0x35800000
RING = 0x35810000
SLOTS = 16384
OPS = {0x00: "TEST UNIT READY", 0x03: "REQUEST SENSE", 0x08: "READ(6)", 0x0A: "WRITE(6)",
       0x12: "INQUIRY", 0x15: "MODE SELECT", 0x1A: "MODE SENSE", 0x1B: "START STOP",
       0x25: "READ CAPACITY", 0x28: "READ(10)", 0x2A: "WRITE(10)", 0x2F: "VERIFY(10)",
       0x35: "SYNCHRONIZE CACHE", 0x43: "READ TOC"}
WRITES = (0x0A, 0x2A)


def entries():
    w49 = struct.unpack("<Q", m.read_phys(BCN + 49 * 8, 8))[0]
    if w49 >> 48 != 0xC10C:
        sys.exit("no command log (beacon word 49 = %016x; build 47 or later?)" % w49)
    nxt, total = (w49 >> 32) & 0x3FFF, w49 & 0xFFFFFFFF
    raw = m.read_phys(RING, SLOTS * 8)
    ring = struct.unpack("<%dQ" % SLOTS, raw)
    order = range(nxt, nxt + SLOTS) if total >= SLOTS else range(0, nxt)
    first = total - len(order)
    out = []
    for i, k in enumerate(order):
        e = ring[k % SLOTS]
        out.append((first + i, e >> 56, (e >> 48) & 7, (e >> 32) & 0xFFFF, e & 0xFFFFFFFF))
    return total, out


def file_lbas(img, path, part):
    sys.path.insert(0, "/media/fat/sgidbg")
    import efsread
    fs = efsread.Efs(img, part)
    _num, ino = fs.resolve(path)
    first = fs.base // 512
    return [(first + bn, first + bn + length) for bn, length, _off in fs.extents(ino)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--writes", action="store_true")
    ap.add_argument("--tail", type=int, default=0)
    ap.add_argument("--file", nargs=2, metavar=("IMG", "PATH"))
    ap.add_argument("--part", type=int, default=0)
    ap.add_argument("--target", type=int, default=1, help="the disk's SCSI ID for --file (1)")
    a = ap.parse_args()

    total, ents = entries()
    ranges = file_lbas(a.file[0], a.file[1], a.part) if a.file else None
    print("%d commands logged, %d in the ring" % (total, len(ents)))
    if ranges:
        print("%s: %d extents, LBAs %s" % (a.file[1], len(ranges),
              ", ".join("%d-%d" % (lo, hi - 1) for lo, hi in ranges[:8])
              + (" ..." if len(ranges) > 8 else "")))
    shown = []
    for seq, op, tgt, n, lba in ents:
        if a.writes and op not in WRITES:
            continue
        if ranges is not None:
            if tgt != a.target or op not in (0x08, 0x28, 0x0A, 0x2A):
                continue
            cnt = (256 if n == 0 else n) if op in (0x08, 0x0A) else n
            if not any(lba < hi and lba + cnt > lo for lo, hi in ranges):
                continue
        shown.append((seq, op, tgt, n, lba))
    if a.tail:
        shown = shown[-a.tail:]
    for seq, op, tgt, n, lba in shown:
        print("%8d  target %d  %-18s lba %10d  len %5d" % (seq, tgt, OPS.get(op, "op %02x" % op), lba, n))
    if ranges is not None:
        w = [s for s in shown if s[1] in WRITES]
        print("SCSILOG %s: %d reads and %d writes of the file's blocks in the ring"
              % ("WROTE" if w else "NO-WRITES", len(shown) - len(w), len(w)))


if __name__ == "__main__":
    main()
