#!/usr/bin/env python3
"""Disassemble an IRIX ECOFF relocatable object (.o), relocations annotated.

    python ecoffdis.py kdsp_a2.o procs            # list procedures
    python ecoffdis.py kdsp_a2.o dis NAME [NAME..] # disassemble procedures
    python ecoffdis.py kdsp_a2.o strings           # .rdata/.data strings
"""
import re
import struct
import sys
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_BIG_ENDIAN

data = open(sys.argv[1], "rb").read()
(f_magic, f_nscns, f_timdat, f_symptr, f_nsyms, f_opthdr,
 f_flags) = struct.unpack(">HHiiiHH", data[:20])
scns = []
off = 20 + f_opthdr
for i in range(f_nscns):
    (s_name, s_paddr, s_vaddr, s_size, s_scnptr, s_relptr, s_lnnoptr,
     s_nreloc, s_nlnno, s_flags) = struct.unpack(">8siiiiiiHHi", data[off:off + 40])
    scns.append(dict(name=s_name.rstrip(b"\0").decode(), vaddr=s_vaddr & 0xFFFFFFFF,
                     size=s_size, ptr=s_scnptr, relptr=s_relptr, nreloc=s_nreloc))
    off += 40

h = struct.unpack(">hh23i", data[f_symptr:f_symptr + 96])
(magic, vstamp, ilineMax, cbLine, cbLineOffset, idnMax, cbDnOffset,
 ipdMax, cbPdOffset, isymMax, cbSymOffset, ioptMax, cbOptOffset,
 iauxMax, cbAuxOffset, issMax, cbSsOffset, issExtMax, cbSsExtOffset,
 ifdMax, cbFdOffset, crfd, cbRfdOffset, iextMax, cbExtOffset) = h

ext = []
for i in range(iextMax):
    o = cbExtOffset + i * 16
    res, ifd, iss, value, bf = struct.unpack(">hhiiI", data[o:o + 16])
    st = (bf >> 26) & 0x3F
    sc = (bf >> 21) & 0x1F
    e = data.find(b"\0", cbSsExtOffset + iss)
    ext.append((data[cbSsExtOffset + iss:e].decode("latin1"), value & 0xFFFFFFFF, st, sc))

procs = {}
locs = []
for ifd in range(ifdMax):
    o = cbFdOffset + ifd * 72
    (adr, rss, issBase, cbSs, isymBase, csym, ilineBase, cline,
     ioptBase, copt, ipdFirst, cpd, iauxBase, caux, rfdBase, crfd_,
     bf, cbLO, cbL) = struct.unpack(">10ihh4i3i", data[o:o + 72])
    for i in range(csym):
        so = cbSymOffset + (isymBase + i) * 12
        iss, value, sbf = struct.unpack(">iiI", data[so:so + 12])
        st = (sbf >> 26) & 0x3F
        sc = (sbf >> 21) & 0x1F
        e = data.find(b"\0", cbSsOffset + issBase + iss)
        name = data[cbSsOffset + issBase + iss:e].decode("latin1")
        if st in (6, 14):
            procs[name] = value & 0xFFFFFFFF
        elif st in (2, 3) and sc in (2, 3, 13, 14, 15, 16, 17, 18):
            locs.append((value & 0xFFFFFFFF, name))
for name, value, st, sc in ext:
    if st == 6 and sc == 1:
        procs.setdefault(name, value)

SECN = {1: ".text", 2: ".rdata", 3: ".data", 4: ".sdata", 5: ".sbss", 6: ".bss",
        7: ".init", 8: ".lit8", 9: ".lit4", 10: ".xdata", 11: ".pdata", 12: ".fini"}
RT = {0: "IGN", 1: "HALF", 2: "WORD", 3: "JMP", 4: "HI", 5: "LO", 6: "GPREL", 7: "LIT"}
relocs = {}
for s in scns:
    for i in range(s["nreloc"]):
        o = s["relptr"] + i * 8
        vaddr = struct.unpack(">I", data[o:o + 4])[0]
        b = data[o + 4:o + 8]
        symndx = (b[0] << 16) | (b[1] << 8) | b[2]
        typ = (b[3] & 0x1E) >> 1
        isext = b[3] & 1
        tgt = ext[symndx][0] if isext and symndx < len(ext) else SECN.get(symndx, "sec%d" % symndx)
        relocs[vaddr] = "%s:%s" % (RT.get(typ, typ), tgt)

