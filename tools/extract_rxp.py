#!/usr/bin/env python3
"""Extract zone / level / quest lists from RestedXP's free Forever guides.

Source: https://github.com/RestedXP/RXPGuides (CC BY-NC-SA 4.0).
Usage: python3 -I extract_rxp.py <RXPGuides/Guides/forever dir> <out.json>
Only the guide header (#name = "<min>-<max> <zone>"), the "<<" race/class
filters and the .accept/.turnin/.complete/.goto lines are read.
"""
import json, re, sys, os

FILES = [  # Alliance speedrun guides, in route order
    "RestedXP-Skyborne.lua",
    "Alliance-1-10_NightElf.lua",
    "Alliance-1-13_Human.lua",
    "Alliance-1-14_DwarfGnome.lua",
    "Alliance-11-20.lua",
]

BLOCK = re.compile(r"RegisterGuide\(\[\[(.*?)\]\]", re.S)
NAME = re.compile(r"^\s*#name\s+(\d+)-(\d+)\s+(.+?)\s*$")
COND = re.compile(r"<<\s*(.+?)\s*$")
GOTO = re.compile(r"^\s*\.goto\s+([^,]+),([\d.]+),([\d.]+)")
QLINE = re.compile(r"^\s*\.(accept|turnin|complete)\s+(\d+)(?:,\d+)?\s*(?:>>\s*(?:Accept|Turn in)?\s*(.*?))?\s*(?:--.*)?$")


def clean_cond(c):
    c = re.sub(r"--.*$", "", c).strip()
    return c or None


def parse_block(text):
    lines = text.splitlines()
    head, steps, cur = [], [], None
    for ln in lines:
        s = ln.strip()
        if s.startswith("step"):
            cur = {"cond": None, "lines": []}
            m = COND.search(s)
            if m:
                cur["cond"] = clean_cond(m.group(1))
            steps.append(cur)
        elif cur is None:
            head.append(s)
        else:
            cur["lines"].append(ln)

    g = {"guideCond": None}
    for s in head:
        m = NAME.match(s)
        if m:
            g["min"], g["max"], g["zone"] = int(m.group(1)), int(m.group(2)), m.group(3)
        elif s.startswith("<<") and g["guideCond"] is None:
            g["guideCond"] = clean_cond(s[2:])
    if "zone" not in g:
        return None

    quests = {}
    order = []
    for st in steps:
        loc = None
        for ln in st["lines"]:
            m = GOTO.match(ln)
            if m and loc is None:
                z = m.group(1).strip()
                if z.isdigit():
                    z = g["zone"]  # numeric uiMapID (Skyborne): use the guide's zone
                if "/" in z:
                    continue  # world/instance coordinates, not zone percentages
                loc = [z, float(m.group(2)), float(m.group(3))]
        for ln in st["lines"]:
            m = QLINE.match(ln)
            if not m:
                continue
            kind, qid, qname = m.group(1), int(m.group(2)), (m.group(3) or "").strip()
            cond = st["cond"]
            if "<<" in qname:
                qname, lc = qname.split("<<", 1)
                qname, lc = qname.strip(), clean_cond(lc)
                if lc:
                    cond = cond + " && " + lc if cond else lc
            q = quests.get(qid)
            if q is None:
                q = quests[qid] = {"id": qid, "name": None, "cond": cond}
                order.append(qid)
            elif q["cond"] != cond:
                # seen under different filters: keep the broadest (no filter wins)
                if q["cond"] is None or cond is None:
                    q["cond"] = None
            if qname and not q["name"]:
                q["name"] = qname
            if kind == "accept" and loc and "start" not in q:
                q["start"] = loc
            if kind == "turnin" and loc:
                q["finish"] = loc
    g["quests"] = [quests[i] for i in order]
    return g


def main(src, out):
    guides = []
    for f in FILES:
        text = open(os.path.join(src, f), encoding="utf-8").read()
        for blk in BLOCK.findall(text):
            g = parse_block(blk)
            if g:
                g["source"] = f
                guides.append(g)
    json.dump(guides, open(out, "w"), indent=1)
    print(len(guides), "guides,", sum(len(g["quests"]) for g in guides), "quests")
    for g in guides:
        print(f'{g["min"]:>2}-{g["max"]:<2} {g["zone"]:<40} {str(g["guideCond"]):<30} {len(g["quests"])}')


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
