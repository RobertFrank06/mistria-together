"""A scene clears the room's loose items; they come back from the host's list."""
import time

from gametest import expect

NAME = "scene_items_survive"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    guest.cmd({"cmd": "drop"})
    time.sleep(3)
    expect(len(host.cmd({"cmd": "items_near"})["items"]) == 1, "the item is on the ground for both")
    guest.cmd({"cmd": "scene_flag", "on": True})
    guest.cmd({"cmd": "items_clear"})
    time.sleep(1)
    expect(len(guest.cmd({"cmd": "items_near"})["items"]) == 0, "the scene cleared the guest's loose items")
    guest.cmd({"cmd": "scene_flag", "on": False})
    time.sleep(4)
    expect(len(guest.cmd({"cmd": "items_near"})["items"]) == 1, "the item is back for the guest")
    expect(len(host.cmd({"cmd": "items_near"})["items"]) == 1, "and still there for the host")
