"""Changes made on either side show up on the other within 5 s."""
from gametest import expect, expect_same_world

NAME = "live_changes"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    objs = host.cmd({"cmd": "find"})["objects"]
    expect(len(objs) >= 2, "farm has at least two objects near the start")
    a, b = objs[0], objs[1]
    host.cmd({"cmd": "erase", "x": a["x"], "y": a["y"]})
    host.cmd({"cmd": "till", "x": 810 // 8, "y": 810 // 8})
    host.cmd({"cmd": "water", "x": 810 // 8, "y": 810 // 8})
    guest.cmd({"cmd": "erase", "x": b["x"], "y": b["y"]})
    guest.cmd({"cmd": "till", "x": 830 // 8, "y": 830 // 8})
    expect_same_world(session.all, "near", timeout=5)
