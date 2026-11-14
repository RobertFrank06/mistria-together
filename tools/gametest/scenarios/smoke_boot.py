"""Two instances reach the world."""
from gametest import expect

NAME = "smoke_boot"
PLAYERS = 2


def run(session):
    for g in session.all:
        st = g.state()
        expect(st.get("in_world"), f"{g.name} is in the world")
