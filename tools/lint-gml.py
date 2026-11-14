#!/usr/bin/env python3
"""Static rules for the GML mod (stdlib only). Exit 1 on any finding.

Rules (see IMPLEMENT.md, Phase 0.4):
  - no `noone` (does not exist in this dialect; use undefined)
  - top-level functions start with `mt_` or `__mt_`
  - `mod` is reserved: not usable as an identifier
  - every called `mt_*` function is defined in the mod
  - every game-to-game message type sent (`t: "x"`) has a handler, and every
    handler case has a sender (system messages from the companion excepted)
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GML = sorted((ROOT / "mod" / "mt" / "gml").glob("*.gml"))

# Messages that arrive from the companion (from = -1), not from other games.
SYSTEM = {"welcome", "join", "leave", "bye", "stat", "blob"}
# Functions whose `case "x"` labels are game-to-game message handlers.
DISPATCHERS = {"mt_net_dispatch", "mt_world_on_message", "mt_sync_on_message"}


def strip(src: str) -> str:
    """Blank out comments and string contents, keeping offsets and newlines."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif src.startswith("/*", i):
            j = src.find("*/", i)
            j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", src[i:j]))
            i = j
        elif c == '"':
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == "\\" else 1
            out.append('"' + "_" * (j - i - 1) + '"')
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def body_of(code: str, start: int) -> str:
    """Text of the brace block that opens at or after `start`."""
    i = code.index("{", start)
    depth = 0
    for j in range(i, len(code)):
        depth += code[j] == "{"
        depth -= code[j] == "}"
        if depth == 0:
            return code[i : j + 1]
    return code[i:]


def main() -> int:
    findings = []

    def bad(path, line, msg):
        findings.append(f"{path.relative_to(ROOT)}:{line}: {msg}")

    raw = {p: p.read_text() for p in GML}
    stripped = {p: strip(s) for p, s in raw.items()}

    defined = set()
    for p, code in stripped.items():
        for m in re.finditer(r"^function\s+(\w+)", code, re.M):
            defined.add(m.group(1))
        for m in re.finditer(r"^#macro\s+(\w+)", code, re.M):
            defined.add(m.group(1))

    sent, handled = {}, {}
    for p, code in stripped.items():
        text = raw[p]
        line_of = lambda off: code.count("\n", 0, off) + 1
        for m in re.finditer(r"^function\s+(\w+)", code, re.M):
            if not m.group(1).startswith(("mt_", "__mt_")):
                bad(p, line_of(m.start()), f"function {m.group(1)} must start with mt_ or __mt_")
        for m in re.finditer(r"\bnoone\b", code):
            bad(p, line_of(m.start()), "`noone` does not exist; use undefined")
        for m in re.finditer(r"(?<![\w.$\"])mod(?![\w\"])", code):
            bad(p, line_of(m.start()), "`mod` is a reserved word; use another name")
        for m in re.finditer(r"(?<![\w.])(mt_\w+)\s*\(", code):
            if m.group(1) not in defined:
                bad(p, line_of(m.start()), f"call to undefined function {m.group(1)}")
        for m in re.finditer(r'\bt:\s*"(\w+)"', text):
            ln = text.count("\n", 0, m.start()) + 1
            src_line = text.splitlines()[ln - 1]
            if "mt_send_link" in src_line:
                continue
            sent.setdefault(m.group(1), (p, ln))
        for m in re.finditer(r"^function\s+(\w+)", code, re.M):
            if m.group(1) in DISPATCHERS:
                blk_start = m.start()
                blk = body_of(code, blk_start)
                base = code.index(blk, blk_start)
                for c in re.finditer(r'case\s+"(\w+)"', text[base : base + len(blk)]):
                    handled.setdefault(c.group(1), (p, text.count("\n", 0, base + c.start()) + 1))
        # `_t == "x"` comparisons inside dispatchers count as handlers too.
        for m in re.finditer(r"^function\s+(\w+)", code, re.M):
            if m.group(1) in DISPATCHERS:
                blk = body_of(code, m.start())
                base = code.index(blk, m.start())
                for c in re.finditer(r'_t\s*==\s*"(\w+)"', text[base : base + len(blk)]):
                    handled.setdefault(c.group(1), (p, text.count("\n", 0, base + c.start()) + 1))

    for t, (p, ln) in sorted(sent.items()):
        if t not in handled:
            bad(p, ln, f'message type "{t}" is sent but has no handler')
    for t, (p, ln) in sorted(handled.items()):
        if t not in sent and t not in SYSTEM:
            bad(p, ln, f'message type "{t}" is handled but never sent')

    for f in findings:
        print(f)
    print(f"lint-gml: {len(findings)} finding(s) in {len(GML)} files")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
