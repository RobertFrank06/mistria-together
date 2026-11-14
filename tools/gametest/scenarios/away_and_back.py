"""A guest leaves the farm, the host changes it, the guest returns."""
import time

from gametest import FARM_ROOM, FARM_X, FARM_Y, expect_same_world

NAME = "away_and_back"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    guest.cmd({"cmd": "tp", "room": "player_home", "x": 100, "y": 100})
    time.sleep(2)
    objs = host.cmd({"cmd": "find"})["objects"]
    host.cmd({"cmd": "erase", "x": objs[0]["x"], "y": objs[0]["y"]})
    host.cmd({"cmd": "till", "x": 100, "y": 100})
    time.sleep(2)
    guest.cmd({"cmd": "tp", "room": FARM_ROOM, "x": FARM_X, "y": FARM_Y})
    time.sleep(3)
    expect_same_world(session.all, "near", timeout=8)
