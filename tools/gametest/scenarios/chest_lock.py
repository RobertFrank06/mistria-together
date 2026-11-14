"""A chest is open for one player at a time."""
import time

from gametest import expect

NAME = "chest_lock"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    info = host.cmd({"cmd": "bin_info"})
    x, y = info["x"], info["y"]
    guest.cmd({"cmd": "chest_open", "x": x, "y": y})
    guest.wait(lambda s: True, "tick", 1)
    time.sleep(2)
    expect(guest.cmd({"cmd": "chest_state"})["menu"], "the guest has the chest open")
    host.cmd({"cmd": "chest_open", "x": x, "y": y})
    time.sleep(2)
    expect(not host.cmd({"cmd": "chest_state"})["menu"], "the host is refused while it is in use")
    guest.cmd({"cmd": "chest_close"})
    time.sleep(2)
    host.cmd({"cmd": "chest_open", "x": x, "y": y})
    time.sleep(2)
    expect(host.cmd({"cmd": "chest_state"})["menu"], "the host can open it once the guest is done")
