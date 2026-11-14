"""Shared wallet: nobody can spend below zero when two purchases race."""
import time

from gametest import expect
from gametest.scenarios._wallet import gold, setup_golds

NAME = "wallet_shared_floor"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    setup_golds(session, 100, 100)
    host.cmd({"cmd": "wallet", "mode": "shared", "now": True})
    time.sleep(2)
    # 200 in the pot; both try to spend 150.
    guest.cmd({"cmd": "spend", "amount": 150})
    host.cmd({"cmd": "spend", "amount": 150})
    time.sleep(3)
    h, g = gold(host), gold(guest)
    expect(h >= 0 and g >= 0, f"never below zero ({h}, {g})")
    expect(h == g, f"everyone agrees on the balance ({h}, {g})")
    # The guest's request is refused if it arrives second; the host's own
    # purchase cannot be undone, so it is clamped at zero instead.
    expect(h in (0, 50), f"at most the pot was spent ({h})")
