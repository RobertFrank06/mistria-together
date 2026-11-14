"""Helpers for the wallet scenarios."""
import time


def gold(g):
    return g.cmd({"cmd": "gold_get"})["gold"]


def setup_golds(session, host_gold=1000, guest_gold=500):
    session.host.cmd({"cmd": "gold", "set": host_gold})
    session.guests[0].cmd({"cmd": "gold", "set": guest_gold})
    time.sleep(2)   # the guest reports its gold to the host


def wait_gold(g, value, what, timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if gold(g) == value:
            return True
        time.sleep(0.3)
    return False
