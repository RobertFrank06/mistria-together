"""A farmhand cannot save before the host's world has been adopted."""
from gametest import expect, join_farmhand

NAME = "farmhand_no_early_save"
PLAYERS = 2
MODES = ["new", "title"]


def run(session):
    host, guest = session.host, session.guests[0]
    host.cmd({"cmd": "menu", "action": "host"})
    host.wait(lambda s: s.get("online"), "host online", 40)
    join_farmhand(session, guest, "Mia")
    expect(guest.cmd({"cmd": "guard_check", "adopted": False})["result"] is False,
           "save vetoed before the world is adopted")
    expect(guest.cmd({"cmd": "guard_check", "adopted": True})["result"] is None,
           "save allowed once the world is adopted")
