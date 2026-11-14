"""At 2:00 everyone passes out and the night runs after each summary."""
import time

from gametest import expect
from gametest.scenarios._night import cal, finish_night, go_home

NAME = "night_two_am"
PLAYERS = 2


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    go_home(session.all)
    c0 = cal(host)
    host.cmd({"cmd": "clock", "set": 26 * 3600 - 60})
    for g in session.all:
        g.wait(lambda s: (s.get("night") or {}).get("eod_button"), "summary at 2:00", 90)
    expect(True, "both players reached their summary")
    finish_night(session.all, c0)
    expect(cal(guest) == cal(host), "both advanced together")
