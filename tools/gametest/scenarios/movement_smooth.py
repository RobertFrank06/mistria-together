"""The host's ghost of a moving guest is smooth and ends where the guest is."""
import time

from gametest import expect

NAME = "movement_smooth"
PLAYERS = 2
SETUP = "farm"


def run(session):
    session.connect()
    host, guest = session.host, session.guests[0]
    host.cmd({"cmd": "trace"})  # clear
    guest.cmd({"cmd": "move", "dx": 1.0, "dy": 0.0, "frames": 120})
    time.sleep(4)
    trace = host.cmd({"cmd": "trace"}) or {}
    # `trace` also writes dev_trace.json; read it when the command has no value.
    import json
    try:
        rows = json.loads((host.ipc / "dev_trace.json").read_text())["trace"]
    except (OSError, ValueError, KeyError):
        rows = []
    xs = [r[1] for r in rows]
    steps = [abs(b - a) for a, b in zip(xs, xs[1:])]
    expect(len(steps) > 60, f"enough trace samples ({len(steps)})")
    moving = [s for s in steps if s > 0]
    # Ignore the start/stop transitions (buffer fill, last packet).
    moving = moving[15:-15] if len(moving) > 60 else moving
    mean = sum(moving) / max(1, len(moving))
    expect(max(moving) <= 2 * mean + 0.001 if moving else False,
           f"no step larger than twice the mean ({max(moving) if moving else 0:.2f} vs {mean:.2f})")
    g = guest.state()
    gx = host.state()["peers"][0]["ghost"]["x"]
    expect(abs(gx - g["x"]) <= 2, f"ghost ends within 2 px ({gx} vs {g['x']})")
