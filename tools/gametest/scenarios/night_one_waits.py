"""One sleeper does not start the night and can get up again."""
import time

from gametest import expect
from gametest.scenarios._night import cal, go_home

NAME = "night_one_waits"
PLAYERS = 2


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    go_home(session.all)
    c0 = cal(host)
    guest.cmd({"cmd": "bed", "action": "sleep"})
    time.sleep(10)
    expect(cal(host) == c0 and cal(guest) == c0, "the day did not advance")
    expect(guest.cmd({"cmd": "night_state"})["bed"], "guest reports waiting in bed")
    expect(len(host.cmd({"cmd": "night_state"})["ready"]) == 1, "one player ready")
    guest.cmd({"cmd": "bed", "action": "get_up"})
    time.sleep(2)
    expect(not guest.cmd({"cmd": "night_state"})["bed"], "guest got up")
    expect(len(host.cmd({"cmd": "night_state"})["ready"]) == 0, "ready list empty again")
