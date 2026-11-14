"""The host's day length decides the pace for everyone."""
import time

from gametest import expect
from gametest.scenarios._clock import clk, full

NAME = "clock_day_length"
PLAYERS = 2
SETUP = "farm"


def run(session):
    host, guest = session.host, session.guests[0]
    host.cmd({"cmd": "setmpd", "value": 30})
    session.connect()
    time.sleep(2)
    expect(full(guest)["mpd"] == 30, "guest adopted the host's day length")
    h0, g0, t0 = clk(host), clk(guest), time.time()
    time.sleep(10)
    h1, g1, t1 = clk(host), clk(guest), time.time()
    rate = (h1 - h0) / (t1 - t0)
    expect(abs(rate - 48) < 8, f"host pace matches a 30 minute day ({rate:.1f}/s)")
    expect(abs((g1 - g0) - (h1 - h0)) <= 120, "guest advanced as much as the host")
