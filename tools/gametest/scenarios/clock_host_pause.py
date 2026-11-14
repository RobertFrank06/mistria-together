"""The host's explicit pause stops everyone's time; resume restarts it."""
import time

from gametest import expect
from gametest.scenarios._clock import clk

NAME = "clock_host_pause"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    time.sleep(2)
    host.cmd({"cmd": "host_pause", "on": True})
    time.sleep(1.5)
    h0, g0 = clk(host), clk(guest)
    time.sleep(3)
    h1, g1 = clk(host), clk(guest)
    expect(h1 == h0 and g1 == g0, f"both clocks stopped ({h0}->{h1}, {g0}->{g1})")
    expect(guest.cmd({"cmd": "clock"})["st_paused"], "guest knows the host paused")
    host.cmd({"cmd": "host_pause", "on": False})
    time.sleep(3)
    expect(clk(host) - h1 > 100 and clk(guest) - g1 > 100, "both clocks run again")
