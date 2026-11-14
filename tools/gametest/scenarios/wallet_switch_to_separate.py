"""Back to separate wallets: the balance is split evenly next morning."""
import time

from gametest import expect
from gametest.scenarios._night import cal, finish_night, go_home
from gametest.scenarios._wallet import gold, setup_golds, wait_gold

NAME = "wallet_switch_to_separate"
PLAYERS = 2


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    setup_golds(session, 1001, 500)
    host.cmd({"cmd": "wallet", "mode": "shared", "now": True})
    time.sleep(2)
    host.cmd({"cmd": "wallet", "mode": "separate"})
    go_home(session.all)
    c0 = cal(host)
    host.cmd({"cmd": "bed", "action": "sleep"})
    guest.cmd({"cmd": "bed", "action": "sleep"})
    finish_night(session.all, c0)
    expect(wait_gold(guest, 750, "guest"), f"guest got half ({gold(guest)})")
    expect(wait_gold(host, 751, "host"), f"host got the other half, odd coin included ({gold(host)})")
