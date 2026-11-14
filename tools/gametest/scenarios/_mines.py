"""Helpers for the mine scenarios."""
from gametest import Failure


def enter(session, floors, timeout=90):
    session.host.cmd({"cmd": "mines", "on": True})
    import time
    for g in session.all:
        g.wait(lambda s: (s.get("progress") or {}).get("mines"), "mines setting known", 20)
    time.sleep(1)
    for g, f in zip(session.all, floors):
        g.cmd({"cmd": "mine", "floor": f})
    for g, f in zip(session.all, floors):
        g.wait(lambda s, f=f: str(s.get("loc", "")).startswith("dng:") and s.get("loc") == f"dng:{f}",
               f"{g.name} on floor {f}", timeout)
    time.sleep(3)
