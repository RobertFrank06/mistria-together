"""A player in a scene is hidden from the others until it ends."""
import time

from gametest import expect


NAME = "scene_hides_player"
PLAYERS = 2
SETUP = "farm"


def hidden(host):
    return host.state()["peers"][0].get("hidden")


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    time.sleep(2)
    expect(not hidden(host), "the guest is visible at first")
    guest.cmd({"cmd": "scene_flag", "on": True})
    time.sleep(3)
    expect(hidden(host), "the guest is hidden during its scene")
    guest.cmd({"cmd": "scene_flag", "on": False})
    time.sleep(3)
    expect(not hidden(host), "the guest is back after the scene")
