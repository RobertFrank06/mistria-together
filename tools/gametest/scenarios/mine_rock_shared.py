"""A rock broken on a shared floor is gone for both players."""
from gametest import expect, expect_same_world
from gametest.scenarios._mines import enter

NAME = "mine_rock_shared"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    enter(session, [1, 1])
    host = session.host
    r = host.cmd({"cmd": "mine_break"})
    expect(r is not None, f"the host broke an object ({r})")
    expect_same_world(session.all, "grid", timeout=10)
