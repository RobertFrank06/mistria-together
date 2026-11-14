"""Session time reaching 2:00 brings every clock to the end of the day."""
import time

from gametest import expect
from gametest.scenarios._clock import clk

NAME = "clock_two_am"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    time.sleep(1)
    host.cmd({"cmd": "clock", "set": 26 * 3600 - 60})
    time.sleep(4)
    expect(clk(host) >= 26 * 3600 - 5, f"host at 2:00 ({clk(host)})")
    expect(clk(guest) >= 26 * 3600 - 5, f"guest at 2:00 ({clk(guest)})")
