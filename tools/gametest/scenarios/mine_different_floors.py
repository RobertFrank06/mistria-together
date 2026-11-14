"""Players on different floors are in different places."""
from gametest import expect
from gametest.scenarios._mines import enter

NAME = "mine_different_floors"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    enter(session, [1, 2])
    host = session.host
    expect(host.state()["peers"][0]["loc"] != host.state()["loc"], "they are on different floors")
