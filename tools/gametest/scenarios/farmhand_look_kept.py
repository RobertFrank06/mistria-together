"""A farmhand's chosen look survives a save and a rejoin."""
from gametest import expect_equal, join_farmhand

NAME = "farmhand_look_kept"
PLAYERS = 2
MODES = ["new", "title"]


def run(session):
    host, guest = session.host, session.guests[0]
    host.cmd({"cmd": "menu", "action": "host"})
    host.wait(lambda s: s.get("online"), "host online", 40)
    join_farmhand(session, guest, "Mia")
    guest.cmd({"cmd": "customization_close"})
    guest.cmd({"cmd": "look", "set": 5})
    guest.cmd({"cmd": "save"})
    guest.cmd({"cmd": "quit_to_title"})
    guest.wait(lambda s: s.get("title"), "back at the title", 60)
    join_farmhand(session, guest, "")
    guest.cmd({"cmd": "customization_close"})
    expect_equal(guest.cmd({"cmd": "look"})["tone"], 5, "the chosen look came back after a rejoin")
