"""Pure GML logic (ready set, bin split) checked inside the real game."""
from gametest import expect

NAME = "unit_pure_logic"
PLAYERS = 1


def run(session):
    for r in session.host.cmd({"cmd": "selftest"})["results"]:
        expect(r["ok"], r["name"])
