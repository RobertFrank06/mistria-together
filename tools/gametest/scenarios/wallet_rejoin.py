"""A guest who left during shared mode sees the shared balance on return."""
import time

from gametest import expect
from gametest.scenarios._wallet import gold, setup_golds, wait_gold

NAME = "wallet_rejoin"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    setup_golds(session)
    host.cmd({"cmd": "wallet", "mode": "shared", "now": True})
    time.sleep(2)
    guest.cmd({"cmd": "menu", "action": "off"})
    guest.wait(lambda s: not s.get("online"), "guest offline", 20)
    expect(wait_gold(guest, 500, "personal gold back"), f"offline guest has their own gold again ({gold(guest)})")
    host.cmd({"cmd": "spend", "amount": 100})
    guest.cmd({"cmd": "menu", "action": "join", "addr": "127.0.0.1"})
    guest.wait(lambda s: s.get("online"), "guest back", 40)
    expect(wait_gold(guest, 1400, "shared balance"), f"guest sees the shared balance again ({gold(guest)})")
