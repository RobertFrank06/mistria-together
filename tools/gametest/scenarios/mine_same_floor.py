"""Players on the same mine floor see the same layout."""
from gametest import expect, expect_same_world
from gametest.scenarios._mines import enter

NAME = "mine_same_floor"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    enter(session, [1, 1])
    host = session.host
    expect(host.state()["peers"][0]["loc"] == host.state()["loc"], "they are in the same place")
    expect_same_world(session.all, "grid", timeout=10)
