"""Helpers for the night scenarios."""
import time

from gametest import Failure

HOME = {"cmd": "tp", "room": "player_home", "x": 100, "y": 100}


def go_home(games):
    for g in games:
        g.cmd(HOME)
    time.sleep(2)


def cal(g):
    return g.cmd({"cmd": "clock"})["cal"]


def finish_night(games, cal0, timeout=150):
    """Tap each summary's button as soon as it is usable until every
    calendar has moved on. Returns when all are in the new day."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        for g in games:
            if cal(g) == cal0:
                g.cmd({"cmd": "summary_next"})
        if all(cal(g) != cal0 for g in games):
            return
        time.sleep(1)
    raise Failure(f"night did not finish: {[ (g.name, cal(g)) for g in games ]}")
