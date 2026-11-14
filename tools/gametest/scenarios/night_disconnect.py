"""A ready guest who disconnects no longer blocks the host."""
import time

from gametest import expect
from gametest.scenarios._night import cal, finish_night, go_home

NAME = "night_disconnect"
PLAYERS = 2


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    go_home(session.all)
    c0 = cal(host)
    guest.cmd({"cmd": "bed", "action": "sleep"})
    time.sleep(2)
    guest.cmd({"cmd": "menu", "action": "off"})
    host.wait(lambda s: len(s.get("peers", [])) == 0, "guest gone", 20)
    host.cmd({"cmd": "bed", "action": "sleep"})
    finish_night([host], c0)
    expect(cal(host) == c0 + 86400, "host advanced alone")
