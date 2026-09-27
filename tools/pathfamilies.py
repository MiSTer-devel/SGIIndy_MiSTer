#!/usr/bin/env python3
"""Group a TimeQuest path summary into families: source module -> endpoint.

    python tools/pathfamilies.py paths.txt        (output of scripts/corepaths.tcl)

Each "==== ... ====" section of the report is grouped on its own. A family is
the first three hierarchy levels of the source (instance names, without the
entity) and, for an endpoint inside ddr3_mux, the register name with its bit
index dropped; otherwise the endpoint's first three levels. Printed worst
first: worst slack, how many endpoints, source -> destination.
"""
import collections
import re
import sys


def level3(node):
    node = re.sub(r"^emu:emu\|", "", node)
    parts = node.split("|")[:3]
    return "|".join(p.split(":")[-1] for p in parts)


def dest(node):
    if "ddr3_mux" in node:
        return re.sub(r"\[\d+\]", "[]", node.split("|")[-1])
    return level3(node)


def main():
    txt = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    sections = re.split(r"^(==== .* ====)$", txt, flags=re.M)
    for i in range(1, len(sections), 2):
        title, body = sections[i], sections[i + 1]
        paths = re.findall(r"Slack\s+:\s+(-?[\d.]+).*?From Node\s+:\s+(\S+)"
                           r".*?To Node\s+:\s+(\S+)", body, re.S)
        count = collections.Counter()
        worst = {}
        for slack, src, dst in paths:
            k = (level3(src), dest(dst))
            count[k] += 1
            worst[k] = min(worst.get(k, 1e9), float(slack))
        print(title)
        print("%d endpoints, %d violated" % (len(paths),
                                             sum(1 for p in paths if float(p[0]) < 0)))
        for k in sorted(count, key=lambda k: worst[k])[:30]:
            print("%8.3f %4d  %s  ->  %s" % (worst[k], count[k], k[0], k[1]))
        print()


if __name__ == "__main__":
    main()
