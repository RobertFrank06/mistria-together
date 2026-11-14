"""Asking for the shared wallet takes effect at the next morning."""
import time

from gametest import expect
from gametest.scenarios._night import cal, finish_night, go_home
from gametest.scenarios._wallet import gold, setup_golds, wait_gold

NAME = "wallet_switch_to_shared"
PLAYERS = 2


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    setup_golds(session)
    host.cmd({"cmd": "wallet", "mode": "shared"})
    time.sleep(1)
    expect(gold(guest) == 500, "nothing changes during the day")
    go_home(session.all)
    c0 = cal(host)
    host.cmd({"cmd": "bed", "action": "sleep"})
    guest.cmd({"cmd": "bed", "action": "sleep"})
    finish_night(session.all, c0)
    expect(wait_gold(host, 1500, "host"), f"host holds the combined gold ({gold(host)})")
    expect(wait_gold(guest, 1500, "guest"), f"guest sees the combined gold ({gold(guest)})")
