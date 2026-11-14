"""A guest whose companion is killed and restarted comes back online."""
import time

from gametest import expect, expect_same_world

NAME = "reconnect"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    guest = session.guests[0]
    guest.restart_companion()
    time.sleep(1)
    guest.cmd({"cmd": "menu", "action": "join", "addr": "127.0.0.1"})
    guest.wait(lambda s: s.get("online"), "guest back online", 40)
    guest.wait(lambda s: (s.get("sync") or {}).get("adopted"), "world adopted again", 40)
    expect(True, "guest reconnected")
    expect_same_world(session.all, "near", timeout=10)
