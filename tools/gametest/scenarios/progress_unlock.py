"""A world unlock on the host opens for the guest too."""
import time

from gametest import expect

NAME = "progress_unlock"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    expect(not guest.cmd({"cmd": "wm_state", "i": 0})["on"], "world mod 0 starts locked for the guest")
    host.cmd({"cmd": "wm_enable", "i": 0})
    expect(host.cmd({"cmd": "wm_state", "i": 0})["on"], "the host unlocked it")
    deadline = time.time() + 15
    while time.time() < deadline and not guest.cmd({"cmd": "wm_state", "i": 0})["on"]:
        time.sleep(1)
    expect(guest.cmd({"cmd": "wm_state", "i": 0})["on"], "the guest has it too")
