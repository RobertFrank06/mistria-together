"""An item a guest drops is on the ground for the host too."""
import time

from gametest import expect

NAME = "items_drop_visible"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    guest.cmd({"cmd": "drop"})
    time.sleep(3)
    print("guest items dbg", guest.cmd({"cmd": "items_dbg"}), "host", host.cmd({"cmd": "items_dbg"}))
    gi = guest.cmd({"cmd": "items_near"})["items"]
    hi = host.cmd({"cmd": "items_near"})["items"]
    expect(any(i["gid"] for i in gi), "the dropped item is tagged on the guest")
    expect(any(i["gid"] and i["item"] == "turnip" for i in hi), f"the host sees the item ({hi})")
