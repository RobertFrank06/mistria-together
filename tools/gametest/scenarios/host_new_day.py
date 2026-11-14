"""The host runs the day transition; guests follow the calendar and world."""
from gametest import expect_equal, expect_same_world

NAME = "host_new_day"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    cal = host.cmd({"cmd": "clock"})["cal"]
    host.cmd({"cmd": "newday"}, timeout=30)
    guest.wait(lambda s: s.get("cal") != cal, "guest calendar to advance", 30)
    expect_equal(guest.state()["cal"], host.state()["cal"], "calendars equal after the new day")
    expect_same_world(session.all, "near", timeout=15)
