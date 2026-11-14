"""A guest's menu freezes only the guest's game; the host's clock keeps going."""
import time

from gametest import expect
from gametest.scenarios._clock import clk, wait_close

NAME = "clock_guest_menu"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    time.sleep(2)
    guest.cmd({"cmd": "menu_open"})
    time.sleep(0.3)
    h0, g0 = clk(host), clk(guest)
    time.sleep(5)
    h1, g1 = clk(host), clk(guest)
    expect(g1 - g0 <= 5, f"guest clock frozen during its menu ({g0} -> {g1})")
    expect(h1 - h0 > 200, f"host clock kept running ({h0} -> {h1})")
    guest.cmd({"cmd": "menu_close"})
    d = wait_close(host, guest, 120, "after the guest's menu closes")
    expect(d <= 120, f"clocks within 2 game minutes (off by {d})")
