"""After connecting, guests' near digest equals the host's on the farm."""
from gametest import expect_same_world

NAME = "join_snapshot"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    expect_same_world(session.all, "near")
