"""The host faints at noon: the session clock keeps running for the guest."""
import time

from gametest import expect
from gametest.scenarios._clock import clk
from gametest.scenarios._night import cal, finish_night, go_home

NAME = "night_host_faints"
PLAYERS = 2


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    go_home(session.all)
    c0 = cal(host)
    host.cmd({"cmd": "faint"})
    host.wait(lambda s: (s.get("night") or {}).get("eod_button"), "host summary button", 60)
    g0 = clk(guest)
    time.sleep(4)
    expect(clk(guest) - g0 > 100, "guest's clock kept running while the host waits")
    guest.cmd({"cmd": "bed", "action": "sleep"})
    finish_night(session.all, c0)
    expect(cal(guest) == cal(host), "both advanced together")
