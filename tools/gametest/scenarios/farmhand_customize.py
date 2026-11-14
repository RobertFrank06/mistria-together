"""A brand-new farmhand is offered the game's character creation in the world."""
import time

from gametest import expect, join_farmhand

NAME = "farmhand_customize"
PLAYERS = 2
MODES = ["new", "title"]


def run(session):
    host, guest = session.host, session.guests[0]
    host.cmd({"cmd": "menu", "action": "host"})
    host.wait(lambda s: s.get("online"), "host online", 40)
    join_farmhand(session, guest, "Mia")
    deadline = time.time() + 20
    while time.time() < deadline and not guest.cmd({"cmd": "customization_state"})["open"]:
        time.sleep(1)
    expect(guest.cmd({"cmd": "customization_state"})["open"], "character creation opened for the new farmhand")
    guest.cmd({"cmd": "customization_close"})
    time.sleep(2)
    expect(not guest.cmd({"cmd": "customization_state"})["open"], "and can be closed again")
