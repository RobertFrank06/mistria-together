"""Loading a farmhand save without joining returns to the title."""
import time

from gametest import expect, join_farmhand

NAME = "farmhand_offline_refused"
PLAYERS = 2
MODES = ["new", "title"]


def run(session):
    host, guest = session.host, session.guests[0]
    host.cmd({"cmd": "menu", "action": "host"})
    host.wait(lambda s: s.get("online"), "host online", 40)
    join_farmhand(session, guest, "Mia")
    guest.cmd({"cmd": "save"})
    guest.cmd({"cmd": "quit_to_title"})
    guest.wait(lambda s: s.get("title"), "back at the title", 60)
    guest.cmd({"cmd": "title_load"})
    # It enters the world for a moment, then is sent back with a notice.
    deadline = time.time() + 60
    while time.time() < deadline and "showing notice: This save belongs" not in guest.log():
        time.sleep(1)
    expect("showing notice: This save belongs" in guest.log(), "farmhand save refused outside a join, notice shown")
    expect(guest.state().get("title"), "guest is back at the title")
