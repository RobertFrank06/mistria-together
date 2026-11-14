"""A third player who joins while the night runs gets the morning and is not counted."""
import time

from gametest import expect
from gametest.scenarios._night import cal, finish_night, go_home

NAME = "night_join_during"
PLAYERS = 3


def run(session):
    host, p2, p3 = session.all
    host.cmd({"cmd": "menu", "action": "host"})
    host.wait(lambda s: s.get("online"), "host online", 40)
    p2.cmd({"cmd": "menu", "action": "join", "addr": "127.0.0.1"})
    p2.wait(lambda s: s.get("online") and (s.get("sync") or {}).get("adopted"), "p2 online", 40)
    go_home([host, p2])
    c0 = cal(host)
    host.cmd({"cmd": "bed", "action": "sleep"})
    p2.cmd({"cmd": "bed", "action": "sleep"})
    # The night is running: the third player joins now.
    time.sleep(3)
    p3.cmd({"cmd": "menu", "action": "join", "addr": "127.0.0.1"})
    p3.wait(lambda s: s.get("online"), "p3 online during the night", 60)
    finish_night([host, p2], c0)
    p3.wait(lambda s: (s.get("sync") or {}).get("adopted"), "p3 has the host's world", 60)
    time.sleep(4)
    expect(cal(p3) == cal(host), "the latecomer is in the new morning")