text = next(s for s in scns if s["name"] == ".text")
tdata = data[text["ptr"]:text["ptr"] + text["size"]]
tbase = text["vaddr"]
sorted_procs = sorted(set(procs.values()))

def proc_end(a):
    for p in sorted_procs:
        if p > a:
            return p
    return tbase + text["size"]

def section_word(va):
    for s in scns:
        if s["vaddr"] <= va < s["vaddr"] + s["size"] and s["ptr"]:
            o = s["ptr"] + va - s["vaddr"]
            return struct.unpack(">I", data[o:o + 4])[0]
    return None

md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_BIG_ENDIAN)
md.skipdata = True

def dis(name):
    a = procs[name]
    e = proc_end(a)
    print("\n==== %s  0x%08x..0x%08x" % (name, a, e))
    hiv = {}
    for ins in md.disasm(tdata[a - tbase:e - tbase], a):
        note = ""
        r = relocs.get(ins.address)
        if r:
            note += "  <%s>" % r
        if ins.mnemonic == "lui":
            rr, v = [t.strip() for t in ins.op_str.split(",")]
            hiv[rr] = int(v, 0) << 16
        elif ins.mnemonic in ("addiu", "ori", "addi", "lw", "sw", "lh", "sh", "lb", "sb", "lhu", "lbu", "ld", "sd"):
            p = [t.strip() for t in ins.op_str.split(",")]
            if ins.mnemonic in ("addiu", "ori", "addi") and len(p) == 3 and p[1] in hiv:
                v = int(p[2], 0)
                if ins.mnemonic != "ori" and v >= 0x8000:
                    v -= 0x10000
                note += "  ; = 0x%08x" % ((hiv[p[1]] + v) & 0xffffffff)
            elif len(p) == 2:
                m = re.match(r"(-?0x[0-9a-f]+|-?\d+)\((\$\w+)\)", p[1])
                if m and m.group(2) in hiv:
                    v = int(m.group(1), 0)
                    note += "  ; @ 0x%08x" % ((hiv[m.group(2)] + v) & 0xffffffff)
        # any other write to a register kills what lui put there
        if ins.mnemonic != "lui" and not ins.mnemonic.startswith(("s", "b", "j", "c")) \
                or ins.mnemonic in ("sll", "srl", "sra", "slt", "sltu", "slti", "sltiu", "sub", "subu", "sllv", "srlv", "srav"):
            p = [t.strip() for t in ins.op_str.split(",")]
            if p and p[0].startswith("$"):
                hiv.pop(p[0], None)
        if ins.mnemonic in ("jal", "jalr"):
            for r in ("$at", "$v0", "$v1", "$a0", "$a1", "$a2", "$a3", "$t0", "$t1", "$t2", "$t3", "$t4", "$t5", "$t6", "$t7", "$t8", "$t9"):
                hiv.pop(r, None)
        print("   0x%08x  %-8s %s%s" % (ins.address, ins.mnemonic, ins.op_str, note))

if sys.argv[2] == "procs":
    for n, v in sorted(procs.items(), key=lambda x: x[1]):
        print("%08x %s" % (v, n))
    for s in scns:
        print("  %-8s va=0x%08x size=0x%x nreloc=%d" % (s["name"], s["vaddr"], s["size"], s["nreloc"]))
elif sys.argv[2] == "dis":
    for n in sys.argv[3:]:
        dis(n)
elif sys.argv[2] == "strings":
    for s in scns:
        if s["name"] in (".rdata", ".data", ".sdata") and s["ptr"]:
            blob = data[s["ptr"]:s["ptr"] + s["size"]]
            for m in re.finditer(rb"[\x20-\x7e\n\t]{4,}", blob):
                print("%s 0x%08x %r" % (s["name"], s["vaddr"] + m.start(), m.group().decode()))
