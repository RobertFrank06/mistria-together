"""A guest joins from the title screen: a farmhand with the host's farm id."""
import time

from gametest import expect, expect_equal, join_farmhand
from gametest.scenarios._night import cal, finish_night, go_home

NAME = "farmhand_first_join"
PLAYERS = 2
MODES = ["new", "title"]


def run(session):
    host, guest = session.host, session.guests[0]
    host.cmd({"cmd": "menu", "action": "host"})
    host.wait(lambda s: s.get("online"), "host online", 40)
    join_farmhand(session, guest, "Mia")
    hi, gi = host.cmd({"cmd": "save_info"}), guest.cmd({"cmd": "save_info"})
    expect_equal(gi["ident"], hi["ident"], "farmhand uses the host's farm id")
    expect_equal(gi["name"], "Mia", "farmhand has the chosen name")
    # One night later the farmhand's save exists under the host's identifier.
    go_home(session.all)
    c0 = cal(host)
    host.cmd({"cmd": "bed", "action": "sleep"})
    guest.cmd({"cmd": "bed", "action": "sleep"})
    finish_night(session.all, c0)
    time.sleep(5)
    save = guest.data / "saves" / f"game-{gi['ident']}-autosave.sav"
    expect(save.exists(), f"farmhand save written: {save.name}")
    tag = guest.data / "mod_data" / "mistria_together" / "saves" / f"{gi['ident']}.json"
    expect(tag.exists() and "farmhand" in tag.read_text(), "farmhand save is tagged")
