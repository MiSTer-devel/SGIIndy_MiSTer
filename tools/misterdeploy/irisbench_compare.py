#!/usr/bin/env python3
"""Side by side: IRIS benchmark results tables from several builds.

    python3 irisbench_compare.py irisbench.elf b54=results54.bin b56=results56.bin [b57=...]

Each column is a results.bin read off the board as irisbench_results.py
describes; rates are work units per second of CP0 Count (25 MHz here), the
last columns are each build's rate over the first column's. Dhrystone and
LINPACK get their industry units (DMIPS = dhry/s / 1757, MFLOPS = flop/s / 1e6).
"""
import struct
import sys

from irisbench_results import REC, R_STATUS, elf_cstr, elf_read, load_elf_sections, words

COUNT_HZ = 25e6


def table(secs, path):
    raw = open(path, "rb").read()
    rows = []
    for i in range(len(raw) // REC):
        rec = words(raw[i * REC:(i + 1) * REC])
        b, iters, work, ns, icount, ticks, exc, ssum, gold, status = struct.unpack_from(">IIQQQIIQQi", rec, 0)
        if b == 0:
            break
        name_p, unit_p = struct.unpack(">II", elf_read(secs, b, 8))
        rate = work * COUNT_HZ / ticks if ticks else 0.0
        rows.append((elf_cstr(secs, name_p), elf_cstr(secs, unit_p), rate, R_STATUS.get(status, status)))
    return rows


def main():
    elf, cols = sys.argv[1], [a.split("=", 1) for a in sys.argv[2:]]
    secs = load_elf_sections(elf)
    data = {label: table(secs, path) for label, path in cols}
    base = cols[0][0]
    names = [r[0] for r in data[base]]
    hdr = f"{'benchmark':<22} {'unit':<5}" + "".join(f"{l:>14}" for l, _ in cols) + "".join(f"{l+'/'+base:>10}" for l, _ in cols[1:])
    print(hdr)
    for i, name in enumerate(names):
        unit = data[base][i][1]
        rates, accs = [], []
        for l, _ in cols:
            rows = data[l]
            r = next((x for x in rows if x[0] == name), None)
            rates.append(r[2] if r else 0.0)
            accs.append(r[3] if r else "-")
        line = f"{name:<22} {unit:<5}" + "".join(f"{v:>14.0f}" for v in rates)
        line += "".join(f"{(v / rates[0] if rates[0] else 0):>10.3f}" for v in rates[1:])
        if any(a != "ok" for a in accs):
            line += "   acc: " + " ".join(accs)
        print(line)
        if name == "int/dhrystone":
            print(f"{'  = DMIPS':<28}" + "".join(f"{v / 1757:>14.1f}" for v in rates))
        if name == "fpu/linpack":
            print(f"{'  = MFLOPS':<28}" + "".join(f"{v / 1e6:>14.2f}" for v in rates))
    return 0


if __name__ == "__main__":
    sys.exit(main())
