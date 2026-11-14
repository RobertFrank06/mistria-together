"""A guest who faints is not paid at that moment, only when the night runs."""
import time

from gametest import expect
from gametest.scenarios._night import cal, finish_night, go_home

NAME = "money_faint_no_early_pay"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    time.sleep(5)   # let the storage scan baseline the bin first
    host.cmd({"cmd": "bin_put", "count": 4})
    time.sleep(3)
    total = host.cmd({"cmd": "bin_value"})["value"]
    g0 = guest.cmd({"cmd": "gold_get"})["gold"]
    go_home(session.all)
    c0 = cal(host)
    guest.cmd({"cmd": "faint"})
    guest.wait(lambda s: (s.get("night") or {}).get("eod_button"), "summary", 60)
    time.sleep(2)
    expect(guest.cmd({"cmd": "gold_get"})["gold"] == g0, "no payout while waiting at the summary")
    host.cmd({"cmd": "bed", "action": "sleep"})
    finish_night(session.all, c0)
    time.sleep(3)
    expect(guest.cmd({"cmd": "gold_get"})["gold"] - g0 == total // 2, "paid the share after the night")
