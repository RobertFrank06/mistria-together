"""Shared wallet: balances add up, and a guest's purchase lowers everyone's gold."""
from gametest import expect
from gametest.scenarios._wallet import gold, setup_golds, wait_gold

NAME = "wallet_shared_spend"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    setup_golds(session)
    host.cmd({"cmd": "wallet", "mode": "shared", "now": True})
    expect(wait_gold(guest, 1500, "guest sees the sum"), f"guest shows the shared balance ({gold(guest)})")
    expect(gold(host) == 1500, "host shows the shared balance")
    guest.cmd({"cmd": "spend", "amount": 200})
    expect(wait_gold(host, 1300, "host drops"), f"host's gold dropped by the guest's purchase ({gold(host)})")
    expect(wait_gold(guest, 1300, "guest drops"), f"guest's gold dropped too ({gold(guest)})")
