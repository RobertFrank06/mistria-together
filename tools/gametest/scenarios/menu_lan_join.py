"""Host and guest driven only through the menu; the guest finds the host in
link.json's lan list."""
import json
import time

from gametest import expect

NAME = "menu_lan_join"
PLAYERS = 2
SETUP = "farm"


def run(session):
    host, guest = session.host, session.guests[0]
    host.cmd({"cmd": "menu", "action": "host"})
    deadline = time.time() + 30
    found = False
    while time.time() < deadline and not found:
        try:
            link = json.loads((guest.ipc / "link.json").read_text())
            found = bool(link.get("lan"))
        except (OSError, ValueError):
            pass
        time.sleep(1)
    expect(found, "guest sees the host in the nearby list")
    guest.cmd({"cmd": "menu", "action": "joinlan"})
    for g in session.all:
        g.wait(lambda s: s.get("online"), "online", 30)
    expect(True, "both online through the menu only")
