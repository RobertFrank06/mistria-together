"""A time skip made by one player does not move the session clock."""
import time

from gametest import expect
from gametest.scenarios._clock import clk, full

NAME = "clock_no_skip"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    time.sleep(2)
    before = full(host)["st"]
    guest.cmd({"cmd": "clock", "jump": clk(guest) + 3600})
    time.sleep(1.5)
    st_h, st_g = full(host)["st"], full(guest)["st"]
    expect(st_h - before < 400, f"host session time did not jump ({before} -> {st_h})")
    expect(abs(clk(guest) - clk(host)) <= 150, "guest clock did not skip ahead")
    expect(abs(st_g - st_h) <= 150, "guest session time follows the host")
