"""The shipping bin's value is split between the players; nobody is paid twice."""
import time

from gametest import expect, expect_equal
from gametest.scenarios._night import cal, finish_night, go_home

NAME = "money_bin_split"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    time.sleep(5)   # let the storage scan baseline the bin first
    host.cmd({"cmd": "bin_put", "count": 5})
    time.sleep(5)
    total = host.cmd({"cmd": "bin_value"})["value"]
    expect(total > 0, f"the bin is worth something ({total})")
    expect_equal(guest.cmd({"cmd": "bin_value"})["value"], total, "the guest sees the same bin")
    g0 = {g.name: g.cmd({"cmd": "gold_get"})["gold"] for g in session.all}
    go_home(session.all)
    c0 = cal(host)
    host.cmd({"cmd": "bed", "action": "sleep"})
    guest.cmd({"cmd": "bed", "action": "sleep"})
    finish_night(session.all, c0)
    time.sleep(3)
    g1 = {g.name: g.cmd({"cmd": "gold_get"})["gold"] for g in session.all}
    gain_h, gain_g = g1[host.name] - g0[host.name], g1[guest.name] - g0[guest.name]
    expect_equal(gain_g, total // 2, "guest got half")
    expect_equal(gain_h, total - total // 2, "host got the other half (odd coin to the host)")
    expect_equal(gain_h + gain_g, total, "no double payment")
