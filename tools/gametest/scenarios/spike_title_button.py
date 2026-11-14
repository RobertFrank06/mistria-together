"""Spike: the Multiplayer button on the title screen. Manual only."""
import time

NAME = "spike_title_button"
PLAYERS = 1
MODES = ["title"]
MANUAL = True


def run(session):
    g = session.host
    for _ in range(60):
        if g.cmd({"cmd": "title_button"})["exists"]:
            break
        time.sleep(1)
    time.sleep(2)
    info = g.cmd({"cmd": "title_button"})
    print("button", {k: v for k, v in info.items() if k != "rows"})
    for r in info["rows"]:
        print("row", r)
    print("after tap ", g.cmd({"cmd": "title_button", "tap": True}))
    time.sleep(2)
    print("popup now ", g.cmd({"cmd": "title_button"}))
    from gametest import screenshot, RIG
    screenshot(g, "/tmp/claude-1000/-home-robert-Projects-mistria-together/099c3dea-1bf0-4be3-846a-c8abd3da9e05/scratchpad/title.png")
