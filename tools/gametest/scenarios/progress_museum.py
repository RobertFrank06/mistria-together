"""A guest's museum donation shows up for the host, and survives a night."""
import time

from gametest import expect, expect_equal
from gametest.scenarios._night import cal, finish_night, go_home

NAME = "progress_museum"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    m0 = host.state()["progress"]["museum"]
    guest.cmd({"cmd": "donate"})
    time.sleep(3)
    expect_equal(host.state()["progress"]["museum"], m0 + 1, "host's museum has the guest's donation")
    go_home(session.all)
    c0 = cal(host)
    host.cmd({"cmd": "bed", "action": "sleep"})
    guest.cmd({"cmd": "bed", "action": "sleep"})
    finish_night(session.all, c0)
    time.sleep(4)
    expect_equal(host.state()["progress"]["museum"], m0 + 1, "still there after the night (host)")
    expect_equal(guest.state()["progress"]["museum"], m0 + 1, "still there after the night (guest)")
