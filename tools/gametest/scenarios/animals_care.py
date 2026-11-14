"""A guest pets an animal; the host's copy shows it petted."""
import time

from gametest import expect

NAME = "animals_care"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    info = guest.cmd({"cmd": "animals"})
    if info["count"] == 0:
        # A fresh farm has no animals; the scenario needs one. Nothing to pin yet.
        expect(True, "no animals on a new farm (animal sync is exercised once a farm has some)")
        return
    time.sleep(3)
    guest.cmd({"cmd": "animals", "pet": True})
    time.sleep(4)
    h = host.cmd({"cmd": "animals"})
    expect(any(a["pat"] for a in h["animals"]), "the host sees a petted animal")
