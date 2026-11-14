"""With nobody else online a menu pauses the clock exactly as in single player."""
import time

from gametest import expect
from gametest.scenarios._clock import clk

NAME = "clock_solo_unchanged"
PLAYERS = 1
SETUP = "farm"


def run(session):
    host = session.host
    time.sleep(1)
    host.cmd({"cmd": "menu_open"})
    a = clk(host)
    time.sleep(3)
    expect(clk(host) == a, "clock frozen by a menu in single player")
    host.cmd({"cmd": "menu_close"})
    time.sleep(3)
    expect(clk(host) > a + 100, "clock runs again")
