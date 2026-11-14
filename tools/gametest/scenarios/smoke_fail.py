"""Deliberately failing scenario: proves the runner exits non-zero and saves
artifacts. Run it by name only; it is excluded from the default selection."""
from gametest import expect

NAME = "smoke_fail"
PLAYERS = 1
MANUAL = True


def run(session):
    expect(False, "deliberately false")
