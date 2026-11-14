"""Two players take the same item in the same moment: exactly one gets it."""
import time

from gametest import expect, expect_equal

NAME = "items_pickup_once"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    guest.cmd({"cmd": "drop"})
    time.sleep(3)
    b = host.cmd({"cmd": "inv_count"})["count"], guest.cmd({"cmd": "inv_count"})["count"]
    host.cmd({"cmd": "pickup_nearest"})
    guest.cmd({"cmd": "pickup_nearest"})
    time.sleep(4)
    a = host.cmd({"cmd": "inv_count"})["count"], guest.cmd({"cmd": "inv_count"})["count"]
    expect_equal((a[0] - b[0]) + (a[1] - b[1]), 1, f"exactly one inventory gained the item ({b} -> {a})")
    expect(not host.cmd({"cmd": "items_near"})["items"] and not guest.cmd({"cmd": "items_near"})["items"],
           "the item is gone for both")
