"""Session time keeps running while one player is in a scene."""
import time

from gametest import expect
from gametest.scenarios._clock import clk, full

NAME = "scene_clock_runs"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    time.sleep(2)
    guest.cmd({"cmd": "scene_flag", "on": True})
    time.sleep(0.5)
    g0, h0, s0 = clk(guest), clk(host), full(host)["st"]
    time.sleep(4)
    expect(clk(guest) == g0, "the guest's own game is paused by the scene")
    expect(clk(host) - h0 > 200, "the host's clock kept running")
    guest.cmd({"cmd": "scene_flag", "on": False})
    time.sleep(3)
    expect(abs(clk(guest) - clk(host)) <= 150, "the guest caught up after the scene")
