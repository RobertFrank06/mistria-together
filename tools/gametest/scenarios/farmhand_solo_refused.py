"""Joining from F9 with a solo save loaded is refused and the save is untouched."""
import time

from gametest import expect, sha256

NAME = "farmhand_solo_refused"
PLAYERS = 2


def run(session):
    host, solo = session.host, session.guests[0]
    host.cmd({"cmd": "menu", "action": "host"})
    host.wait(lambda s: s.get("online"), "host online", 40)
    info = solo.cmd({"cmd": "save"})
    before = sha256(info["path"])
    solo.cmd({"cmd": "menu", "action": "f9join", "addr": "127.0.0.1"})
    time.sleep(6)
    expect(not solo.state().get("online"), "the solo player did not join")
    expect(sha256(info["path"]) == before, "the solo save is byte-for-byte unchanged")
