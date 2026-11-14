"""The deepest mine floor reached is shared."""
import time

from gametest import expect_equal

NAME = "progress_mine_depth"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    guest.cmd({"cmd": "mine_depth", "level": 17})
    time.sleep(3)
    expect_equal(host.state()["progress"]["depth"], 17, "host learned the guest's depth")
    host.cmd({"cmd": "mine_depth", "level": 30})
    time.sleep(3)
    expect_equal(guest.state()["progress"]["depth"], 30, "guest learned the host's depth")
