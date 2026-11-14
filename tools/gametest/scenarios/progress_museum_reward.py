"""A set completed by one player's donations rewards the other players too."""
import time

from gametest import expect

NAME = "progress_museum_reward"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    before = host.cmd({"cmd": "inv_total"})["total"]
    r = guest.cmd({"cmd": "donate_set"})
    expect(r["donated"] > 0, f"the guest donated a whole set ({r['donated']} items)")
    time.sleep(4)
    after = host.cmd({"cmd": "inv_total"})["total"]
    expect(after > before, f"the host received the set reward ({before} -> {after})")
