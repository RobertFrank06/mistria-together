"""A sleeping guest never reaches the next day while the host is awake."""
import time

from gametest import expect
from gametest.scenarios._night import cal, go_home

NAME = "night_guest_cannot_advance"
PLAYERS = 2


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    go_home(session.all)
    c0 = cal(host)
    guest.cmd({"cmd": "bed", "action": "sleep"})
    time.sleep(20)
    expect(cal(guest) == c0, "guest calendar unchanged")
    expect(not guest.cmd({"cmd": "night_state"})["eod"], "guest never reached the summary")
    expect(cal(host) == c0, "host calendar unchanged")
