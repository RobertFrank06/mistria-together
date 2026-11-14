"""Both players go to bed: one night, one new day, equal worlds."""
import time

from gametest import expect, expect_equal, expect_same_world
from gametest.scenarios._night import cal, finish_night, go_home

NAME = "night_both_sleep"
PLAYERS = 2


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    go_home(session.all)
    c0 = cal(host)
    guest.cmd({"cmd": "bed", "action": "sleep"})
    time.sleep(2)
    expect(cal(host) == c0, "the night waits for the host")
    host.cmd({"cmd": "bed", "action": "sleep"})
    finish_night(session.all, c0)
    expect_equal(cal(guest), cal(host), "calendars equal in the morning")
    expect_equal(cal(host), c0 + 86400, "exactly one day passed")
    time.sleep(8)
    for g in session.all:
        g.cmd({"cmd": "tp", "room": "farm", "x": 800, "y": 800})
    time.sleep(3)
    expect_same_world(session.all, "near", timeout=20)
