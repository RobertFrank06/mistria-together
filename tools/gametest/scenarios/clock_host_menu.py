"""A host's menu freezes only the host's game; the guest's clock keeps going."""
import time

from gametest import expect
from gametest.scenarios._clock import clk, wait_close

NAME = "clock_host_menu"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    time.sleep(2)
    host.cmd({"cmd": "menu_open"})
    time.sleep(0.3)
    h0, g0 = clk(host), clk(guest)
    time.sleep(5)
    h1, g1 = clk(host), clk(guest)
    expect(h1 - h0 <= 5, f"host clock frozen during its menu ({h0} -> {h1})")
    expect(g1 - g0 > 200, f"guest clock kept running ({g0} -> {g1})")
    host.cmd({"cmd": "menu_close"})
    d = wait_close(host, guest, 120, "after the host's menu closes")
    expect(d <= 120, f"clocks within 2 game minutes (off by {d})")
