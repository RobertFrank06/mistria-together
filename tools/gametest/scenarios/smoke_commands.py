"""Dev commands return results with the documented shapes."""
from gametest import expect

NAME = "smoke_commands"
PLAYERS = 2
SETUP = "farm"


def run(session):
    for g in session.all:
        d = g.cmd({"cmd": "digest", "scope": "near", "radius": 10})
        expect(isinstance(d.get("lines"), list), f"{g.name} digest returns a list")
        c = g.cmd({"cmd": "clock"})
        expect(all(k in c for k in ("clk", "cal", "paused")), f"{g.name} clock returns clk/cal/paused")
        gold = g.cmd({"cmd": "gold_get"})
        expect(isinstance(gold.get("gold"), (int, float)), f"{g.name} gold_get returns a number")
