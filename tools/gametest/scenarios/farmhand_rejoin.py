"""Leave and join again: the same character comes back."""
from gametest import expect_equal, join_farmhand

NAME = "farmhand_rejoin"
PLAYERS = 2
MODES = ["new", "title"]


def run(session):
    host, guest = session.host, session.guests[0]
    host.cmd({"cmd": "menu", "action": "host"})
    host.wait(lambda s: s.get("online"), "host online", 40)
    join_farmhand(session, guest, "Mia")
    guest.cmd({"cmd": "gold", "set": 777})
    guest.cmd({"cmd": "save"})
    guest.cmd({"cmd": "quit_to_title"})
    guest.wait(lambda s: s.get("title"), "back at the title", 60)
    join_farmhand(session, guest, "")
    info = guest.cmd({"cmd": "save_info"})
    expect_equal(info["name"], "Mia", "same character name")
    expect_equal(info["gold"], 777, "same gold")
