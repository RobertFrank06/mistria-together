"""A guest who faints waits at the summary; the night runs when the host sleeps."""
import time

from gametest import expect
from gametest.scenarios._night import cal, finish_night, go_home

NAME = "night_faint_holds"
PLAYERS = 2


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    go_home(session.all)
    c0 = cal(host)
    guest.cmd({"cmd": "faint"})
    guest.wait(lambda s: (s.get("night") or {}).get("eod_button"), "summary button", 60)
    expect(guest.cmd({"cmd": "summary_next"})["tapped"] is False, "summary button is locked")
    time.sleep(3)
    expect(cal(guest) == c0, "guest cannot advance alone")
    expect(guest.cmd({"cmd": "night_state"})["held"], "guest is held")
    host.cmd({"cmd": "bed", "action": "sleep"})
    finish_night(session.all, c0)
    expect(cal(guest) == cal(host), "both advanced together")
