"""Shared helpers for the clock scenarios."""
import time


def clk(g):
    return g.cmd({"cmd": "clock"})["clk"]


def full(g):
    return g.cmd({"cmd": "clock"})


def wait_close(a, b, within, what, timeout=8):
    deadline = time.time() + timeout
    while time.time() < deadline:
        d = abs(clk(a) - clk(b))
        if d <= within:
            return d
        time.sleep(0.3)
    from gametest import expect
    expect(False, f"{what}: clocks within {within}s (off by {abs(clk(a) - clk(b))})")
